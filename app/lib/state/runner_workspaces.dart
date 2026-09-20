import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 執行器 `config.json` 的「工作區／專案」兩層資料層。
///
/// ## 兩層是什麼
///
/// - **工作區**（頂層 `workspaces`，舊鍵 `projects`）：外層資料夾的概念，
///   派工時 Hub 認得的那個 key；它自己不是 git repo。
/// - **專案**（工作區內的 `projects`，舊鍵 `repos`）：一個 git repo 的路徑。
///
/// 舊鍵是**讀**得進來的（同一份設定在新舊版執行器之間要能混著用），但
/// [RunnerWorkspace.toJson] 一律只寫新鍵。原地改檔的 CRUD 則沿用檔案裡**既有**
/// 的鍵名——別人手寫的 `repos` 不該在我們加一個專案時被悄悄換名字。

/// 工作區裡的一個專案。就是一個 git repo。
@immutable
class RunnerProject {
  const RunnerProject({
    required this.path,
    this.allowedBranches = const [],
    this.pushBranches = const [],
  });

  /// repo 的絕對路徑。
  final String path;

  /// 允許 checkout 的分支；空＝不限制。
  final List<String> allowedBranches;

  /// 允許推上去的分支；空＝不允許推。
  final List<String> pushBranches;

  factory RunnerProject.fromJson(Object? json) {
    // 舊設定有人把值直接寫成路徑字串，不是物件
    if (json is String) return RunnerProject(path: json);
    if (json is! Map) return const RunnerProject(path: '');
    return RunnerProject(
      path: json['path']?.toString() ?? '',
      allowedBranches: _stringList(json['allowed_branches']),
      pushBranches: _stringList(json['push_branches']),
    );
  }

  Map<String, dynamic> toJson() => {
        'path': path,
        if (allowedBranches.isNotEmpty) 'allowed_branches': allowedBranches,
        if (pushBranches.isNotEmpty) 'push_branches': pushBranches,
      };
}

/// `config.json` 裡的一個工作區。
///
/// `public` 預設 **true**、`allowBrowserLivetest` 預設 **false**——與
/// `runner/chatroom_runner/config.py` 同一組預設值。兩邊不一樣的話，同一份設定
/// 在畫面與執行器眼裡會是兩種意思，而沒有任何地方會報錯。
@immutable
class RunnerWorkspace {
  const RunnerWorkspace({
    required this.key,
    this.folder = '',
    this.public = true,
    this.allowBrowserLivetest = false,
    this.model = '',
    this.maxTurns = 0,
    this.maxBudgetUsd = 0,
    this.wallClockSeconds = 0,
    this.contextWindowTokens = 0,
    this.skillDirs = const [],
    this.primarySkill = '',
    this.defaultProject = '',
    this.projects = const {},
    this.extraWriteDirs = const [],
  });

  final String key;

  /// 工作區的外層資料夾；空＝沒登記。它自己不必是 git repo。
  final String folder;

  /// 要不要讓別人在派工對話框看到這個工作區。
  final bool public;

  /// 這個工作區的 run 可不可以開瀏覽器做實機測試。
  final bool allowBrowserLivetest;

  /// 以下四個是「沒設就是 0／空字串」＝**沿用執行器的預設值**。
  /// App 這邊不複製執行器的預設數字——複製了就會有兩份會走鐘的常數。
  final String model;
  final int maxTurns;
  final double maxBudgetUsd;
  final int wallClockSeconds;
  final int contextWindowTokens;

  final List<String> skillDirs;

  /// 優先載入的 skill，至多一個；空＝沒有。必須在 [skillDirs] 底下找得到。
  final String primarySkill;

  final String defaultProject;

  /// 專案名 → 專案。
  final Map<String, RunnerProject> projects;

  final List<String> extraWriteDirs;

  /// 新鍵優先、舊鍵退回：`projects`←`repos`、`default_project`←`default_repo`。
  factory RunnerWorkspace.fromJson(String key, Map<String, dynamic> json) {
    final projectsRaw = json['projects'] ?? json['repos'];
    final projects = <String, RunnerProject>{};
    if (projectsRaw is Map) {
      for (final e in projectsRaw.entries) {
        projects[e.key.toString()] = RunnerProject.fromJson(e.value);
      }
    }
    return RunnerWorkspace(
      key: key,
      folder: json['folder']?.toString() ?? '',
      public: json['public'] is bool ? json['public'] as bool : true,
      allowBrowserLivetest: json['allow_browser_livetest'] is bool
          ? json['allow_browser_livetest'] as bool
          : false,
      model: json['model']?.toString() ?? '',
      maxTurns: _int(json['max_turns']),
      maxBudgetUsd: _double(json['max_budget_usd']),
      wallClockSeconds: _int(json['wall_clock_seconds']),
      contextWindowTokens: _int(json['context_window_tokens']),
      skillDirs: _stringList(json['skill_dirs']),
      primarySkill: json['primary_skill']?.toString() ?? '',
      defaultProject:
          (json['default_project'] ?? json['default_repo'])?.toString() ?? '',
      projects: projects,
      extraWriteDirs: _stringList(json['extra_write_dirs']),
    );
  }

  /// **只寫新鍵**。沒設的數值欄位不寫出去，留給執行器的預設值。
  Map<String, dynamic> toJson() => {
        if (folder.isNotEmpty) 'folder': folder,
        'public': public,
        'allow_browser_livetest': allowBrowserLivetest,
        if (model.isNotEmpty) 'model': model,
        if (maxTurns > 0) 'max_turns': maxTurns,
        if (maxBudgetUsd > 0) 'max_budget_usd': maxBudgetUsd,
        if (wallClockSeconds > 0) 'wall_clock_seconds': wallClockSeconds,
        if (contextWindowTokens > 0)
          'context_window_tokens': contextWindowTokens,
        if (skillDirs.isNotEmpty) 'skill_dirs': skillDirs,
        if (primarySkill.isNotEmpty) 'primary_skill': primarySkill,
        if (defaultProject.isNotEmpty) 'default_project': defaultProject,
        'projects': {
          for (final e in projects.entries) e.key: e.value.toJson(),
        },
        if (extraWriteDirs.isNotEmpty) 'extra_write_dirs': extraWriteDirs,
      };
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
    required this.workspaces,
    required this.modified,
    this.host = '',
    this.label = '',
    this.stateDir = '',
    this.allowedMcpServers = const [],
    this.claudeBin = const [],
    this.claudeConfigDir = '',
  });

  final String path;
  final Map<String, dynamic> raw;
  final List<RunnerWorkspace> workspaces;

  /// 讀到這一份時檔案的 mtime。寫回前再比一次——這中間有人手改過的話，
  /// 靜默覆寫等於把他剛寫的東西吃掉。
  final DateTime modified;

  final String host;
  final String label;

  /// `state_dir`（空＝走執行器的預設位置）。`state.json` 在它底下。
  final String stateDir;

  /// `allowed_mcp_servers`：**執行器層**的允許清單，整台共用一份，不是
  /// 工作區的設定。沒寫這一鍵時是空清單——它的意思是「沿用執行器的預設」
  /// （`config.DEFAULT_ALLOWED_MCP_SERVERS`＝只有 chatroom），不是「全開」。
  final List<String> allowedMcpServers;

  /// `claude_bin`（argv）。列本機 MCP 清單時要用同一支 claude。
  final List<String> claudeBin;

  /// `claude_config_dir`：執行器自己的 `CLAUDE_CONFIG_DIR`。
  /// **列清單一定要在這個目錄下列**——跟著登入進來的 claude.ai 連接器是
  /// 綁設定目錄的，拿使用者的目錄去列會列出另一台機器的答案。
  final String claudeConfigDir;
}

/// 外部改動撞上存檔。
class RunnerConfigConflict implements Exception {
  const RunnerConfigConflict();

  @override
  String toString() => 'RunnerConfigConflict';
}

/// 要求本身就不成立（路徑不存在、不是 git repo、skill 找不到……）。
///
/// 與 [RunnerConfigConflict] 分開：那個是「重讀一次再試」，這個是「你給的值
/// 不對，重試幾次都一樣」。
class RunnerConfigInvalid implements Exception {
  const RunnerConfigInvalid(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 讀一份 `config.json`。讀不到或形狀不對回 `null`。
Future<RunnerConfigFile?> readRunnerConfig(String path) async {
  final file = File(path);
  try {
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString());
    if (json is! Map) return null;
    final raw = json.cast<String, dynamic>();
    final workspacesRaw = raw['workspaces'] ?? raw['projects'];
    final workspaces = <RunnerWorkspace>[];
    if (workspacesRaw is Map) {
      for (final e in workspacesRaw.entries) {
        final v = e.value;
        if (v is Map) {
          workspaces.add(RunnerWorkspace.fromJson(
              e.key.toString(), v.cast<String, dynamic>()));
        }
      }
    }
    return RunnerConfigFile(
      path: path,
      raw: raw,
      workspaces: workspaces,
      modified: await file.lastModified(),
      host: (raw['host'] as String?) ?? '',
      label: (raw['label'] as String?) ?? '',
      stateDir: (raw['state_dir'] as String?) ?? '',
      allowedMcpServers: _stringList(raw['allowed_mcp_servers']),
      claudeBin: _argvList(raw['claude_bin']),
      claudeConfigDir: (raw['claude_config_dir'] as String?) ?? '',
    );
  } on Object {
    return null;
  }
}

/// 這個路徑是不是 git repo。
///
/// 判準就是 `<path>/.git` 存在——**目錄或檔案都算**：worktree 與 submodule 的
/// `.git` 是一個指標檔，不是目錄，只看目錄會把它們當成「不是 repo」。
Future<bool> isGitRepoDir(String path) async {
  if (path.trim().isEmpty) return false;
  final dot = '$path${Platform.pathSeparator}.git';
  return await Directory(dot).exists() || await File(dot).exists();
}

/// 掃 `skill_dirs` 底下有哪些 skill，給下拉用。
///
/// 位置與執行器的 `skill_manifest()` 同一條規則：
/// `<dir>/.claude/skills/<name>/SKILL.md`。回傳去重、排序後的名稱。
Future<List<String>> listRunnerSkills(List<String> skillDirs) async {
  final sep = Platform.pathSeparator;
  final names = <String>{};
  for (final dir in skillDirs) {
    if (dir.trim().isEmpty) continue;
    final root = Directory([dir, '.claude', 'skills'].join(sep));
    try {
      if (!await root.exists()) continue;
      await for (final entry in root.list(followLinks: false)) {
        if (entry is! Directory) continue;
        final name = entry.path.split(Platform.pathSeparator).last;
        if (await File('${entry.path}${sep}SKILL.md').exists()) {
          names.add(name);
        }
      }
    } on Object {
      // 讀不到的目錄就是沒有 skill，不讓它擋掉其他目錄
      continue;
    }
  }
  final sorted = names.toList()..sort();
  return sorted;
}

/// 某個 skill 在這組目錄裡找不找得到。
Future<bool> hasRunnerSkill(String name, List<String> skillDirs) async {
  if (name.trim().isEmpty) return false;
  final sep = Platform.pathSeparator;
  for (final dir in skillDirs) {
    if (dir.trim().isEmpty) continue;
    final manifest =
        File([dir, '.claude', 'skills', name, 'SKILL.md'].join(sep));
    if (await manifest.exists()) return true;
  }
  return false;
}

/// 把表單改過的欄位寫回工作區。
///
/// 🔴 **只動被碰到的鍵**：整份重新組一個物件的話，這一版還不認得的設定
/// （執行器加了新欄位、使用者手寫的其他參數）會在存檔那一刻消失。
///
/// `null` ＝ 不碰這個欄位；要清掉某個值就給空字串／空清單。
Future<void> saveRunnerWorkspace(
  RunnerConfigFile cfg, {
  required String workspaceKey,
  String? folder,
  bool? public,
  bool? allowBrowserLivetest,
  String? model,
  int? maxTurns,
  double? maxBudgetUsd,
  int? wallClockSeconds,
  int? contextWindowTokens,
  List<String>? skillDirs,
  List<String>? extraWriteDirs,
  String? defaultProject,
}) async {
  await _mutate(cfg, (raw) async {
    final ws = _workspaceRaw(raw, workspaceKey);
    if (folder != null) {
      if (folder.isNotEmpty && !await Directory(folder).exists()) {
        throw RunnerConfigInvalid('資料夾「$folder」不存在');
      }
      _put(ws, 'folder', folder.isEmpty ? null : folder);
    }
    if (public != null) ws['public'] = public;
    if (allowBrowserLivetest != null) {
      ws['allow_browser_livetest'] = allowBrowserLivetest;
    }
    if (model != null) _put(ws, 'model', model.isEmpty ? null : model);
    if (maxTurns != null) _put(ws, 'max_turns', maxTurns > 0 ? maxTurns : null);
    if (maxBudgetUsd != null) {
      _put(ws, 'max_budget_usd', maxBudgetUsd > 0 ? maxBudgetUsd : null);
    }
    if (wallClockSeconds != null) {
      _put(ws, 'wall_clock_seconds',
          wallClockSeconds > 0 ? wallClockSeconds : null);
    }
    if (contextWindowTokens != null) {
      _put(ws, 'context_window_tokens',
          contextWindowTokens > 0 ? contextWindowTokens : null);
    }
    if (skillDirs != null) ws['skill_dirs'] = skillDirs;
    if (extraWriteDirs != null) ws['extra_write_dirs'] = extraWriteDirs;
    if (defaultProject != null) {
      if (defaultProject.isEmpty) {
        ws.remove('default_project');
        ws.remove('default_repo');
      } else {
        final projects = _projectsRaw(ws, create: false);
        if (projects == null || !projects.containsKey(defaultProject)) {
          throw RunnerConfigInvalid(
              '預設專案「$defaultProject」不在工作區「$workspaceKey」裡');
        }
        // 檔案裡原本用哪個鍵就寫哪個，不順手改名
        if (ws.containsKey('default_repo') &&
            !ws.containsKey('default_project')) {
          ws['default_repo'] = defaultProject;
        } else {
          ws['default_project'] = defaultProject;
        }
      }
    }
  });
}

/// 設定（或清掉）工作區的優先載入 skill。
///
/// 驗證與執行器 `skill_manifest()` 同一條規則：要在這個工作區的 `skill_dirs`
/// 底下找得到 `.claude/skills/<name>/SKILL.md`。找不到就拒絕——寫進去的話，
/// 執行器下次讀設定會直接起不來。
Future<void> setRunnerPrimarySkill(
  RunnerConfigFile cfg, {
  required String workspaceKey,
  required String skill,
}) async {
  final name = skill.trim();
  await _mutate(cfg, (raw) async {
    final ws = _workspaceRaw(raw, workspaceKey);
    if (name.isEmpty) {
      ws.remove('primary_skill');
      return;
    }
    final dirs = _stringList(ws['skill_dirs']);
    if (!await hasRunnerSkill(name, dirs)) {
      final where = dirs.isEmpty ? '（沒有設定 skill_dirs）' : dirs.join('、');
      throw RunnerConfigInvalid(
          'skill「$name」在 $where 底下找不到 .claude/skills/$name/SKILL.md');
    }
    ws['primary_skill'] = name;
  });
}

/// 執行器層的「允許 run 使用的 MCP 伺服器」。
///
/// 🔴 **chatroom 一定在裡面**：run 靠它進房領卡、回報階段，被自己的允許清單
/// 擋掉的話那一輪只會盲做（執行器端 `DEFAULT_ALLOWED_MCP_SERVERS` 也是它）。
/// 所以這裡不信任呼叫端傳什麼，一律補上去。
///
/// 名稱**照 `claude mcp list` 顯示的原樣**寫（例如 `claude.ai Gmail`）：
/// 執行器比對時才會把它換算成工具名裡的 server 段（`claude_ai_Gmail`）。
Future<void> saveRunnerAllowedMcpServers(
  RunnerConfigFile cfg, {
  required List<String> servers,
}) async {
  final names = <String>[kRunnerRequiredMcpServer];
  for (final name in servers) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || names.contains(trimmed)) continue;
    names.add(trimmed);
  }
  await _mutate(cfg, (raw) async {
    raw['allowed_mcp_servers'] = names;
  });
}

/// 永遠勾著、拿不掉的那一台。
const String kRunnerRequiredMcpServer = 'chatroom';

/// 新增一個工作區（登記既有資料夾）。
///
/// `folder` 是工作區的外層資料夾，**必須已經存在**；它自己不必是 git repo。
/// 工作區至少要有一個專案，否則執行器讀設定就會炸（`沒有任何 repo`）——所以
/// 這裡要嘛給 `projectName`／`projectPath`，要嘛 `folder` 自己就是 git repo
/// （那就用它當第一個專案，名稱取資料夾名）。
Future<void> addRunnerWorkspace(
  RunnerConfigFile cfg, {
  required String key,
  required String folder,
  String projectName = '',
  String projectPath = '',
}) async {
  final wsKey = key.trim();
  if (wsKey.isEmpty) throw const RunnerConfigInvalid('工作區名稱不可空白');
  if (!await Directory(folder).exists()) {
    throw RunnerConfigInvalid('資料夾「$folder」不存在');
  }

  var name = projectName.trim();
  var path = projectPath.trim();
  if (path.isEmpty) {
    if (!await isGitRepoDir(folder)) {
      throw RunnerConfigInvalid(
          '工作區「$wsKey」至少要有一個專案：「$folder」不是 git repo，請指定專案路徑');
    }
    path = folder;
    if (name.isEmpty) name = _baseName(folder);
  }
  if (name.isEmpty) name = _baseName(path);
  if (!await Directory(path).exists()) {
    throw RunnerConfigInvalid('專案路徑「$path」不存在');
  }
  if (!await isGitRepoDir(path)) {
    throw RunnerConfigInvalid('「$path」不是 git repo（找不到 .git）');
  }

  await _mutate(cfg, (raw) async {
    final all = _workspacesRaw(raw, create: true)!;
    if (all.containsKey(wsKey)) {
      throw RunnerConfigInvalid('工作區「$wsKey」已經存在');
    }
    all[wsKey] = <String, dynamic>{
      'folder': folder,
      'projects': <String, dynamic>{
        name: RunnerProject(path: path).toJson(),
      },
      'default_project': name,
    };
  });
}

/// 移除一個工作區。整塊拿掉——裡面的專案設定跟著走。
Future<void> removeRunnerWorkspace(
  RunnerConfigFile cfg, {
  required String key,
}) async {
  await _mutate(cfg, (raw) async {
    final all = _workspacesRaw(raw, create: false);
    if (all == null || !all.containsKey(key)) {
      throw RunnerConfigInvalid('工作區「$key」不存在');
    }
    all.remove(key);
  });
}

/// 在工作區裡新增一個專案（git repo）。
Future<void> addRunnerProject(
  RunnerConfigFile cfg, {
  required String workspaceKey,
  required String name,
  required String path,
  List<String> allowedBranches = const [],
  List<String> pushBranches = const [],
}) async {
  final projectName = name.trim();
  final projectPath = path.trim();
  if (projectName.isEmpty) throw const RunnerConfigInvalid('專案名稱不可空白');
  if (!await Directory(projectPath).exists()) {
    throw RunnerConfigInvalid('專案路徑「$projectPath」不存在');
  }
  if (!await isGitRepoDir(projectPath)) {
    throw RunnerConfigInvalid('「$projectPath」不是 git repo（找不到 .git）');
  }

  await _mutate(cfg, (raw) async {
    final ws = _workspaceRaw(raw, workspaceKey);
    final projects = _projectsRaw(ws, create: true)!;
    if (projects.containsKey(projectName)) {
      throw RunnerConfigInvalid(
          '工作區「$workspaceKey」裡已經有專案「$projectName」');
    }
    projects[projectName] = RunnerProject(
      path: projectPath,
      allowedBranches: allowedBranches,
      pushBranches: pushBranches,
    ).toJson();
  });
}

/// 從工作區移除一個專案。
///
/// 最後一個專案不給移除：移掉之後這份設定執行器讀不起來，而錯誤會在下一次
/// `reload` 才出現，那時已經看不出是這一步做的。
Future<void> removeRunnerProject(
  RunnerConfigFile cfg, {
  required String workspaceKey,
  required String name,
}) async {
  await _mutate(cfg, (raw) async {
    final ws = _workspaceRaw(raw, workspaceKey);
    final projects = _projectsRaw(ws, create: false);
    if (projects == null || !projects.containsKey(name)) {
      throw RunnerConfigInvalid('工作區「$workspaceKey」裡沒有專案「$name」');
    }
    if (projects.length <= 1) {
      throw RunnerConfigInvalid('工作區「$workspaceKey」至少要留一個專案');
    }
    projects.remove(name);
    // 預設專案指到被移掉的那個就清掉，留著會讓執行器載入失敗
    for (final k in const ['default_project', 'default_repo']) {
      if (ws[k]?.toString() == name) ws.remove(k);
    }
  });
}

// ── 內部：原地改檔 ────────────────────────────────────────────────

/// 讀 → 改 → 原子寫回。
///
/// 存檔前再讀一次 mtime：對不上就丟 [RunnerConfigConflict]，由呼叫端提示重新
/// 整理。沒有鎖，靜默覆寫會把別人（或使用者自己手改）的那一版吃掉。
///
/// 寫法是**先寫暫存檔再 rename**：中途斷電時留下的是完整的舊檔，不是一份被
/// 截斷的設定——執行器讀不到設定是起不來的等級。
Future<void> _mutate(
  RunnerConfigFile cfg,
  Future<void> Function(Map<String, dynamic> raw) change,
) async {
  final file = File(cfg.path);
  final now = await file.lastModified();
  if (now != cfg.modified) throw const RunnerConfigConflict();

  final json = jsonDecode(await file.readAsString());
  if (json is! Map) throw const RunnerConfigConflict();
  final raw = json.cast<String, dynamic>();

  await change(raw);

  const encoder = JsonEncoder.withIndent('  ');
  final tmp = File('${cfg.path}.tmp');
  await tmp.writeAsString('${encoder.convert(raw)}\n');
  await tmp.rename(cfg.path);
}

/// 頂層工作區容器。檔案裡原本用哪個鍵就用哪個（新鍵優先），都沒有才建新鍵。
Map<String, dynamic>? _workspacesRaw(Map<String, dynamic> raw,
    {required bool create}) {
  for (final key in const ['workspaces', 'projects']) {
    final v = raw[key];
    if (v is Map) {
      final map = v.cast<String, dynamic>();
      raw[key] = map;
      return map;
    }
  }
  if (!create) return null;
  final map = <String, dynamic>{};
  raw['workspaces'] = map;
  return map;
}

Map<String, dynamic> _workspaceRaw(Map<String, dynamic> raw, String key) {
  final all = _workspacesRaw(raw, create: false);
  final ws = all?[key];
  if (ws is! Map) throw RunnerConfigInvalid('工作區「$key」不存在');
  final map = ws.cast<String, dynamic>();
  all![key] = map;
  return map;
}

/// 工作區內的專案容器。同上：原本是 `repos` 就繼續寫 `repos`。
Map<String, dynamic>? _projectsRaw(Map<String, dynamic> ws,
    {required bool create}) {
  for (final key in const ['projects', 'repos']) {
    final v = ws[key];
    if (v is Map) {
      final map = v.cast<String, dynamic>();
      ws[key] = map;
      return map;
    }
  }
  if (!create) return null;
  final map = <String, dynamic>{};
  ws['projects'] = map;
  return map;
}

void _put(Map<String, dynamic> target, String key, Object? value) {
  if (value == null) {
    target.remove(key);
  } else {
    target[key] = value;
  }
}

String _baseName(String path) {
  final parts = path
      .replaceAll('\\', '/')
      .split('/')
      .where((p) => p.isNotEmpty)
      .toList();
  return parts.isEmpty ? '' : parts.last;
}

/// `claude_bin`：字串或陣列都認，**字串不切**——與執行器 `config._as_argv`
/// 同一條規則（Windows 路徑的反斜線會被當成跳脫字元吃掉）。沒設就是 `claude`。
List<String> _argvList(Object? value) {
  if (value is List) {
    final argv = value.map((e) => e.toString()).toList();
    return argv.isEmpty ? const ['claude'] : argv;
  }
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? const ['claude'] : [text];
}

List<String> _stringList(Object? value) {
  if (value is! List) return const [];
  return value.map((e) => e.toString()).toList();
}

int _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double _double(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0;
}
