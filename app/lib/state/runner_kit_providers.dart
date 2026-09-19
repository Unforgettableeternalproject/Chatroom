import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/host_kit.dart' show KitSource;

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

/// `config.json` 裡的一個專案。
///
/// `public` 預設 **true**、`allowBrowserLivetest` 預設 **false**——與
/// `runner/chatroom_runner/config.py` 的 `ProjectConfig` 同一組預設值。
/// 兩邊不一樣的話，同一份設定在畫面與執行器眼裡會是兩種意思。
@immutable
class RunnerProject {
  const RunnerProject({
    required this.key,
    this.public = true,
    this.allowBrowserLivetest = false,
    this.repos = const {},
    this.defaultRepo = '',
    this.skillDirs = const [],
  });

  final String key;

  /// 要不要讓別人在派工對話框看到這個專案。
  final bool public;

  /// 這個專案的 run 可不可以開瀏覽器做實機測試。
  final bool allowBrowserLivetest;

  /// repo 名 → 路徑。
  final Map<String, String> repos;
  final String defaultRepo;
  final List<String> skillDirs;

  factory RunnerProject.fromJson(String key, Map<String, dynamic> json) {
    final reposRaw = json['repos'];
    final repos = <String, String>{};
    if (reposRaw is Map) {
      for (final e in reposRaw.entries) {
        final v = e.value;
        repos[e.key.toString()] =
            v is Map ? (v['path']?.toString() ?? '') : v.toString();
      }
    }
    return RunnerProject(
      key: key,
      public: json['public'] is bool ? json['public'] as bool : true,
      allowBrowserLivetest: json['allow_browser_livetest'] is bool
          ? json['allow_browser_livetest'] as bool
          : false,
      repos: repos,
      defaultRepo: (json['default_repo'] as String?) ?? '',
      skillDirs: ((json['skill_dirs'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
    );
  }
}

/// 現讀出來的 `config.json`。
///
/// `raw` 是**整份原樣**的解析結果：寫回時要從它改，沒被表單碰到的欄位
/// （這一版還不認得的新設定）才不會在存檔時消失。
@immutable
class RunnerConfigFile {
  const RunnerConfigFile({
    required this.path,
    required this.raw,
    required this.projects,
    required this.modified,
    this.host = '',
    this.label = '',
    this.stateDir = '',
  });

  final String path;
  final Map<String, dynamic> raw;
  final List<RunnerProject> projects;

  /// 讀到這一份時檔案的 mtime。寫回前再比一次——這中間有人手改過的話，
  /// 靜默覆寫等於把他剛寫的東西吃掉。
  final DateTime modified;

  final String host;
  final String label;

  /// `state_dir`（空＝走執行器的預設位置）。`state.json` 在它底下。
  final String stateDir;
}

/// 外部改動撞上存檔。
class RunnerConfigConflict implements Exception {
  const RunnerConfigConflict();

  @override
  String toString() => 'RunnerConfigConflict';
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

/// 讀一份 `config.json`。讀不到或形狀不對回 `null`。
Future<RunnerConfigFile?> readRunnerConfig(String path) async {
  final file = File(path);
  try {
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString());
    if (json is! Map) return null;
    final raw = json.cast<String, dynamic>();
    final projectsRaw = raw['projects'];
    final projects = <RunnerProject>[];
    if (projectsRaw is Map) {
      for (final e in projectsRaw.entries) {
        final v = e.value;
        if (v is Map) {
          projects.add(
              RunnerProject.fromJson(e.key.toString(), v.cast<String, dynamic>()));
        }
      }
    }
    return RunnerConfigFile(
      path: path,
      raw: raw,
      projects: projects,
      modified: await file.lastModified(),
      host: (raw['host'] as String?) ?? '',
      label: (raw['label'] as String?) ?? '',
      stateDir: (raw['state_dir'] as String?) ?? '',
    );
  } on Object {
    return null;
  }
}

/// 把表單改過的欄位寫回 `config.json`。
///
/// 🔴 **只動被碰到的鍵**：整份重新組一個物件的話，這一版還不認得的設定
/// （執行器加了新欄位、使用者手寫的其他專案參數）會在存檔那一刻消失。
/// 這裡是讀出整份 JSON → 改那幾個鍵 → 寫回，格式化風格會被 `JsonEncoder`
/// 重排（JSON 沒有註解，這是已知且接受的代價），但**沒有任何鍵會掉**。
///
/// 寫法是**先寫暫存檔再 rename**：中途斷電時留下的是完整的舊檔，
/// 不是一份被截斷的設定——執行器讀不到設定是起不來的等級。
///
/// 存檔前再讀一次 mtime：對不上就丟 [RunnerConfigConflict]，由呼叫端提示
/// 重新整理。沒有鎖，靜默覆寫會把別人（或使用者自己手改）的那一版吃掉。
Future<void> saveRunnerProject(
  RunnerConfigFile cfg, {
  required String projectKey,
  bool? public,
  bool? allowBrowserLivetest,
  List<String>? skillDirs,
}) async {
  final file = File(cfg.path);
  final now = await file.lastModified();
  if (now != cfg.modified) throw const RunnerConfigConflict();

  final json = jsonDecode(await file.readAsString());
  if (json is! Map) throw const RunnerConfigConflict();
  final raw = json.cast<String, dynamic>();
  final projectsRaw = raw['projects'];
  if (projectsRaw is! Map) throw const RunnerConfigConflict();
  final projectRaw = projectsRaw[projectKey];
  if (projectRaw is! Map) throw const RunnerConfigConflict();

  if (public != null) projectRaw['public'] = public;
  if (allowBrowserLivetest != null) {
    projectRaw['allow_browser_livetest'] = allowBrowserLivetest;
  }
  if (skillDirs != null) projectRaw['skill_dirs'] = skillDirs;

  const encoder = JsonEncoder.withIndent('  ');
  final tmp = File('${cfg.path}.tmp');
  await tmp.writeAsString('${encoder.convert(raw)}\n');
  await tmp.rename(cfg.path);
}

/// 本機執行器在 Hub 上的 `runner_id`，從 `state.json` 現讀。
///
/// 位置由 `config.json` 的 `state_dir` 決定；沒設就走執行器的預設
/// （`%LOCALAPPDATA%/UEP/Chatroom/runner`，與 `config.default_state_dir()`
/// 同一條規則）。**拿不到就是拿不到**：回 `null`，畫面少一個「套用到執行器」
/// 的動作，而不是對著一個猜出來的 id 發命令。
final runnerIdProvider = FutureProvider<String?>((ref) async {
  final cfg = await ref.watch(runnerConfigProvider.future);
  if (cfg == null) return null;
  final sep = Platform.pathSeparator;
  var dir = cfg.stateDir;
  if (dir.isEmpty) {
    final local = Platform.environment['LOCALAPPDATA'] ?? '';
    if (local.isNotEmpty) {
      dir = [local, 'UEP', 'Chatroom', 'runner'].join(sep);
    } else {
      final home = Platform.environment['HOME'] ?? '';
      if (home.isEmpty) return null;
      dir = [home, '.local', 'share', 'uep', 'chatroom', 'runner'].join(sep);
    }
  }
  try {
    final file = File('$dir${sep}state.json');
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString());
    if (json is! Map) return null;
    final id = (json['runner_id'] as String?) ?? '';
    return id.isEmpty ? null : id;
  } on Object {
    return null;
  }
});
