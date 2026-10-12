import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/build_info.dart';
import '../core/window/window_tray.dart';
import 'kit_installer.dart';

/// App 自己的檢查更新與自我更新（Windows 桌面）。
///
/// 與 kit 安裝分開：kit 錨在「App 這一版」的 Release，這裡問的是 latest。
/// 共用的只有不帶 token 的 HTTP 取用與子進程介面。
///
/// 流程：查 latest → 下載 zip 到 `.downloads\app-update\<tag>\` → 驗大小與
/// SHA-256 → 解壓到 `staged\` → 交給獨立的 PowerShell 腳本，等 App 結束後
/// 替換安裝目錄並重新啟動。**App 自己不碰安裝目錄**：執行中的 exe 與 dll
/// 換不掉。

/// Release 上 App 資產的檔名：`chatroom-app-<tag>-windows-x64.zip`。
const String kAppAssetPrefix = 'chatroom-app-';
const String kAppAssetSuffix = '-windows-x64.zip';

/// zip 根目錄一定要有的兩個檔案；缺任何一個都不算一份完整的 App。
const String kAppExeName = 'Chatroom.exe';
const List<String> kAppSoPath = ['data', 'app.so'];

const String kAppLatestReleaseUrl =
    'https://api.github.com/repos/$kKitReleaseRepo/releases/latest';

/// 可比較的版本：`v1.2.5-hotfix2` → (1, 2, 5, 2)。
@immutable
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, [this.hotfix = 0]);

  final int major;
  final int minor;
  final int patch;

  /// 沒有 `-hotfix<n>` 後綴就是 0。
  final int hotfix;

  static final _pattern =
      RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:-hotfix(\d+))?$');

  /// `v1.2.5`／`1.2.5`／`v1.2.5-hotfix2`。認不得回 `null`。
  static AppVersion? tryParse(String text) {
    final m = _pattern.firstMatch(text.trim());
    if (m == null) return null;
    return AppVersion(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      m.group(4) == null ? 0 : int.parse(m.group(4)!),
    );
  }

  /// 這份 App 的版本：版號來自 [BuildInfo.version]，熱修序號另外帶。
  static AppVersion? ofBuild(BuildInfo info) {
    final base = tryParse(info.version);
    if (base == null) return null;
    return AppVersion(base.major, base.minor, base.patch, info.hotfix);
  }

  @override
  int compareTo(AppVersion other) {
    for (final (a, b) in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
      (hotfix, other.hotfix),
    ]) {
      if (a != b) return a.compareTo(b);
    }
    return 0;
  }

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, hotfix);

  @override
  String toString() =>
      'v$major.$minor.$patch${hotfix > 0 ? '-hotfix$hotfix' : ''}';
}

/// [compareAppVersions] 的結果：`latest` 相對於 `current`。
enum AppVersionOrder { newer, same, older }

/// `latest` 比 `current` 新、相同還是舊。任一邊認不得回 `null`——
/// 呼叫端要當成「查不到」，不是「相同」。
AppVersionOrder? compareAppVersions(String latest, String current) {
  final a = AppVersion.tryParse(latest);
  final b = AppVersion.tryParse(current);
  if (a == null || b == null) return null;
  return _order(a, b);
}

AppVersionOrder _order(AppVersion latest, AppVersion current) {
  final c = latest.compareTo(current);
  if (c > 0) return AppVersionOrder.newer;
  return c == 0 ? AppVersionOrder.same : AppVersionOrder.older;
}

/// latest Release 裡的 App 資產。
@immutable
class AppRelease {
  const AppRelease({
    required this.tag,
    required this.assetName,
    required this.downloadUrl,
    this.htmlUrl = '',
    this.size,
    this.sha256,
  });

  /// `v1.2.6` 或 `v1.2.6-hotfix1`。
  final String tag;
  final String htmlUrl;
  final String assetName;
  final String downloadUrl;

  /// 資產的位元組數。GitHub 沒給就是 `null`（不比對）。
  final int? size;

  /// 小寫 hex。GitHub 沒給 `digest`、或不是 sha256 就是 `null`（不比對）。
  final String? sha256;

  /// GitHub 的 JSON → 這個。沒有 tag 或沒有對應的 App 資產就回 `null`。
  static AppRelease? fromJson(Object? json) {
    if (json is! Map) return null;
    final tag = json['tag_name'];
    if (tag is! String || tag.isEmpty) return null;
    final raw = json['assets'];
    if (raw is! List) return null;
    for (final item in raw) {
      if (item is! Map) continue;
      final name = item['name'];
      final url = item['browser_download_url'];
      if (name is! String || url is! String || url.isEmpty) continue;
      if (!_isAppAsset(name)) continue;
      final size = item['size'];
      return AppRelease(
        tag: tag,
        htmlUrl: json['html_url'] is String ? json['html_url'] as String : '',
        assetName: name,
        downloadUrl: url,
        size: size is int && size > 0 ? size : null,
        sha256: _sha256Of(item['digest']),
      );
    }
    return null;
  }

  /// 資產名會拿去組本機路徑、也會進 PowerShell 的指令字串：只認英數與
  /// `.`、`_`、`-`，其餘（路徑分隔、引號、`$`、空白…）一律不認。
  static bool _isAppAsset(String name) =>
      name.startsWith(kAppAssetPrefix) &&
      name.endsWith(kAppAssetSuffix) &&
      RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name);

  static String? _sha256Of(Object? digest) {
    if (digest is! String) return null;
    const prefix = 'sha256:';
    if (!digest.toLowerCase().startsWith(prefix)) return null;
    final hex = digest.substring(prefix.length).trim().toLowerCase();
    return RegExp(r'^[0-9a-f]{64}$').hasMatch(hex) ? hex : null;
  }
}

/// 更新失敗的原因分類，UI 據此挑一句話。
enum AppUpdateFailure {
  /// 安裝目錄寫不進去。
  notWritable,
  download,
  sizeMismatch,
  digestMismatch,
  extract,

  /// 解出來的東西缺 `Chatroom.exe` 或 `data\app.so`。
  incomplete,

  /// 更新腳本起不來。
  launch,
}

@immutable
class AppUpdateError implements Exception {
  const AppUpdateError(this.reason, [this.detail = '']);

  final AppUpdateFailure reason;
  final String detail;

  @override
  String toString() => detail.isEmpty ? '$reason' : detail;
}

/// 下載並驗證完、等著被套用的一份更新。
@immutable
class AppUpdatePackage {
  const AppUpdatePackage({
    required this.tag,
    required this.dir,
    required this.stagedDir,
    required this.backupDir,
    required this.scriptPath,
  });

  final String tag;

  /// `app-update\<tag>\`：腳本、log、staged、backup 都在這底下。
  final String dir;
  final String stagedDir;
  final String backupDir;
  final String scriptPath;
}

/// 查 latest、下載、驗證、解壓。**不碰安裝目錄**（只做一次寫入探針）。
class AppUpdater {
  AppUpdater({
    required this.http,
    required this.processRunner,
    required this.updateRoot,
    required this.installDir,
  });

  final KitHttpClient http;
  final KitProcessRunner processRunner;

  /// `.downloads` 的父目錄（正式環境是 [kitInstallRoot]）。
  final String updateRoot;

  /// App 現在裝在哪。
  final String installDir;

  static final _sep = Platform.pathSeparator;

  String get _updatesDir => [updateRoot, '.downloads', 'app-update'].join(_sep);

  /// 查 latest Release。查不到（非 200、認不得、沒有 App 資產）回 `null`；
  /// 連不上會丟例外，呼叫端一樣當成查不到。
  Future<AppRelease?> fetchLatest() async {
    final (status, body) = await http.getJson(kAppLatestReleaseUrl);
    if (status != 200) return null;
    return AppRelease.fromJson(body);
  }

  /// 下載、驗證、解壓，並把更新腳本寫好。失敗丟 [AppUpdateError]，
  /// 並把這次下載的東西清掉。
  Future<AppUpdatePackage> download(
    AppRelease release, {
    void Function(double progress)? onProgress,
  }) async {
    // 先探針：下載完才發現寫不進去的話，白等一輪
    if (await checkKitInstallPath(installDir) != null) {
      throw AppUpdateError(AppUpdateFailure.notWritable, installDir);
    }
    // tag 會拿去組路徑，只收認得的那種形狀
    if (AppVersion.tryParse(release.tag) == null) {
      throw AppUpdateError(AppUpdateFailure.download, release.tag);
    }

    final updates = Directory(_updatesDir);
    final tagDir = Directory('${updates.path}$_sep${release.tag}');
    final zipPath = '${tagDir.path}$_sep${release.assetName}';
    final staged = Directory('${tagDir.path}$_sep' 'staged');
    var ok = false;
    try {
      try {
        // 上一次更新留下的 backup 與 log 在這裡清掉
        if (await updates.exists()) await updates.delete(recursive: true);
        await tagDir.create(recursive: true);
        onProgress?.call(0);
        await http.download(release.downloadUrl, zipPath,
            onProgress: (received, total) {
          final all = total > 0 ? total : (release.size ?? 0);
          onProgress?.call(all > 0 ? (received / all).clamp(0.0, 1.0) : 0);
        });
      } on Object catch (e) {
        throw AppUpdateError(AppUpdateFailure.download, '$e');
      }

      final size = release.size;
      if (size != null) {
        final actual = await File(zipPath).length();
        if (actual != size) {
          throw AppUpdateError(
              AppUpdateFailure.sizeMismatch, '$actual != $size');
        }
      }
      final expected = release.sha256;
      if (expected != null) {
        final actual = await _sha256(zipPath);
        if (actual != expected) {
          throw AppUpdateError(
              AppUpdateFailure.digestMismatch, '$actual != $expected');
        }
      }

      await _extract(zipPath, staged.path);
      final exe = File('${staged.path}$_sep$kAppExeName');
      final so = File([staged.path, ...kAppSoPath].join(_sep));
      if (!await exe.exists() || !await so.exists()) {
        throw const AppUpdateError(AppUpdateFailure.incomplete);
      }

      final script = File('${tagDir.path}$_sep' 'apply-update.ps1');
      try {
        await script.writeAsString(kApplyUpdateScript);
      } on Object catch (e) {
        throw AppUpdateError(AppUpdateFailure.extract, '$e');
      }
      ok = true;
      return AppUpdatePackage(
        tag: release.tag,
        dir: tagDir.path,
        stagedDir: staged.path,
        backupDir: '${tagDir.path}$_sep' 'backup',
        scriptPath: script.path,
      );
    } finally {
      // 清理放 finally：成功時只刪 zip，失敗時整份丟掉
      try {
        if (ok) {
          final zip = File(zipPath);
          if (await zip.exists()) await zip.delete();
        } else if (await tagDir.exists()) {
          await tagDir.delete(recursive: true);
        }
      } on Object {
        // 刪不掉不影響結果，不要讓它蓋掉真正的錯誤
      }
    }
  }

  /// 檔案的 SHA-256（小寫 hex）。算不出來回空字串——那會與期望值不符，
  /// 也就是「驗不了＝不過」。
  ///
  /// 經 PowerShell 算，理由同解壓：這條路只在 Windows 上走，不為它多拉一個
  /// 套件。直接叫 .NET 而不用 `Get-FileHash`——後者是 script module 裡的
  /// 函式，`PSModulePath` 被 PowerShell 7 的父進程帶歪時 5.1 會找不到它
  /// （實測 2026-10-12）。輸出形如 `AB-CD-…`。
  Future<String> _sha256(String path) async {
    try {
      final r = await processRunner.run('powershell', [
        '-NoProfile',
        '-Command',
        '[BitConverter]::ToString([Security.Cryptography.SHA256]::Create()'
            '.ComputeHash([IO.File]::ReadAllBytes("$path")))',
      ]);
      if (r.exitCode != 0) return '';
      return '${r.stdout}'.trim().replaceAll('-', '').toLowerCase();
    } on Object {
      return '';
    }
  }

  Future<void> _extract(String zipPath, String target) async {
    try {
      await Directory(target).create(recursive: true);
      final r = await processRunner.run('powershell', [
        '-NoProfile',
        '-Command',
        'Expand-Archive -LiteralPath "$zipPath" '
            '-DestinationPath "$target" -Force',
      ]);
      if (r.exitCode != 0) {
        throw AppUpdateError(AppUpdateFailure.extract, '${r.stderr}'.trim());
      }
    } on AppUpdateError {
      rethrow;
    } on Object catch (e) {
      throw AppUpdateError(AppUpdateFailure.extract, '$e');
    }
  }
}

/// 起更新腳本的參數（`powershell` 之後的整串）。
List<String> applyUpdateArguments({
  required AppUpdatePackage package,
  required String installDir,
  required String exePath,
  required int waitPid,
}) =>
    [
      '-NoProfile',
      '-NonInteractive',
      '-WindowStyle',
      'Hidden',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      package.scriptPath,
      '-AppDir',
      installDir,
      '-StagedDir',
      package.stagedDir,
      '-BackupDir',
      package.backupDir,
      '-ExePath',
      exePath,
      '-WaitPid',
      '$waitPid',
    ];

/// 把更新腳本起成一支獨立的進程。測試換成 fake。
abstract class AppUpdateLauncher {
  Future<void> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  });
}

/// 經一支短命的 PowerShell 用 `Start-Process` 把腳本起出去：App 結束後它
/// 要繼續活著，而且要有自己的（隱藏的）主控台。
///
/// ⚠️ 不能直接 `Process.start('powershell', …, mode: detached)`：detached
/// 的進程沒有主控台，實測（2026-10-12，Windows PowerShell 5.1）
/// `powershell -File` 在那種狀態下起得來、拿得到 PID，腳本卻一行都不跑，
/// 也沒有任何錯誤。
class DetachedAppUpdateLauncher implements AppUpdateLauncher {
  const DetachedAppUpdateLauncher();

  @override
  Future<void> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    final line = arguments.map(_quoteArgument).join(' ');
    final command = StringBuffer(r"$ErrorActionPreference = 'Stop'; ")
      ..write('Start-Process -FilePath ${_psLiteral(executable)} ')
      ..write('-WindowStyle Hidden -ArgumentList ${_psLiteral(line)}');
    if (workingDirectory != null) {
      command.write(' -WorkingDirectory ${_psLiteral(workingDirectory)}');
    }
    // -EncodedCommand（UTF-16LE 的 base64）：整段指令不必再過一層引號跳脫
    final encoded = base64.encode([
      for (final unit in command.toString().codeUnits) ...[
        unit & 0xff,
        unit >> 8,
      ],
    ]);
    final r = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-EncodedCommand',
      encoded,
    ]);
    if (r.exitCode != 0) {
      throw ProcessException(
          executable, arguments, '${r.stderr}'.trim(), r.exitCode);
    }
  }

  /// PowerShell 的單引號字串。
  static String _psLiteral(String text) => "'${text.replaceAll("'", "''")}'";

  /// Windows 命令列的一個參數（`CommandLineToArgvW` 的規則）：有空白才加
  /// 引號，引號前與結尾的反斜線要加倍。
  static String _quoteArgument(String arg) {
    if (arg.isNotEmpty && !arg.contains(RegExp(r'[\s"]'))) return arg;
    final out = StringBuffer('"');
    var slashes = 0;
    for (final rune in arg.runes) {
      final char = String.fromCharCode(rune);
      if (char == r'\') {
        slashes++;
        continue;
      }
      if (char == '"') {
        out.write(r'\' * (slashes * 2 + 1));
      } else {
        out.write(r'\' * slashes);
      }
      out.write(char);
      slashes = 0;
    }
    out
      ..write(r'\' * (slashes * 2))
      ..write('"');
    return out.toString();
  }
}

/// 替換安裝目錄並重新啟動的腳本。寫到 `app-update\<tag>\apply-update.ps1`。
///
/// 本體保持純 ASCII：Windows PowerShell 5.1 讀沒有 BOM 的檔案時用系統碼頁，
/// 中文會變成亂碼甚至語法錯誤。
///
/// 🔴 **只動這一包帶來的那些頂層項目**（`Chatroom.exe`、`data\`、各 dll…）：
/// 安裝目錄是「exe 所在的資料夾」，那裡可能還放著不相干的檔案（整包解到
/// 下載資料夾的人就是這樣），那些不備份、不刪、不搬。
///
/// 備份用「先複製、再刪原檔」而不是 `Move-Item`：安裝目錄與
/// `%LOCALAPPDATA%` 可能在不同磁碟機（推測 5.1 的 `Move-Item` 搬不動跨
/// 磁碟機的資料夾，未實測）。複製完才刪，也讓備份失敗時安裝目錄原封不動。
///
/// 等不到 App 結束時**不重新啟動**：它還活著，再起一次就是第二個實例。
///
/// 結束碼：0 已替換；2 等不到 App 結束（沒替換）；3 備份失敗（沒替換）；
/// 4 這一包讀不到（沒替換）或替換失敗（已還原）。
const String kApplyUpdateScript = r'''
param(
  [Parameter(Mandatory = $true)][string]$AppDir,
  [Parameter(Mandatory = $true)][string]$StagedDir,
  [Parameter(Mandatory = $true)][string]$BackupDir,
  [Parameter(Mandatory = $true)][string]$ExePath,
  [int]$WaitPid = 0,
  [int]$TimeoutSec = 60,
  [switch]$NoRelaunch
)

$ErrorActionPreference = 'Stop'
$LogPath = Join-Path $PSScriptRoot 'apply-update.log'

function Write-Log([string]$Message) {
  $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  for ($i = 0; $i -lt 10; $i++) {
    try {
      Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
      return
    } catch {
      Start-Sleep -Milliseconds 50
    }
  }
}

function Start-App {
  if ($NoRelaunch) {
    Write-Log 'relaunch skipped (-NoRelaunch)'
    return
  }
  try {
    Start-Process -FilePath $ExePath -WorkingDirectory $AppDir
    Write-Log "relaunched $ExePath"
  } catch {
    Write-Log "relaunch failed: $($_.Exception.Message)"
  }
}

function Test-AppRunning {
  if ($WaitPid -gt 0) {
    if (Get-Process -Id $WaitPid -ErrorAction SilentlyContinue) { return $true }
  }
  $name = [System.IO.Path]::GetFileNameWithoutExtension($ExePath)
  foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
    $path = $null
    try { $path = $p.Path } catch { }
    if ($path -and ($path -eq $ExePath)) { return $true }
  }
  return $false
}

function Clear-AppDir {
  foreach ($name in $Names) {
    $target = Join-Path $AppDir $name
    if (Test-Path -LiteralPath $target) {
      Remove-Item -LiteralPath $target -Recurse -Force
    }
  }
}

function Backup-App {
  foreach ($name in $Names) {
    $source = Join-Path $AppDir $name
    if (Test-Path -LiteralPath $source) {
      Copy-Item -LiteralPath $source -Destination $BackupDir -Recurse -Force
    }
  }
}

function Copy-Tree([string]$From, [string]$To) {
  foreach ($item in @(Get-ChildItem -LiteralPath $From -Force)) {
    Copy-Item -LiteralPath $item.FullName -Destination $To -Recurse -Force
  }
}

function Restore-App {
  Write-Log 'restoring from backup'
  try { Clear-AppDir } catch { Write-Log "cleanup failed: $($_.Exception.Message)" }
  try {
    Copy-Tree $BackupDir $AppDir
    Write-Log 'restored'
  } catch {
    Write-Log "restore failed: $($_.Exception.Message)"
  }
}

Write-Log "start app=$AppDir staged=$StagedDir backup=$BackupDir exe=$ExePath pid=$WaitPid"

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$timedOut = $false
while (Test-AppRunning) {
  if ((Get-Date) -ge $deadline) {
    $timedOut = $true
    break
  }
  Start-Sleep -Milliseconds 300
}
if ($timedOut) {
  # The app is still running: starting it again would open a second instance.
  Write-Log "timeout: app still running after $TimeoutSec s, nothing replaced"
  exit 2
}
Write-Log 'app exited'

# Only the top-level entries shipped in the package are touched. Anything
# else sitting next to the exe is not ours to move or delete.
$Names = @()
try {
  $Names = @(Get-ChildItem -LiteralPath $StagedDir -Force | ForEach-Object { $_.Name })
  if ($Names.Count -eq 0) { throw 'staged dir is empty' }
} catch {
  Write-Log "staged dir unreadable, nothing replaced: $($_.Exception.Message)"
  Start-App
  exit 4
}

try {
  if (Test-Path -LiteralPath $BackupDir) {
    Remove-Item -LiteralPath $BackupDir -Recurse -Force
  }
  New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
  Backup-App
  Write-Log 'backup copied'
} catch {
  Write-Log "backup failed, nothing replaced: $($_.Exception.Message)"
  Start-App
  exit 3
}

try {
  Clear-AppDir
  Write-Log 'app dir cleared'
  Copy-Tree $StagedDir $AppDir
  Write-Log 'staged copied'
} catch {
  Write-Log "replace failed: $($_.Exception.Message)"
  Restore-App
  Start-App
  exit 4
}

Write-Log 'update applied'
Start-App
exit 0
''';

/// 檢查更新走到哪。
enum AppUpdatePhase {
  idle,
  checking,
  upToDate,

  /// 有新版，還沒下載。
  available,

  /// 查不到。**不等於已是最新。**
  checkFailed,
  downloading,

  /// 下載、驗證、解壓都好了，等重新啟動。
  ready,

  /// 腳本已起、App 正要結束。
  applying,
  failed,
}

@immutable
class AppUpdateState {
  const AppUpdateState({
    this.phase = AppUpdatePhase.idle,
    this.tag = '',
    this.progress = 0,
    this.failure,
    this.detail = '',
  });

  final AppUpdatePhase phase;

  /// 新版的 tag；idle／checking／upToDate／checkFailed 時是空字串。
  final String tag;

  /// 下載進度 0..1；其餘階段沒有意義。
  final double progress;

  final AppUpdateFailure? failure;
  final String detail;

  bool get busy =>
      phase == AppUpdatePhase.checking ||
      phase == AppUpdatePhase.downloading ||
      phase == AppUpdatePhase.applying;
}

/// 這個平台走不走得通自我更新。做成 provider 的理由同
/// [kitInstallSupportedProvider]。
final appUpdatePlatformProvider = Provider<bool>((ref) => Platform.isWindows);

/// 這份 App 的版本識別。測試覆寫它來扮演 Release 版。
final appBuildInfoProvider = Provider<BuildInfo>((ref) => BuildInfo.current);

/// 要不要顯示檢查更新。dev build（沒有 commit）與 dirty build 對不回任何
/// 一份 Release，不拿它們去比。
final appUpdateEnabledProvider = Provider<bool>((ref) {
  final info = ref.watch(appBuildInfoProvider);
  return ref.watch(appUpdatePlatformProvider) && info.isKnown && !info.isDirty;
});

/// 執行中的 exe。
final appExePathProvider =
    Provider<String>((ref) => Platform.resolvedExecutable);

/// 安裝目錄＝exe 所在的資料夾。
final appInstallDirProvider = Provider<String>(
    (ref) => File(ref.watch(appExePathProvider)).parent.path);

/// `.downloads` 的父目錄。
final appUpdateRootProvider = Provider<String>((ref) => kitInstallRoot());

/// 腳本要等它結束的那個進程。
final appPidProvider = Provider<int>((ref) => pid);

final appUpdateLauncherProvider = Provider<AppUpdateLauncher>(
    (ref) => const DetachedAppUpdateLauncher());

/// 結束 App。走系統匣「結束」的同一條路——closeToTray 開著時，關閉視窗
/// 只是藏起來。之後的 `exit` 是保險：腳本要等這個進程真的消失才會動手。
final appQuitProvider = Provider<Future<void> Function()>((ref) => () async {
      await WindowTray.instance.quit();
      exit(0);
    });

final appUpdaterProvider = Provider<AppUpdater>((ref) => AppUpdater(
      http: ref.watch(kitHttpClientProvider),
      processRunner: ref.watch(kitProcessRunnerProvider),
      updateRoot: ref.watch(appUpdateRootProvider),
      installDir: ref.watch(appInstallDirProvider),
    ));

/// 檢查更新的狀態。不是 autoDispose：切分頁、離開設定頁都不該丟掉
/// 下載到一半的進度。
///
/// 只在使用者按下時動作——沒有自動檢查，也沒有背景輪詢。
class AppUpdate extends Notifier<AppUpdateState> {
  AppRelease? _release;
  AppUpdatePackage? _package;

  @override
  AppUpdateState build() => const AppUpdateState();

  /// 查一次 latest。
  ///
  /// 🔴 查不到的每一種（非 200、沒網路、認不得、沒有 App 資產、連自己的
  /// 版本都認不得）都是 [AppUpdatePhase.checkFailed]，不是 upToDate。
  Future<void> check() async {
    if (!ref.read(appUpdateEnabledProvider) || state.busy) return;
    state = const AppUpdateState(phase: AppUpdatePhase.checking);
    _release = null;
    _package = null;

    final current = AppVersion.ofBuild(ref.read(appBuildInfoProvider));
    AppRelease? release;
    try {
      release = await ref.read(appUpdaterProvider).fetchLatest();
    } on Object {
      release = null;
    }
    final latest = release == null ? null : AppVersion.tryParse(release.tag);
    if (current == null || release == null || latest == null) {
      state = const AppUpdateState(phase: AppUpdatePhase.checkFailed);
      return;
    }
    switch (_order(latest, current)) {
      case AppVersionOrder.newer:
        _release = release;
        state =
            AppUpdateState(phase: AppUpdatePhase.available, tag: release.tag);
      case AppVersionOrder.same:
      case AppVersionOrder.older:
        state = const AppUpdateState(phase: AppUpdatePhase.upToDate);
    }
  }

  /// 下載並驗證剛才查到的那一版。
  Future<void> download() async {
    final release = _release;
    if (release == null || state.phase != AppUpdatePhase.available) return;
    final tag = release.tag;
    state = AppUpdateState(phase: AppUpdatePhase.downloading, tag: tag);
    try {
      _package = await ref.read(appUpdaterProvider).download(
            release,
            onProgress: (progress) => state = AppUpdateState(
                phase: AppUpdatePhase.downloading,
                tag: tag,
                progress: progress),
          );
      state = AppUpdateState(phase: AppUpdatePhase.ready, tag: tag);
    } on AppUpdateError catch (e) {
      state = AppUpdateState(
        phase: AppUpdatePhase.failed,
        tag: tag,
        failure: e.reason,
        detail: e.detail,
      );
    } on Object catch (e) {
      state = AppUpdateState(
        phase: AppUpdatePhase.failed,
        tag: tag,
        failure: AppUpdateFailure.download,
        detail: '$e',
      );
    }
  }

  /// 起更新腳本，然後結束 App。**腳本起來了才結束**：順序反過來的話，
  /// 起不來時使用者只會看到 App 自己關掉。
  Future<void> restart() async {
    final package = _package;
    if (package == null || state.phase != AppUpdatePhase.ready) return;
    final tag = package.tag;
    state = AppUpdateState(phase: AppUpdatePhase.applying, tag: tag);
    try {
      await ref.read(appUpdateLauncherProvider).start(
            'powershell',
            applyUpdateArguments(
              package: package,
              installDir: ref.read(appInstallDirProvider),
              exePath: ref.read(appExePathProvider),
              waitPid: ref.read(appPidProvider),
            ),
            workingDirectory: package.dir,
          );
    } on Object catch (e) {
      state = AppUpdateState(
        phase: AppUpdatePhase.failed,
        tag: tag,
        failure: AppUpdateFailure.launch,
        detail: '$e',
      );
      return;
    }
    await ref.read(appQuitProvider)();
  }
}

final appUpdateProvider =
    NotifierProvider<AppUpdate, AppUpdateState>(AppUpdate.new);
