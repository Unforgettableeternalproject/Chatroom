import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../models/host_kit.dart';
import 'host_probe.dart';
import 'runner_kit_providers.dart';

/// 登錄檔的位置。`install-kit/install.py` 寫，App 讀。
File? mcpKitRegistryFile([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  final home = env['USERPROFILE'] ?? env['HOME'] ?? '';
  if (home.isEmpty) return null;
  return File('$home${Platform.pathSeparator}.chatroom'
      '${Platform.pathSeparator}mcp-kit.json');
}

/// 這台機器上有沒有接上 chatroom。
///
/// 與 `hostKitProvider` 同一套容錯：**每一種「讀不到」都降級成「這台沒有」**
/// ——壞掉的指路牌與沒有指路牌，對使用者的意義相同。
///
/// ⚠️ 但「沒有指路牌」**不等於**沒有 bridge：直接跑 repo 裡那份的人從來
/// 不會有 `mcp-kit.json`。那時往下退到本機來源（見 [resolveMcpKit]），
/// 只有連檔案都找不到才回 `null`。
final mcpKitProvider = FutureProvider<McpKit?>((ref) async {
  return resolveMcpKit(
    registry: mcpKitRegistryFile(),
    environment: Platform.environment,
    walkFrom: [
      File(Platform.resolvedExecutable).parent.path,
      Directory.current.path,
    ],
  );
});

/// 偵測順序（每一層都要**實際存在**才算數）：
///
/// 1. 安裝包登錄檔 `~/.chatroom/mcp-kit.json`
/// 2. 環境變數 `CHATROOM_BRIDGE_PATH`
/// 3. 執行器設定 `config.json` 的 `bridge_path`
/// 4. 從執行檔／工作目錄往上找含 `bridge/chatroom_mcp` 的位置（開發模式）
/// 5. 常見安裝位置
///
/// 🔴 **不寫死任何一台機器的路徑**：上面每一條都是從設定、環境或相對位置
/// 推出來的，常見位置那一層也只用系統給的目錄組出來。
Future<McpKit?> resolveMcpKit({
  File? registry,
  Map<String, String> environment = const {},
  List<String> walkFrom = const [],
}) async {
  final installed = await _mcpFromRegistry(registry);
  if (installed != null) return installed;

  McpKit? fallback;
  for (final dir in await _bridgeCandidates(environment, walkFrom)) {
    final kit = await _localKitAt(dir);
    if (kit == null) continue;
    // 🔴 **說得出連線設定的那一份優先。** 同一台機器上可能有好幾份 bridge
    // （執行器帶一份、repo 裡一份），而挑到沒有 `.env` 的那一份時，分頁會
    // 出現卻永遠答不出「連得上嗎」——那與沒有分頁一樣幫不上忙。
    // 都沒有 `.env` 時仍然回第一份：至少版本與位置是真的。
    if (kit.envFile.isNotEmpty) return kit;
    fallback ??= kit;
  }
  return fallback;
}

/// 這個目錄是不是一份 bridge；是的話連它的 `.env` 一起找出來。
Future<McpKit?> _localKitAt(String dir) async {
  final sep = Platform.pathSeparator;
  try {
    if (!await Directory('$dir${sep}chatroom_mcp').exists()) return null;
  } on Object {
    return null;
  }
  final root = File(dir).parent.path;
  return McpKit(
    kitRoot: root,
    envFile: await _firstExistingFile([
      '$root${sep}server$sep.env',
      '$dir$sep.env',
      '$root$sep.env',
    ]),
    source: KitSource.local,
    bridgeDir: dir,
  );
}

Future<McpKit?> _mcpFromRegistry(File? registry) async {
  if (registry == null) return null;
  try {
    if (!await registry.exists()) return null;
    final json = jsonDecode(await registry.readAsString());
    if (json is! Map) return null;
    final kit = McpKit.fromJson(json.cast<String, dynamic>());
    if (kit.kitRoot.isEmpty) return null;
    if (!await Directory(kit.kitRoot).exists()) return null;
    return kit;
  } on Object {
    return null;
  }
}

/// bridge 目錄的候選清單，按偵測順序排。
Future<List<String>> _bridgeCandidates(
  Map<String, String> env,
  List<String> walkFrom,
) async {
  final sep = Platform.pathSeparator;
  final out = <String>[];
  void add(String? path) {
    final value = (path ?? '').trim();
    if (value.isEmpty || out.contains(value)) return;
    out.add(value);
  }

  add(env['CHATROOM_BRIDGE_PATH']);
  add(await _bridgePathFromRunnerConfig(env));

  // 開發模式：App 與 bridge 在同一個 repo 裡，從執行檔往上走找得到
  for (final start in walkFrom) {
    var dir = Directory(start);
    for (var i = 0; i < 8; i++) {
      add('${dir.path}${sep}bridge');
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
  }

  // 常見安裝位置（系統目錄組出來的，不是某一台機器的路徑）
  final local = env['LOCALAPPDATA'];
  if (local != null && local.isNotEmpty) {
    add([local, 'UEP', 'Chatroom', 'bridge'].join(sep));
  }
  final programFiles = env['ProgramFiles'];
  if (programFiles != null && programFiles.isNotEmpty) {
    add([programFiles, 'Chatroom', 'bridge'].join(sep));
  }
  final home = env['USERPROFILE'] ?? env['HOME'];
  if (home != null && home.isNotEmpty) {
    add([home, '.chatroom', 'bridge'].join(sep));
    add([home, 'Chatroom', 'bridge'].join(sep));
  }
  return out;
}

/// 執行器設定裡的 `bridge_path`——它指的就是這台機器實際在用的 bridge。
Future<String> _bridgePathFromRunnerConfig(Map<String, String> env) async {
  final path = runnerConfigPathFor(env);
  if (path.isEmpty) return '';
  try {
    final file = File(path);
    if (!await file.exists()) return '';
    final json = jsonDecode(await file.readAsString());
    if (json is! Map) return '';
    return (json['bridge_path'] as String?) ?? '';
  } on Object {
    return '';
  }
}

Future<String> _firstExistingFile(List<String> paths) async {
  for (final path in paths) {
    try {
      if (await File(path).exists()) return path;
    } on Object {
      continue;
    }
  }
  return '';
}

/// agent 連線設定，從 kit 根目錄的 `.env` 現讀。
final mcpEnvProvider = FutureProvider<McpEnv?>((ref) async {
  final kit = await ref.watch(mcpKitProvider.future);
  if (kit == null) return null;
  try {
    final file = File(kit.envFile);
    if (!await file.exists()) return null;
    final values = <String, String>{};
    for (final line in await file.readAsLines()) {
      final text = line.trim();
      if (text.isEmpty || text.startsWith('#')) continue;
      final at = text.indexOf('=');
      if (at <= 0) continue;
      values[text.substring(0, at).trim()] = text.substring(at + 1).trim();
    }
    return McpEnv(
      url: _urlFrom(values),
      token: values['CHATROOM_TOKEN'] ?? '',
    );
  } on Object {
    return null;
  }
});

/// bridge 要連的 Hub 位址。
///
/// 安裝包的 `.env` 直接寫著 `CHATROOM_URL`。**本機來源讀到的多半是 Hub 自己
/// 那份 `server/.env`**，裡面只有 host／port——那時照同一條規則組出來，
/// 而不是說「沒有設定」（東西其實都在，只是換了個欄位名）。
///
/// `0.0.0.0` 是「所有介面都收」，沒有人連得到它，本機要連就是 127.0.0.1。
String _urlFrom(Map<String, String> values) {
  final url = (values['CHATROOM_URL'] ?? '').trim();
  if (url.isNotEmpty) return url;
  final host = (values['CHATROOM_HOST'] ?? '').trim();
  if (host.isEmpty) return '';
  final port = (values['CHATROOM_PORT'] ?? '').trim();
  final target = host == '0.0.0.0' ? '127.0.0.1' : host;
  // 8787 是 server 端的預設埠（`chatroom_server/config.py`）
  return 'http://$target:${port.isEmpty ? '8787' : port}';
}

/// 這台機器上的 bridge 版本。
///
/// kit 解開之後沒有 `.git`，所以 `_build.json` 是部署現場唯一可靠的版本來源
/// （`bridge/chatroom_mcp/version.py` 的註解已經說明過）。**但本機來源相反**：
/// 跑 repo 那份的人沒有 `_build.json`，有的是 `.git`——那時沿用 version.py
/// 的第二、三順位（git → unknown），不假裝讀不到。
final mcpBridgeVersionProvider = FutureProvider<String>((ref) async {
  final kit = await ref.watch(mcpKitProvider.future);
  if (kit == null) return '';
  return readBridgeVersion(kit.bridgePath);
});

/// 讀一個 bridge 目錄的版本字串。讀不到回空字串（畫面會說「讀不到」）。
Future<String> readBridgeVersion(String bridgeDir) async {
  final sep = Platform.pathSeparator;
  final packed =
      await _versionFromBuildFile('$bridgeDir${sep}chatroom_mcp${sep}_build.json');
  if (packed.isNotEmpty) return packed;

  final version =
      await _appVersionFromSource('$bridgeDir${sep}chatroom_mcp${sep}version.py');
  if (version.isEmpty) return '';
  final commit = await _gitCommit(bridgeDir);
  // 不偽造：問不到 commit 就講 unknown，與 version.py 的 `source` 同一個態度
  return '$version+${commit.isEmpty ? 'unknown' : commit}';
}

Future<String> _versionFromBuildFile(String path) async {
  try {
    final file = File(path);
    if (!await file.exists()) return '';
    final json = jsonDecode(await file.readAsString());
    if (json is! Map) return '';
    final version = (json['version'] as String?) ?? '';
    final commit = (json['commit'] as String?) ?? '';
    if (version.isEmpty) return commit;
    return commit.isEmpty ? version : '$version+$commit';
  } on Object {
    return '';
  }
}

/// `version.py` 裡的 `APP_VERSION`——三包同版號，所以它就是版號本身。
Future<String> _appVersionFromSource(String path) async {
  try {
    final file = File(path);
    if (!await file.exists()) return '';
    final match = RegExp(r'''APP_VERSION\s*=\s*["']([^"']+)["']''')
        .firstMatch(await file.readAsString());
    return match?.group(1) ?? '';
  } on Object {
    return '';
  }
}

/// repo 的短 commit，與 `version.py:_from_git` 同一組參數（含 dirty 判定，
/// scope 只看 bridge 目錄）。不是 git 工作樹就回空字串。
Future<String> _gitCommit(String bridgeDir) async {
  final dir = Directory(bridgeDir);
  final root = dir.parent.path;
  final name = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
  try {
    if (!await Directory('$root${Platform.pathSeparator}.git').exists()) {
      return '';
    }
    final head = await Process.run(
      'git',
      ['rev-parse', '--short=12', 'HEAD'],
      workingDirectory: root,
    ).timeout(const Duration(seconds: 5));
    if (head.exitCode != 0) return '';
    final commit = '${head.stdout}'.trim();
    if (commit.isEmpty) return '';
    final dirty = await Process.run(
      'git',
      ['status', '--porcelain', '--', '$name/'],
      workingDirectory: root,
    ).timeout(const Duration(seconds: 5));
    if (dirty.exitCode == 0 && '${dirty.stdout}'.trim().isNotEmpty) {
      return '$commit-dirty';
    }
    return commit;
  } on Object {
    return '';
  }
}

/// agent 接入的整體狀態。
@immutable
class McpStatus {
  const McpStatus({
    required this.reach,
    required this.auth,
    this.bridgeVersion = '',
  });

  /// Hub 連得到嗎（不帶 token）。
  final Probe reach;

  /// token 過得了嗎。
  final Probe auth;
  final String bridgeVersion;
}

/// 成員端要回答的三題裡的兩題：**連得上嗎、token 對不對**。
///
/// 第三題「agent 認得這些工具了嗎」這裡答不了——那要問 agent 的進程，
/// 而 App 看不到它。介面上改用「安裝時間」把話講明白：Claude Code 若在那
/// 之前就開著，它連的是舊的 bridge。**答不了的事不要假裝答得了。**
final mcpStatusProvider = FutureProvider<McpStatus?>((ref) async {
  final env = await ref.watch(mcpEnvProvider.future);
  if (env == null || !env.isComplete) return null;
  final version = await ref.watch(mcpBridgeVersionProvider.future);

  final base = env.url.endsWith('/')
      ? env.url.substring(0, env.url.length - 1)
      : env.url;

  final reachable = await probeHealth('$base/api/health');
  if (!reachable) {
    return McpStatus(
      reach: Probe(ProbeState.bad, L10n.current.hostMcpUnreachable),
      auth: Probe(ProbeState.unknown, L10n.current.hostMcpAuthSkipped),
      bridgeVersion: version,
    );
  }

  final authed = await probeStatus('$base/api/rooms', token: env.token);
  final Probe auth;
  if (authed == 200) {
    auth = Probe(ProbeState.ok, L10n.current.hostProbeAuthOk);
  } else if (authed == 401 || authed == 403) {
    auth = Probe(ProbeState.bad, L10n.current.hostProbeAuthBad);
  } else {
    auth = Probe(ProbeState.unknown, L10n.current.hostProbeAuthUnknown);
  }

  return McpStatus(
    reach: Probe(ProbeState.ok, L10n.current.hostMcpReachable),
    auth: auth,
    bridgeVersion: version,
  );
});
