import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/build_info.dart';
import 'host_kit_providers.dart';
import 'mcp_kit_providers.dart';
import 'runner_kit_providers.dart';

/// 從 GitHub Release 下載並安裝三種 kit。
///
/// ## 這一層做的事很窄
///
/// 下載、解壓、找到 python、**呼叫那一包自己的 `install.py`**、把它印出來的
/// 結果讀回來。venv 建立、`.env` 產生、排程工作註冊一律留在 `install.py`
/// 裡——**不做第二套安裝器**。兩份安裝邏輯會在某次改動後分岔，而分岔的
/// 那一刻沒有任何地方報錯。
///
/// ## 版本錨在 App 自己身上
///
/// 查的是 `releases/tags/v<App 版本>`，不是 latest。理由是「App 與 kit 要
/// 對得起來」：latest 會讓一份三個月前的 App 裝上今天的 kit，而那兩邊的
/// 契約未必還相容。查不到（dev build 沒有對應 Release）就**停用按鈕並說
/// 明白**，不偷偷退到別的版本。
enum KitId { hub, mcp, runner }

extension KitIdInfo on KitId {
  /// Release 上的資產名。
  String get assetName => switch (this) {
        KitId.hub => 'chatroom-hub-kit.zip',
        KitId.mcp => 'chatroom-mcp-kit.zip',
        KitId.runner => 'chatroom-runner-kit.zip',
      };

  /// 解壓到 `%LOCALAPPDATA%/UEP/Chatroom/<這個>/`。
  String get dirName => switch (this) {
        KitId.hub => 'hub-kit',
        KitId.mcp => 'mcp-kit',
        KitId.runner => 'runner-kit',
      };
}

/// GitHub 上的來源。公開 repo，所以不帶任何憑證——**也不可以帶**：
/// App 手上那個 token 是 Hub 的，送到 GitHub 等於把它交給一個無關的服務。
const String kKitReleaseRepo = 'Unforgettableeternalproject/Chatroom';

String kitReleaseApiUrl(String version) =>
    'https://api.github.com/repos/$kKitReleaseRepo/releases/tags/v$version';

/// 一份 Release。
@immutable
class KitRelease {
  const KitRelease({required this.tag, required this.assets});

  /// `v1.2.3`。
  final String tag;

  /// 資產名 → 下載網址。
  final Map<String, String> assets;

  /// 去掉開頭 `v` 的版本號。
  String get version => tag.startsWith('v') ? tag.substring(1) : tag;

  String? assetFor(KitId kit) => assets[kit.assetName];

  /// GitHub 的 JSON → 這個。認不得就回 `null`（不編一個空的出來）。
  static KitRelease? fromJson(Object? json) {
    if (json is! Map) return null;
    final tag = (json['tag_name'] as String?) ?? '';
    if (tag.isEmpty) return null;
    final assets = <String, String>{};
    final raw = json['assets'];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final name = (item['name'] as String?) ?? '';
        final url = (item['browser_download_url'] as String?) ?? '';
        if (name.isEmpty || url.isEmpty) continue;
        assets[name] = url;
      }
    }
    return KitRelease(tag: tag, assets: assets);
  }
}

/// HTTP 取用。測試換成 fake——**不打真網路**。
abstract class KitHttpClient {
  /// 回傳 `(狀態碼, 解析後的 JSON)`。
  Future<(int, Object?)> getJson(String url);

  /// 下載到本機檔案。`onProgress` 的 total 可能是 -1（伺服器沒給長度）。
  Future<void> download(
    String url,
    String savePath, {
    void Function(int received, int total)? onProgress,
  });
}

class DioKitHttpClient implements KitHttpClient {
  DioKitHttpClient([Dio? dio]) : _dio = dio ?? Dio();

  /// 🔴 **另開一個 Dio。** App 那顆帶著 Hub 的 baseUrl 與 Authorization
  /// header，拿它去打 GitHub 等於把 Hub 的 token 送給 GitHub。
  final Dio _dio;

  @override
  Future<(int, Object?)> getJson(String url) async {
    final res = await _dio.get<Object?>(
      url,
      options: Options(
        responseType: ResponseType.json,
        headers: const {'Accept': 'application/vnd.github+json'},
        // 404 是正常答案（這一版沒發 Release），不是例外
        validateStatus: (code) => code != null && code < 500,
      ),
    );
    return (res.statusCode ?? 0, res.data);
  }

  @override
  Future<void> download(
    String url,
    String savePath, {
    void Function(int received, int total)? onProgress,
  }) =>
      _dio.download(url, savePath, onReceiveProgress: onProgress);
}

/// 子進程。測試換成 fake。
abstract class KitProcessRunner {
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  });
}

class SystemKitProcessRunner implements KitProcessRunner {
  const SystemKitProcessRunner();

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) =>
      Process.run(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        runInShell: true,
        // ⚠️ encoding 一定要設：不設的話 Windows 上拿回來的是被系統碼頁
        // 解讀過的位元組，安裝器講的每一句中文都變成亂碼——而它的輸出
        // 正是「到底成功了沒」的唯一來源。
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
}

/// 找到的 Python 3.12。
@immutable
class PythonExe {
  const PythonExe({required this.executable, this.prefixArgs = const []});

  final String executable;

  /// `py -3.12` 這種要帶的前置參數。
  final List<String> prefixArgs;

  List<String> argsFor(List<String> rest) => [...prefixArgs, ...rest];

  @override
  String toString() => [executable, ...prefixArgs].join(' ');
}

/// 安裝走到哪一步。
enum KitInstallPhase { idle, checking, downloading, extracting, installing, done, failed }

/// 安裝失敗的原因分類——UI 要據此決定顯示什麼（例如缺 Python 要給下載連結）。
enum KitInstallFailure {
  /// Release 裡沒有這包的資產。
  assetMissing,

  /// 這台機器沒有 Python 3.12。
  pythonMissing,
  download,
  extract,

  /// 安裝器跑了但沒有回報成功（含「沒印 RESULT」）。
  installer,
}

@immutable
class KitInstallError implements Exception {
  const KitInstallError(this.reason, [this.detail = '']);

  final KitInstallFailure reason;
  final String detail;

  @override
  String toString() => detail.isEmpty ? '$reason' : detail;
}

/// 安裝器印回來的那一行。
///
/// 共用欄位 `ok`／`kit`／`registry`／`kit_root`／`version`／`commit`／
/// `installed_at`，失敗時 `ok=false` 帶 `error`（exit code 1，stderr 有原因）。
/// 每一包還有自己的欄位，留在 [raw] 裡——**這一層不替它們取名**，那會讓
/// 每加一個欄位就要改這裡。
@immutable
class KitInstallResult {
  const KitInstallResult({
    required this.ok,
    this.error = '',
    this.version = '',
    this.commit = '',
    this.kitRoot = '',
    this.raw = const {},
  });

  final bool ok;
  final String error;

  /// 裝上去的那一包的版本（登錄檔裡叫 `kit_version`；RESULT 裡是 `version`）。
  final String version;
  final String commit;
  final String kitRoot;
  final Map<String, dynamic> raw;

  /// runner-kit：設定檔原本就在，安裝器**沒有覆寫**它。
  /// 這件事要講出來——不講的話，人會以為剛才填的 Hub 位址生效了。
  bool get configKept => raw['config_written'] == false;
}

/// 從安裝器的 stdout 裡撈 `RESULT {json}` 那一行。
///
/// 🔴 **撈不到要當成失敗**，不可以回一個「成功但沒有細節」的結果
/// （與 `parseScriptResult` 同一個態度）：安裝器在 Windows 主控台可能吐出
/// 編碼壞掉的字、或在 stderr 留下 traceback，那時 stdout 不是我們要的東西
/// ——把它當成功的話，使用者會看到綠色的「安裝完成」，磁碟上什麼都沒有。
///
/// 取**最後**一行 `RESULT`：安裝器的進度輸出裡若混進別的 RESULT 字樣，
/// 契約講的是「最後印一行」。
KitInstallResult? parseInstallResult(String stdout) {
  Map<String, dynamic>? found;
  for (final line in const LineSplitter().convert(stdout)) {
    final text = line.trim();
    if (!text.startsWith('RESULT ')) continue;
    try {
      final decoded = jsonDecode(text.substring('RESULT '.length).trim());
      if (decoded is Map) found = decoded.cast<String, dynamic>();
    } on FormatException {
      // 壞掉的那一行當作沒有——前面若有好的就用前面那份
      continue;
    }
  }
  if (found == null) return null;
  return KitInstallResult(
    ok: found['ok'] == true,
    error: '${found['error'] ?? ''}',
    version: '${found['version'] ?? ''}',
    commit: '${found['commit'] ?? ''}',
    kitRoot: '${found['kit_root'] ?? ''}',
    raw: found,
  );
}

/// kit 解壓後的固定位置。
String kitInstallRoot([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  final sep = Platform.pathSeparator;
  final local = env['LOCALAPPDATA'] ?? '';
  if (local.isNotEmpty) return [local, 'UEP', 'Chatroom'].join(sep);
  final home = env['USERPROFILE'] ?? env['HOME'] ?? '';
  if (home.isEmpty) return '';
  return [home, '.chatroom', 'kits'].join(sep);
}

/// 下載、解壓、呼叫 `install.py`。
class KitInstaller {
  KitInstaller({
    required this.http,
    required this.processRunner,
    required this.installRoot,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final KitHttpClient http;
  final KitProcessRunner processRunner;

  /// 三包解壓的父目錄。
  final String installRoot;

  final DateTime Function() _clock;

  static final _sep = Platform.pathSeparator;

  /// 查這一版的 Release。**404 回 `null`**——那是「這份 App 沒有對應的
  /// Release」，不是錯誤，也不退到 latest。
  Future<KitRelease?> fetchRelease(String version) async {
    final (status, body) = await http.getJson(kitReleaseApiUrl(version));
    if (status != 200) return null;
    return KitRelease.fromJson(body);
  }

  /// 找 Python 3.12。找不到回 `null`——**不代裝**。
  Future<PythonExe?> findPython() async {
    for (final candidate in const [
      PythonExe(executable: 'py', prefixArgs: ['-3.12']),
      PythonExe(executable: 'python3.12'),
      PythonExe(executable: 'python'),
    ]) {
      try {
        final r = await processRunner
            .run(candidate.executable, candidate.argsFor(['--version']));
        if (r.exitCode != 0) continue;
        final text = '${r.stdout}${r.stderr}';
        // `py -3.12` 挑的一定是 3.12，但 `python` 可能是任何一版——
        // 版號對不上就往下一個找，不假裝它可以用
        if (RegExp(r'Python\s+3\.12\.').hasMatch(text)) return candidate;
      } on Object {
        continue;
      }
    }
    return null;
  }

  /// 走完一次安裝。
  ///
  /// `extraArgs` 是那一包自己的參數（Hub 位址、token…），由呼叫端決定；
  /// 這裡只負責把 `--yes` 擺在最前面。
  Future<KitInstallResult> install(
    KitId kit, {
    required KitRelease release,
    List<String> extraArgs = const [],
    void Function(KitInstallPhase phase, double progress)? onProgress,
  }) async {
    final url = release.assetFor(kit);
    if (url == null || url.isEmpty) {
      throw KitInstallError(KitInstallFailure.assetMissing, kit.assetName);
    }

    onProgress?.call(KitInstallPhase.checking, 0);
    final python = await findPython();
    if (python == null) {
      throw const KitInstallError(KitInstallFailure.pythonMissing);
    }

    final downloads = Directory('$installRoot$_sep.downloads');
    final zipPath = '${downloads.path}$_sep${kit.assetName}';
    try {
      await downloads.create(recursive: true);
      onProgress?.call(KitInstallPhase.downloading, 0);
      try {
        await http.download(url, zipPath, onProgress: (received, total) {
          onProgress?.call(
            KitInstallPhase.downloading,
            total > 0 ? received / total : 0,
          );
        });
      } on Object catch (e) {
        throw KitInstallError(KitInstallFailure.download, '$e');
      }

      onProgress?.call(KitInstallPhase.extracting, 0);
      final target = await _extract(kit, zipPath);

      onProgress?.call(KitInstallPhase.installing, 0);
      final script = await _findInstallScript(target);
      if (script == null) {
        throw KitInstallError(
            KitInstallFailure.installer, '$target$_sep' 'install.py');
      }
      final ProcessResult run;
      try {
        run = await processRunner.run(
          python.executable,
          python.argsFor([script.path, '--yes', ...extraArgs]),
          workingDirectory: script.parent.path,
        );
      } on Object catch (e) {
        throw KitInstallError(KitInstallFailure.installer, '$e');
      }
      final result = parseInstallResult('${run.stdout}');
      if (result == null) {
        final err = '${run.stderr}'.trim();
        throw KitInstallError(
          KitInstallFailure.installer,
          err.isNotEmpty ? err : '${run.stdout}'.trim(),
        );
      }
      if (!result.ok) {
        throw KitInstallError(KitInstallFailure.installer, result.error);
      }
      onProgress?.call(KitInstallPhase.done, 1);
      return result;
    } finally {
      // 🔴 清理放 finally：中途炸掉時那個半份 zip 仍然要走。
      try {
        final f = File(zipPath);
        if (await f.exists()) await f.delete();
      } on Object {
        // 刪不掉不影響安裝結果，不要讓它蓋掉真正的錯誤
      }
    }
  }

  /// 解壓到 `<installRoot>/<kit>-kit/`；已存在的先備份成 `.bak-<時間>`。
  ///
  /// 用 PowerShell 的 `Expand-Archive` 而不是拉一個解壓套件進來：這條路
  /// 本來就只在 Windows 上走得通（排程工作、`py` 啟動器都是），而少一個
  /// 依賴就少一次 Windows build 出事的機會。
  Future<String> _extract(KitId kit, String zipPath) async {
    final target = Directory('$installRoot$_sep${kit.dirName}');
    try {
      if (await target.exists()) {
        final stamp = _stamp(_clock());
        await target.rename('${target.path}.bak-$stamp');
      }
      await target.create(recursive: true);
      final r = await processRunner.run('powershell', [
        '-NoProfile',
        '-Command',
        'Expand-Archive -LiteralPath "$zipPath" '
            '-DestinationPath "${target.path}" -Force',
      ]);
      if (r.exitCode != 0) {
        throw KitInstallError(
            KitInstallFailure.extract, '${r.stderr}'.trim());
      }
    } on KitInstallError {
      rethrow;
    } on Object catch (e) {
      throw KitInstallError(KitInstallFailure.extract, '$e');
    }
    return target.path;
  }

  /// `install.py` 在解壓出來的哪裡。
  ///
  /// 三包的 `build.py` 都用 `f.relative_to(DIST)` 寫 zip，所以裡面帶一層
  /// `chatroom-*-kit/`；但別假設它永遠如此——根目錄也找一次。
  Future<File?> _findInstallScript(String target) async {
    final direct = File('$target$_sep' 'install.py');
    if (await direct.exists()) return direct;
    try {
      await for (final entry in Directory(target).list()) {
        if (entry is! Directory) continue;
        final nested = File('${entry.path}$_sep' 'install.py');
        if (await nested.exists()) return nested;
      }
    } on Object {
      return null;
    }
    return null;
  }

  static String _stamp(DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${at.year}${two(at.month)}${two(at.day)}'
        '-${two(at.hour)}${two(at.minute)}${two(at.second)}';
  }
}

/// 這台機器裝不裝得了 kit。
///
/// 整條安裝路徑（`py` 啟動器、`Expand-Archive`、排程工作）都是 Windows 的
/// 東西——在手機上畫一顆按不動的「安裝」，比沒有那顆按鈕更糟。
///
/// 做成 provider 而不是直接讀 `Platform`：測試要能兩邊都測，而
/// `Platform.isWindows` 在測試裡是跑測試那台機器的事實，不是被測的條件。
final kitInstallSupportedProvider = Provider<bool>((ref) => Platform.isWindows);

final kitHttpClientProvider =
    Provider<KitHttpClient>((ref) => DioKitHttpClient());

final kitProcessRunnerProvider =
    Provider<KitProcessRunner>((ref) => const SystemKitProcessRunner());

final kitInstallerProvider = Provider<KitInstaller>((ref) => KitInstaller(
      http: ref.watch(kitHttpClientProvider),
      processRunner: ref.watch(kitProcessRunnerProvider),
      installRoot: kitInstallRoot(),
    ));

/// 這份 App 對應的 Release。
///
/// `null` ＝**這一版沒有對應的 Release**（dev build，或那一版根本沒發）。
/// 那時安裝按鈕停用並說明白，不退到 latest：latest 會讓一份舊 App 裝上
/// 今天的 kit，而兩邊的契約未必還相容。
final kitReleaseProvider = FutureProvider<KitRelease?>((ref) async {
  try {
    return await ref
        .watch(kitInstallerProvider)
        .fetchRelease(BuildInfo.current.version);
  } on Object {
    // 連不到 GitHub 與「沒有這一版」在畫面上是同一件事：按鈕按不得。
    return null;
  }
});

/// 這台機器上找不找得到 Python 3.12。
final kitPythonProvider = FutureProvider<PythonExe?>(
    (ref) => ref.watch(kitInstallerProvider).findPython());

/// python.org 的下載頁——**App 不代裝直譯器**。
const String kPythonDownloadUrl = 'https://www.python.org/downloads/';

/// 執行器手上還有沒有 run。
///
/// 讀的是執行器自己落地的 `state.json`（`loop.py:_persist_active` 在 spawn
/// 與結束的當下就寫）。**讀不到回 `false`**：這一格的用途是「擋住更新」，
/// 而把「不知道」擋成「忙碌中」會讓一台早就空著的機器永遠更新不了。
/// 真的忙的話，覆蓋檔案的後果由 `install.py` 與執行器自己承擔——那與人手
/// 跑安裝器是同一個處境。
final runnerBusyProvider = FutureProvider<bool>((ref) async {
  final cfg = await ref.watch(runnerConfigProvider.future);
  if (cfg == null) return false;
  final file = runnerStateFileFor(cfg);
  if (file == null) return false;
  try {
    if (!await file.exists()) return false;
    final json = jsonDecode(await file.readAsString());
    if (json is! Map) return false;
    final ids = json['active_run_ids'];
    return ids is List && ids.isNotEmpty;
  } on Object {
    return false;
  }
});

/// 一包 kit 現在的安裝狀態。
@immutable
class KitInstallState {
  const KitInstallState({
    this.phase = KitInstallPhase.idle,
    this.progress = 0,
    this.failure,
    this.detail = '',
    this.result,
  });

  final KitInstallPhase phase;

  /// 下載進度 0..1；其餘階段沒有意義。
  final double progress;

  final KitInstallFailure? failure;
  final String detail;
  final KitInstallResult? result;

  bool get busy =>
      phase == KitInstallPhase.checking ||
      phase == KitInstallPhase.downloading ||
      phase == KitInstallPhase.extracting ||
      phase == KitInstallPhase.installing;
}

/// 三包各自一格。
///
/// 分格存是因為三包可以各裝各的，而「這一顆按鈕現在能不能按」只看自己
/// 那一格——合起來看的話，裝 MCP 的時候 Hub 的按鈕也會變成「安裝中」。
class KitInstalls extends Notifier<Map<KitId, KitInstallState>> {
  @override
  Map<KitId, KitInstallState> build() => const {};

  KitInstallState of(KitId kit) => state[kit] ?? const KitInstallState();

  void _set(KitId kit, KitInstallState value) =>
      state = {...state, kit: value};

  /// 跑一次安裝／更新。成功後 invalidate 對應的 kit provider，分頁跟著更新。
  Future<void> install(
    KitId kit, {
    required KitRelease release,
    List<String> extraArgs = const [],
  }) async {
    if (of(kit).busy) return;
    _set(kit, const KitInstallState(phase: KitInstallPhase.checking));
    try {
      final result = await ref.read(kitInstallerProvider).install(
            kit,
            release: release,
            extraArgs: extraArgs,
            onProgress: (phase, progress) =>
                _set(kit, KitInstallState(phase: phase, progress: progress)),
          );
      _set(
        kit,
        KitInstallState(
            phase: KitInstallPhase.done, progress: 1, result: result),
      );
      _refresh(kit);
    } on KitInstallError catch (e) {
      _set(
        kit,
        KitInstallState(
          phase: KitInstallPhase.failed,
          failure: e.reason,
          detail: e.detail,
        ),
      );
    } on Object catch (e) {
      _set(
        kit,
        KitInstallState(
          phase: KitInstallPhase.failed,
          failure: KitInstallFailure.installer,
          detail: '$e',
        ),
      );
    }
  }

  void _refresh(KitId kit) {
    switch (kit) {
      case KitId.hub:
        ref.invalidate(hostKitProvider);
        ref.invalidate(hostEnvProvider);
      case KitId.mcp:
        ref.invalidate(mcpKitProvider);
        ref.invalidate(mcpEnvProvider);
        ref.invalidate(mcpBridgeVersionProvider);
      case KitId.runner:
        ref.invalidate(runnerKitProvider);
        ref.invalidate(runnerConfigProvider);
        ref.invalidate(runnerVersionProvider);
    }
  }
}

final kitInstallsProvider =
    NotifierProvider<KitInstalls, Map<KitId, KitInstallState>>(
        KitInstalls.new);
