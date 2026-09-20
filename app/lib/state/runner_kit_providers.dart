import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/host_kit.dart' show KitSource;
import 'runner_workspaces.dart';

// 工作區／專案的模型與 CRUD 住在 runner_workspaces.dart；這裡轉出去，
// 既有的 `import 'runner_kit_providers.dart'` 呼叫端不必改 import。
export 'runner_workspaces.dart';

/// 這台機器上裝著的執行器（`runner-kit`）。
///
/// ## 它是指路牌，不是設定
///
/// 與 `HostKit`／`McpKit` 同一個性質：安裝器寫下 `~/.chatroom/runner-kit.json`，
/// 裡面只有「這一包在哪、設定檔在哪」。**專案清單、公開與否、skill 目錄一律
/// 現讀 `config.json`**——那份檔案會被人手改，而改完不會有人回來更新註冊檔。
@immutable
class RunnerKit {
  const RunnerKit({
    required this.kitDir,
    required this.configPath,
    this.python = '',
    this.installedAt = '',
    this.source = KitSource.installed,
  });

  /// 這一份資訊的來源（安裝包／本機來源）。
  final KitSource source;

  /// runner-kit 解開後的根目錄。
  final String kitDir;

  /// 執行器設定檔（`config.json`）的絕對路徑。
  final String configPath;

  /// kit 自己那支 python（安裝器建的獨立 venv）。
  final String python;
  final String installedAt;

  factory RunnerKit.fromJson(Map<String, dynamic> json) => RunnerKit(
        kitDir: (json['kit_dir'] as String?) ?? '',
        configPath: (json['config'] as String?) ?? '',
        python: (json['python'] as String?) ?? '',
        installedAt: (json['installed_at'] as String?) ?? '',
      );
}

/// 註冊檔的位置。`runner-kit` 的安裝器寫，App 讀。
File? runnerKitRegistryFile() {
  final home = Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      '';
  if (home.isEmpty) return null;
  return File('$home${Platform.pathSeparator}.chatroom'
      '${Platform.pathSeparator}runner-kit.json');
}

/// 執行器設定檔的預設位置，與 `chatroom_runner.config.default_state_dir()`
/// 同一條規則。`CHATROOM_RUNNER_CONFIG` 可以指到別處。
String runnerConfigPathFor([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  final explicit = (env['CHATROOM_RUNNER_CONFIG'] ?? '').trim();
  if (explicit.isNotEmpty) return explicit;
  final sep = Platform.pathSeparator;
  final local = env['LOCALAPPDATA'] ?? '';
  if (local.isNotEmpty) {
    return [local, 'UEP', 'Chatroom', 'runner', 'config.json'].join(sep);
  }
  final home = env['HOME'] ?? '';
  if (home.isEmpty) return '';
  return [home, '.local', 'share', 'uep', 'chatroom', 'runner', 'config.json']
      .join(sep);
}

/// 這台機器上有沒有執行器。
///
/// **`null` 是正常狀態，不是錯誤**（同 `hostKitProvider`）：沒有的人照樣能
/// 加入別人的工作房、看派工結果，只是「執行器」分頁**整個不存在**。
///
/// ⚠️ 但判準不能只有登錄檔：手動部署的執行器（程式放在某個目錄、排程工作
/// 自己建）沒有 `runner-kit.json`，而它**正在接派工**。那時退回本機來源，
/// 見 [resolveRunnerKit]。
final runnerKitProvider = FutureProvider<RunnerKit?>((ref) async {
  return resolveRunnerKit(
    registry: runnerKitRegistryFile(),
    environment: Platform.environment,
    scheduledTask: queryRunnerScheduledTask,
  );
});

/// 偵測順序：
///
/// 1. 安裝包登錄檔 `~/.chatroom/runner-kit.json`
/// 2. 執行器設定 `config.json`（`CHATROOM_RUNNER_CONFIG` 或預設位置）
/// 3. 排程工作 `ChatroomRunner`——它的 `Execute`／工作目錄與 `--config`
///    參數就是這台機器實際在跑的那一份
///
/// 程式目錄從 `bridge_path` 的上一層或排程工作的工作目錄推；推不出來時
/// 留空（分頁照出，「安裝位置」改顯示設定檔路徑）。
Future<RunnerKit?> resolveRunnerKit({
  File? registry,
  Map<String, String> environment = const {},
  Future<RunnerTaskInfo?> Function()? scheduledTask,
}) async {
  final installed = await _runnerFromRegistry(registry);
  if (installed != null) return installed;

  var configPath = runnerConfigPathFor(environment);
  var kitDir = '';
  var python = '';
  var hasConfig = false;
  try {
    final file = File(configPath);
    if (await file.exists()) {
      hasConfig = true;
      final json = jsonDecode(await file.readAsString());
      if (json is Map) {
        final bridge = ((json['bridge_path'] as String?) ?? '').trim();
        if (bridge.isNotEmpty) kitDir = Directory(bridge).parent.path;
      }
    }
  } on Object {
    // 壞掉的設定仍然算「這台有執行器」：分頁裡的讀取端各自會說讀不到
  }

  if (!hasConfig || kitDir.isEmpty) {
    final task = await (scheduledTask?.call() ?? Future.value(null));
    if (task != null) {
      if (!hasConfig && task.configPath.isNotEmpty) {
        configPath = task.configPath;
        hasConfig = true;
      }
      if (kitDir.isEmpty) kitDir = task.workingDirectory;
      python = task.command;
    }
    if (!hasConfig && task == null) return null;
  }

  if (kitDir.isNotEmpty && !await Directory(kitDir).exists()) kitDir = '';
  if (configPath.isEmpty && kitDir.isEmpty) return null;
  return RunnerKit(
    kitDir: kitDir,
    configPath: configPath,
    python: python,
    source: KitSource.local,
  );
}

Future<RunnerKit?> _runnerFromRegistry(File? registry) async {
  if (registry == null) return null;
  try {
    if (!await registry.exists()) return null;
    final json = jsonDecode(await registry.readAsString());
    if (json is! Map) return null;
    final kit = RunnerKit.fromJson(json.cast<String, dynamic>());
    if (kit.configPath.isEmpty) return null;
    // 指路牌指向不存在的地方，與沒有指路牌是同一件事
    if (kit.kitDir.isNotEmpty && !await Directory(kit.kitDir).exists()) {
      return null;
    }
    return kit;
  } on Object {
    return null;
  }
}

/// 排程工作裡問得到的三件事。
@immutable
class RunnerTaskInfo {
  const RunnerTaskInfo({
    this.command = '',
    this.workingDirectory = '',
    this.configPath = '',
  });

  final String command;
  final String workingDirectory;
  final String configPath;
}

/// 查 Windows 排程工作 `ChatroomRunner`。查不到、不是 Windows、或 schtasks
/// 自己出錯都回 `null`——**問不到就是問不到**，不往上丟例外。
Future<RunnerTaskInfo?> queryRunnerScheduledTask(
    {String taskName = 'ChatroomRunner'}) async {
  if (!Platform.isWindows) return null;
  try {
    final out = await Process.run(
      'schtasks',
      ['/query', '/tn', taskName, '/xml', 'ONE'],
      stdoutEncoding: null,
    ).timeout(const Duration(seconds: 8));
    if (out.exitCode != 0) return null;
    return parseRunnerTaskXml(_decodeConsole(out.stdout as List<int>));
  } on Object {
    return null;
  }
}

/// schtasks `/xml` 吐的是 UTF-16LE（帶 BOM），照 UTF-8 解會整份變亂碼。
String _decodeConsole(List<int> bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    final units = <int>[];
    for (var i = 2; i + 1 < bytes.length; i += 2) {
      units.add(bytes[i] | (bytes[i + 1] << 8));
    }
    return String.fromCharCodes(units);
  }
  try {
    return utf8.decode(bytes, allowMalformed: true);
  } on Object {
    return String.fromCharCodes(bytes);
  }
}

/// 從工作的 XML 取出程式、工作目錄與 `--config` 指到的設定檔。
RunnerTaskInfo? parseRunnerTaskXml(String xml) {
  String pick(String tag) =>
      RegExp('<$tag>(.*?)</$tag>', dotAll: true).firstMatch(xml)?.group(1)?.trim() ??
      '';
  final command = pick('Command');
  final workingDirectory = pick('WorkingDirectory');
  final args = pick('Arguments');
  final config = RegExp(r'--config\s+"([^"]+)"').firstMatch(args)?.group(1) ??
      RegExp(r'--config\s+(\S+)').firstMatch(args)?.group(1) ??
      '';
  if (command.isEmpty && workingDirectory.isEmpty && config.isEmpty) {
    return null;
  }
  return RunnerTaskInfo(
    command: command,
    workingDirectory: workingDirectory,
    configPath: config,
  );
}

/// 這台機器上的執行器版本：`runner/chatroom_runner/_build.json`，沒有就
/// 讀程式目錄的 `VERSION.txt`。兩個都沒有就是讀不到，回空字串。
final runnerVersionProvider = FutureProvider<String>((ref) async {
  final kit = await ref.watch(runnerKitProvider.future);
  if (kit == null || kit.kitDir.isEmpty) return '';
  return readRunnerVersion(kit.kitDir);
});

Future<String> readRunnerVersion(String kitDir) async {
  final sep = Platform.pathSeparator;
  try {
    final build =
        File([kitDir, 'runner', 'chatroom_runner', '_build.json'].join(sep));
    if (await build.exists()) {
      final json = jsonDecode(await build.readAsString());
      if (json is Map) {
        final version = (json['version'] as String?) ?? '';
        final commit = (json['commit'] as String?) ?? '';
        if (version.isNotEmpty) {
          return commit.isEmpty ? version : '$version+$commit';
        }
        if (commit.isNotEmpty) return commit;
      }
    }
  } on Object {
    // 往下試 VERSION.txt
  }
  try {
    final file = File('$kitDir${sep}VERSION.txt');
    if (!await file.exists()) return '';
    final lines = await file.readAsLines();
    for (final line in lines) {
      if (line.trim().isNotEmpty) return line.trim();
    }
  } on Object {
    return '';
  }
  return '';
}

/// 執行器現在的設定，從 `config.json` **現讀**。不跨 session 快取。
final runnerConfigProvider = FutureProvider<RunnerConfigFile?>((ref) async {
  final kit = await ref.watch(runnerKitProvider.future);
  if (kit == null) return null;
  return readRunnerConfig(kit.configPath);
});

/// 執行器的 `state.json` 在哪。
///
/// 位置由 `config.json` 的 `state_dir` 決定；沒設就走執行器的預設
/// （`%LOCALAPPDATA%/UEP/Chatroom/runner`，與 `config.default_state_dir()`
/// 同一條規則）。推不出來就回 `null`——**不猜一個路徑**。
File? runnerStateFileFor(RunnerConfigFile cfg,
    [Map<String, String>? environment]) {
  final dir = runnerStateDirFor(cfg, environment);
  if (dir == null) return null;
  return File('$dir${Platform.pathSeparator}state.json');
}

/// 執行器的狀態根目錄。推不出來就回 `null`——**不猜一個路徑**。
String? runnerStateDirFor(RunnerConfigFile cfg,
    [Map<String, String>? environment]) {
  if (cfg.stateDir.isNotEmpty) return cfg.stateDir;
  final env = environment ?? Platform.environment;
  final sep = Platform.pathSeparator;
  final local = env['LOCALAPPDATA'] ?? '';
  if (local.isNotEmpty) return [local, 'UEP', 'Chatroom', 'runner'].join(sep);
  final home = env['HOME'] ?? '';
  if (home.isEmpty) return null;
  return [home, '.local', 'share', 'uep', 'chatroom', 'runner'].join(sep);
}

/// 執行器起 claude 時用的 `CLAUDE_CONFIG_DIR`。
///
/// 沒設 `claude_config_dir` 時是 `<state_dir>/claude-config`——與
/// `config.load_config()` 同一條規則。**這裡跟著算**：算錯的症狀是勾選清單
/// 列出使用者自己的 MCP，而執行器面對的是另一組伺服器。
String? runnerClaudeConfigDirFor(RunnerConfigFile cfg,
    [Map<String, String>? environment]) {
  if (cfg.claudeConfigDir.isNotEmpty) return cfg.claudeConfigDir;
  final dir = runnerStateDirFor(cfg, environment);
  if (dir == null) return null;
  return '$dir${Platform.pathSeparator}claude-config';
}

/// 本機執行器在 Hub 上的 `runner_id`，從 `state.json` 現讀。
///
/// **拿不到就是拿不到**：回 `null`，畫面少一個「套用到執行器」的動作，
/// 而不是對著一個猜出來的 id 發命令。
final runnerIdProvider = FutureProvider<String?>((ref) async {
  final cfg = await ref.watch(runnerConfigProvider.future);
  if (cfg == null) return null;
  final file = runnerStateFileFor(cfg);
  if (file == null) return null;
  try {
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString());
    if (json is! Map) return null;
    final id = (json['runner_id'] as String?) ?? '';
    return id.isEmpty ? null : id;
  } on Object {
    return null;
  }
});

/// `claude mcp list` 的一行：`<name>: <url or command> - <狀態>`。
///
/// 🔴 **與執行器 `run._MCP_LIST_RE` 是同一條規則**：勾選介面列出來的名字，
/// 就是執行器拿去比對允許清單的那個名字。兩邊分頭改的話，畫面上勾得到的
/// 伺服器與 run 真正放行的伺服器會是兩份清單，而沒有地方會報錯。
final RegExp _mcpListLine = RegExp(r'^(\S.*?): (.+?) - [✔!✘]');

/// 從 `claude mcp list` 的輸出撈出伺服器顯示名（連接器與本機 stdio 都算）。
List<String> parseClaudeMcpList(String text) {
  final names = <String>[];
  for (final line in const LineSplitter().convert(text)) {
    final m = _mcpListLine.firstMatch(line.trim());
    if (m == null) continue;
    final name = m.group(1)!;
    if (!names.contains(name)) names.add(name);
  }
  return names;
}

/// 列清單的上限。連不上的連接器一個要等 30 秒健康檢查，十幾個排下來很久
/// ——與執行器的 `run.MCP_LIST_TIMEOUT_SECONDS` 同一個數字。
const Duration kMcpListTimeout = Duration(seconds: 90);

/// 這台機器的 MCP 清單，以及沒問到時的原因。
///
/// 🔴 **失敗不丟例外**：provider 一丟例外，Riverpod 會自己重試，畫面就一直
/// 停在「正在讀…」，而「讀不到」這件事永遠不會被說出來。所以把失敗當成一種
/// 結果帶回去。空清單也不是答案——`error` 有東西時，畫面不准說某個名字
/// 「本機找不到」，那是「我們沒問到」。
@immutable
class MachineMcpServers {
  const MachineMcpServers({this.names, this.error = ''});

  /// 本機列到的伺服器；`null` ＝這次沒問到（不是「一台都沒有」）。
  final List<String>? names;

  /// 沒問到的原因，要給使用者看的那一句。
  final String error;
}

/// 這台機器上 `claude mcp list` 看得到的 MCP 伺服器名稱。
///
/// **一定要在執行器自己的 `CLAUDE_CONFIG_DIR` 底下列**：跟著登入進來的
/// claude.ai 連接器是綁設定目錄的，不在任何 `.claude.json` 的 `mcpServers`
/// 裡；拿使用者的目錄去列，列到的是另一組伺服器。
Future<MachineMcpServers> listMachineMcpServers(RunnerConfigFile cfg) async {
  final argv = cfg.claudeBin.isEmpty ? const ['claude'] : cfg.claudeBin;
  final configDir = runnerClaudeConfigDirFor(cfg) ?? '';
  ProcessResult result;
  try {
    result = await Process.run(
      argv.first,
      [...argv.skip(1), 'mcp', 'list'],
      // `includeParentEnvironment` 留著預設的 true：claude 要的是整組
      // 使用者環境（PATH、登入資訊），只給一個鍵它連自己都找不到
      environment: {
        if (configDir.isNotEmpty) 'CLAUDE_CONFIG_DIR': configDir,
      },
      // Windows 上 claude 是 .cmd，不走 shell 叫不起來
      runInShell: true,
    ).timeout(kMcpListTimeout);
  } on Object catch (e) {
    return MachineMcpServers(error: '$e');
  }
  final text = '${result.stdout}\n${result.stderr}';
  final names = parseClaudeMcpList(text);
  if (names.isEmpty) {
    // 健康檢查逾時、沒登入、claude 版本對不上都長這樣
    return MachineMcpServers(
        error: text.trim().isEmpty
            ? 'claude mcp list exit ${result.exitCode}'
            : text.trim().split('\n').last.trim());
  }
  return MachineMcpServers(names: names);
}

/// 這台機器現在看得到的 MCP 伺服器。重讀＝`ref.invalidate`。
final machineMcpServersProvider =
    FutureProvider<MachineMcpServers>((ref) async {
  final cfg = await ref.watch(runnerConfigProvider.future);
  if (cfg == null) return const MachineMcpServers(names: []);
  return listMachineMcpServers(cfg);
});
