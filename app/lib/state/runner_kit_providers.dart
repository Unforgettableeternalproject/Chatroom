import 'dart:async';
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

/// 執行器那個設定目錄底下，claude 登入了沒。
@immutable
class RunnerClaudeLogin {
  const RunnerClaudeLogin({
    required this.configDir,
    required this.loggedIn,
    this.expired = false,
    this.tokenSet = false,
  });

  /// 執行器起 claude 時用的 `CLAUDE_CONFIG_DIR`。
  final String configDir;

  final bool loggedIn;

  /// 登入過、但現在不能用（憑證還在而 claude 說沒登入，或 `mcp list` 說
  /// OAuth 過期）。只有 `loggedIn` 為 false 時有意義。
  final bool expired;

  /// 狀態目錄下有沒有長效 token 檔（[kRunnerOAuthTokenFileName]）。
  /// **只有有／沒有**：token 本身不進這個物件，畫面也就拿不到它。
  final bool tokenSet;

  /// 沒登入時要人去打的那一行。`CLAUDE_CONFIG_DIR` **一定要帶**：執行器用
  /// 的是自己的設定目錄，在別的目錄登入等於沒登入。
  String get loginCommand =>
      '\$env:CLAUDE_CONFIG_DIR = "$configDir"; claude auth login';
}

/// 這個設定目錄底下看不看得到登入憑證。
///
/// 🔴 **與 `runner-kit/install.py` 的 `has_claude_login()` 同一份判準**：
/// `.credentials.json`（Claude Code 寫在 `CLAUDE_CONFIG_DIR` 根下），舊版本
/// 把帳號記在 `.claude.json` 的 `oauthAccount`。兩邊分頭改的話，安裝器與
/// App 會對同一台機器講出相反的話。
///
/// 只是痕跡偵測：讀不到就回 `false`——**寧可多叫一次登入**，也不要顯示
/// 「已登入」而執行器第一筆單就因為沒登入而炸掉。
///
/// ⚠️ 痕跡在不代表能用：OAuth 過期且 refresh 失敗時檔案照樣在。所以這只是
/// [probeClaudeAuthStatus] 問不到時的退路，見 [resolveRunnerClaudeLogin]。
Future<bool> hasClaudeLogin(String claudeConfigDir) async {
  if (claudeConfigDir.isEmpty) return false;
  final sep = Platform.pathSeparator;
  try {
    final cred = File('$claudeConfigDir$sep.credentials.json');
    if (await cred.exists() && await cred.length() > 2) return true;
  } on Object {
    return false;
  }
  try {
    final json =
        jsonDecode(await File('$claudeConfigDir$sep.claude.json').readAsString());
    return json is Map && (json['oauthAccount'] != null);
  } on Object {
    return false;
  }
}

/// 長效 token 檔名。🔴 **與執行器的契約**：執行器讀 `<state_dir>` 底下這個
/// 檔，有的話把內容當 `CLAUDE_CODE_OAUTH_TOKEN` 帶給 claude。不可改名。
const String kRunnerOAuthTokenFileName = 'claude-oauth-token';

/// 長效 token 檔的位置：與 `claude-config` 同層，在執行器的狀態目錄下。
/// 推不出狀態目錄就回 `null`。
File? runnerOAuthTokenFileFor(RunnerConfigFile cfg,
    [Map<String, String>? environment]) {
  final dir = runnerStateDirFor(cfg, environment);
  if (dir == null || dir.isEmpty) return null;
  return File('$dir${Platform.pathSeparator}$kRunnerOAuthTokenFileName');
}

/// 讀長效 token：第一個非空行、去頭尾空白。沒有檔、讀不到或是空的都回
/// `null`。🔴 回傳值只拿去當環境變數，**不得顯示、不得進 log**。
Future<String?> readRunnerOAuthToken(File file) async {
  try {
    if (!await file.exists()) return null;
    for (final line in await file.readAsLines()) {
      final t = line.trim();
      if (t.isNotEmpty) return t;
    }
  } on Object {
    return null;
  }
  return null;
}

/// 寫入長效 token。內容只有 token 一行（去頭尾空白，**不帶結尾換行**）。
///
/// 貼上時常夾帶換行或前後空白；去掉之後中間還有空白的不是 token，丟
/// [FormatException]——訊息裡**不放 token 本身**。
Future<void> writeRunnerOAuthToken(File file, String token) async {
  final t = token.trim();
  if (t.isEmpty || RegExp(r'\s').hasMatch(t)) {
    throw const FormatException('invalid token');
  }
  await file.parent.create(recursive: true);
  await file.writeAsString(t, flush: true);
}

/// 清除長效 token。沒有檔就當已清除。
Future<void> clearRunnerOAuthToken(File file) async {
  if (await file.exists()) await file.delete();
}

/// 從 `claude auth status --json` 的輸出取 `loggedIn`。
///
/// 沒登入時 claude 的 exit code 是 1，但 stdout 照樣是 JSON——**不看 exit
/// code，只看內容**。看不懂（不是 JSON、沒有布林的 `loggedIn`）回 `null`，
/// 讓呼叫端退回檔案判準。
bool? parseClaudeAuthStatus(String text) {
  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    final json = jsonDecode(text.substring(start, end + 1));
    if (json is! Map) return null;
    final v = json['loggedIn'];
    return v is bool ? v : null;
  } on Object {
    return null;
  }
}

/// claude 說 OAuth 過期、refresh 不回來的那幾句。
///
/// 這時 `auth status` 不一定會說沒登入（憑證檔還在），問題只在真的要用的
/// 時候冒出來——`mcp list` 就是其中之一。
bool isClaudeAuthExpiredText(String text) {
  final t = text.toLowerCase();
  return t.contains('oauth session expired') ||
      t.contains('could not be refreshed');
}

/// `claude auth status` 的上限。只問本機狀態，不必等 `mcp list` 那麼久。
const Duration kAuthStatusTimeout = Duration(seconds: 20);

/// 問 claude 自己：在執行器的設定目錄下（有 token 也帶上）登入了沒。
///
/// 叫法與 [listMachineMcpServers] 相同。叫不起來、逾時、看不懂都回 `null`。
Future<bool?> probeClaudeAuthStatus(RunnerConfigFile cfg,
    {String? oauthToken}) async {
  final argv = cfg.claudeBin.isEmpty ? const ['claude'] : cfg.claudeBin;
  final configDir = runnerClaudeConfigDirFor(cfg) ?? '';
  try {
    final result = await Process.run(
      argv.first,
      [...argv.skip(1), 'auth', 'status', '--json'],
      environment: {
        if (configDir.isNotEmpty) 'CLAUDE_CONFIG_DIR': configDir,
        if (oauthToken != null && oauthToken.isNotEmpty)
          'CLAUDE_CODE_OAUTH_TOKEN': oauthToken,
      },
      runInShell: true,
    ).timeout(kAuthStatusTimeout);
    return parseClaudeAuthStatus('${result.stdout}');
  } on Object {
    return null;
  }
}

typedef ClaudeAuthProbe = Future<bool?> Function(RunnerConfigFile cfg,
    {String? oauthToken});

/// 實際去問 claude 的那一支。測試覆寫它，免得在測試裡叫這台機器的 claude。
final claudeAuthProbeProvider =
    Provider<ClaudeAuthProbe>((ref) => probeClaudeAuthStatus);

/// 綜合判斷執行器的登入狀態。
///
/// 1. 問 `claude auth status`（[probe]）；問得到就以它為準。
/// 2. 問不到才退回檔案判準 [hasClaudeLogin]，有 token 檔也算。
/// 3. `mcp list` 說 OAuth 過期（[mcpAuthExpired]）時判為失效——但**有 token
///    檔時不降級**：執行器跑單用的是 token，設定目錄裡那份 OAuth 過期不影響
///    它接單（MCP 區塊仍會自己顯示過期）。
///
/// 判為失效而設定目錄裡有憑證痕跡時標 `expired`，畫面說「已過期」而不是
/// 「尚未登入」。
Future<RunnerClaudeLogin> resolveRunnerClaudeLogin({
  required RunnerConfigFile cfg,
  required String configDir,
  required ClaudeAuthProbe probe,
  File? tokenFile,
  bool mcpAuthExpired = false,
}) async {
  final token = tokenFile == null ? null : await readRunnerOAuthToken(tokenFile);
  final tokenSet = token != null;
  final probed = await probe(cfg, oauthToken: token);
  final traces = await hasClaudeLogin(configDir);
  var loggedIn = probed ?? (traces || tokenSet);
  if (mcpAuthExpired && !tokenSet) loggedIn = false;
  return RunnerClaudeLogin(
    configDir: configDir,
    loggedIn: loggedIn,
    expired: !loggedIn && (traces || mcpAuthExpired),
    tokenSet: tokenSet,
  );
}

/// 執行器的 claude 登入狀態。推不出設定目錄就回 `null`（畫面少一列，
/// 而不是對著一個猜出來的路徑說「尚未登入」）。
///
/// 重新判斷要**連同 [machineMcpServersProvider] 一起 invalidate**，否則上一次
/// `mcp list` 的過期旗標會一直把結果壓成失效。
final runnerClaudeLoginProvider =
    FutureProvider<RunnerClaudeLogin?>((ref) async {
  // 不 await `mcp list`（最長 90 秒）：它晚到時這裡再算一次。重讀中不算——
  // 重讀時 AsyncValue 還留著上一次的值，登入完按重新檢查會被舊旗標壓住
  final mcpExpired = ref.watch(machineMcpServersProvider
      .select((v) => !v.isLoading && (v.value?.authExpired ?? false)));
  final probe = ref.watch(claudeAuthProbeProvider);
  final cfg = await ref.watch(runnerConfigProvider.future);
  if (cfg == null) return null;
  final dir = runnerClaudeConfigDirFor(cfg) ?? '';
  if (dir.isEmpty) return null;
  return resolveRunnerClaudeLogin(
    cfg: cfg,
    configDir: dir,
    probe: probe,
    tokenFile: runnerOAuthTokenFileFor(cfg),
    mcpAuthExpired: mcpExpired,
  );
});

/// 在新的終端視窗裡跑 claude 的 PowerShell 指令稿。
///
/// 路徑用單引號字串（PowerShell 單引號裡只有 `'` 要變成 `''`）。
String claudeTerminalScript(String configDir, List<String> claudeArgs) {
  final dir = configDir.replaceAll("'", "''");
  return "\$env:CLAUDE_CONFIG_DIR = '$dir'; claude ${claudeArgs.join(' ')}";
}

/// 開新終端視窗的 argv：
/// `cmd /c start "" /wait powershell -NoExit -EncodedCommand <base64>`。
///
/// 指令稿走 `-EncodedCommand`（UTF-16LE 的 base64），避開 cmd、start、
/// powershell 三層各自的引號規則。`/wait` 讓 cmd 等到那個視窗關掉才結束，
/// 呼叫端才知道什麼時候該重新判斷。
List<String> claudeTerminalArgv(String script) {
  final bytes = <int>[];
  for (final u in script.codeUnits) {
    bytes
      ..add(u & 0xFF)
      ..add(u >> 8);
  }
  return [
    'cmd',
    '/c',
    'start',
    '',
    '/wait',
    'powershell',
    '-NoExit',
    '-EncodedCommand',
    base64.encode(bytes),
  ];
}

/// 開一個看得到的終端視窗跑 `claude <claudeArgs>`，等視窗關掉才回來。
///
/// 不用 detached：detached 拿不到結束時機，而「視窗關了就重新判斷」要靠它。
Future<void> openClaudeTerminal(
    String configDir, List<String> claudeArgs) async {
  final argv = claudeTerminalArgv(claudeTerminalScript(configDir, claudeArgs));
  final process = await Process.start(argv.first, argv.sublist(1));
  // cmd 本身沒有輸出；照樣放掉，免得管線塞住
  unawaited(process.stdout.drain<void>());
  unawaited(process.stderr.drain<void>());
  await process.exitCode;
}

/// 開終端視窗的那一支。測試覆寫它，免得真的開出視窗。
final claudeTerminalLauncherProvider =
    Provider<Future<void> Function(String configDir, List<String> claudeArgs)>(
        (ref) => openClaudeTerminal);

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
  const MachineMcpServers({
    this.names,
    this.error = '',
    this.origins = const {},
    this.globalError = '',
    this.complete = true,
    this.authExpired = false,
  });

  /// 本機列到的伺服器；`null` ＝這次沒問到（不是「一台都沒有」）。
  final List<String>? names;

  /// 沒問到的原因，要給使用者看的那一句。
  final String error;

  /// 每個名字是從哪一邊來的。重複的名字以全域為準（畫面只列一次）。
  final Map<String, McpServerOrigin> origins;

  /// 全域 `.claude.json` 讀不到的原因；空字串＝讀到了。
  final String globalError;

  /// 兩邊都問到了。🔴 只有這時候畫面才能說某個名字「本機找不到」——
  /// 少問到一邊時，缺的那些很可能就在沒問到的那一邊。
  final bool complete;

  /// `claude mcp list` 說執行器的 OAuth 過期、refresh 不回來。這時 [error]
  /// 是 claude 的原文，畫面改講「執行器登入已過期」。
  final bool authExpired;
}

/// 一台 MCP 伺服器是從哪裡來的。
///
/// 兩邊問到的是**不同的東西**：連接器綁執行器的設定目錄，只有
/// `claude mcp list` 問得到；fff、mempal 這種自訂 stdio 伺服器只寫在使用者
/// 全域 `.claude.json` 的 `mcpServers` 裡，執行器的設定目錄看不到它們。
enum McpServerOrigin { connector, global }

/// 使用者全域 `.claude.json`。
///
/// `CLAUDE_CONFIG_DIR` 有設而且那裡真的有檔案就用它（人類把設定搬走的
/// 情況），否則是家目錄底下那一份（Windows 是 `%USERPROFILE%`）。
/// **與執行器 `run.global_config_path()` 是同一條規則**：畫面上勾得到的
/// 名字，就是 run 組 mcp.json 時找得到定義的名字。
File? globalClaudeConfigFile() {
  final env = Platform.environment;
  final dir = (env['CLAUDE_CONFIG_DIR'] ?? '').trim();
  final sep = Platform.pathSeparator;
  if (dir.isNotEmpty) {
    final moved = File('$dir$sep.claude.json');
    if (moved.existsSync()) return moved;
  }
  final home = env['USERPROFILE'] ?? env['HOME'] ?? '';
  if (home.isEmpty) return null;
  return File('$home$sep.claude.json');
}

/// 全域 `.claude.json` 的 `mcpServers` 名字，以及讀不到時的原因。
///
/// 🔴 **讀不到不是空清單**：回 `null` 讓畫面說「這一邊沒問到」，而不是
/// 讓人以為自己機器上沒有那些伺服器。
Future<MachineMcpServers> readGlobalMcpServers({File? file}) async {
  final f = file ?? globalClaudeConfigFile();
  if (f == null) return const MachineMcpServers(globalError: 'no home dir');
  try {
    if (!await f.exists()) return MachineMcpServers(globalError: f.path);
    final json = jsonDecode(await f.readAsString());
    if (json is! Map) return MachineMcpServers(globalError: f.path);
    final servers = json['mcpServers'];
    if (servers is! Map) return const MachineMcpServers(names: []);
    return MachineMcpServers(
        names: servers.keys.map((e) => '$e').toList()..sort());
  } on Object catch (e) {
    return MachineMcpServers(globalError: '$e');
  }
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
  // 過期那句不一定在最後一行（後面常接著 "No MCP servers configured"），
  // 要對全文找
  final expired = isClaudeAuthExpiredText(text);
  if (names.isEmpty) {
    // 健康檢查逾時、沒登入、claude 版本對不上都長這樣
    return MachineMcpServers(
        authExpired: expired,
        error: text.trim().isEmpty
            ? 'claude mcp list exit ${result.exitCode}'
            : text.trim().split('\n').last.trim());
  }
  return MachineMcpServers(names: names, authExpired: expired);
}

/// 兩邊合併成一份清單：連接器（執行器設定目錄）＋全域 `.claude.json`。
///
/// 重複的名字**以全域為準**：run 的 mcp.json 帶得進去的是全域那一份定義，
/// 畫面標的來源要跟實際載入的那一份一致。
MachineMcpServers mergeMcpServers(
    MachineMcpServers connectors, MachineMcpServers global) {
  if (connectors.names == null && global.names == null) {
    return MachineMcpServers(
        error: connectors.error,
        globalError: global.globalError,
        authExpired: connectors.authExpired);
  }
  final origins = <String, McpServerOrigin>{};
  for (final name in connectors.names ?? const <String>[]) {
    origins[name] = McpServerOrigin.connector;
  }
  for (final name in global.names ?? const <String>[]) {
    origins[name] = McpServerOrigin.global;
  }
  return MachineMcpServers(
      names: origins.keys.toList(),
      origins: origins,
      error: connectors.error,
      globalError: global.globalError,
      complete: connectors.names != null && global.names != null,
      authExpired: connectors.authExpired);
}

/// 這台機器現在看得到的 MCP 伺服器。重讀＝`ref.invalidate`。
final machineMcpServersProvider =
    FutureProvider<MachineMcpServers>((ref) async {
  final cfg = await ref.watch(runnerConfigProvider.future);
  final global = await readGlobalMcpServers();
  if (cfg == null) {
    return mergeMcpServers(const MachineMcpServers(names: []), global);
  }
  return mergeMcpServers(await listMachineMcpServers(cfg), global);
});
