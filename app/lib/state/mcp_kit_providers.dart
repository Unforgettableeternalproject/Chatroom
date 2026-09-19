import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../models/host_kit.dart';
import 'host_probe.dart';

/// 這台機器上有沒有接上 chatroom（`install-kit`）。
///
/// 與 `hostKitProvider` 同一套容錯：**每一種「讀不到」都降級成「這台沒有」**
/// ——壞掉的指路牌與沒有指路牌，對使用者的意義相同。
final mcpKitProvider = FutureProvider<McpKit?>((ref) async {
  final home = Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      '';
  if (home.isEmpty) return null;
  final file = File('$home${Platform.pathSeparator}.chatroom'
      '${Platform.pathSeparator}mcp-kit.json');
  try {
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString());
    if (json is! Map) return null;
    final kit = McpKit.fromJson(json.cast<String, dynamic>());
    if (kit.kitRoot.isEmpty) return null;
    if (!await Directory(kit.kitRoot).exists()) return null;
    return kit;
  } on Object {
    return null;
  }
});

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
      url: values['CHATROOM_URL'] ?? '',
      token: values['CHATROOM_TOKEN'] ?? '',
    );
  } on Object {
    return null;
  }
});

/// 已安裝的 bridge 版本，讀 `bridge/chatroom_mcp/_build.json`。
///
/// kit 解開之後沒有 `.git`，所以那份檔案是部署現場唯一可靠的版本來源
/// （`bridge/chatroom_mcp/version.py` 的註解已經說明過）。
final mcpBridgeVersionProvider = FutureProvider<String>((ref) async {
  final kit = await ref.watch(mcpKitProvider.future);
  if (kit == null) return '';
  final sep = Platform.pathSeparator;
  final path = [kit.kitRoot, 'bridge', 'chatroom_mcp', '_build.json'].join(sep);
  final file = File(path);
  try {
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
});

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
