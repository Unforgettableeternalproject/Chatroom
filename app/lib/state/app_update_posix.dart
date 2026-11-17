import 'package:flutter/foundation.dart';

import '../core/platform/app_platform.dart';

/// macOS／Linux 的自我更新：資產名、完整性檢查、更新腳本與起腳本的命令。
///
/// Windows 那一套（PowerShell）留在 `app_updater.dart`，一個字都沒動。
/// 這裡的東西都是**純函式與常數**，跑在 Windows 上的測試也能覆蓋。

/// Release 資產名的尾巴。契約：
/// `chatroom-app-<tag>-windows-x64.zip`、`chatroom-app-<tag>-macos-universal.zip`
/// （內含 `Chatroom.app`，以 `ditto -c -k --keepParent` 壓）、
/// `chatroom-app-<tag>-linux-x64.tar.gz`（內含 Flutter bundle 的內容）。
String appAssetSuffixFor(AppPlatform platform) => switch (platform) {
      AppPlatform.windows => '-windows-x64.zip',
      AppPlatform.macos => '-macos-universal.zip',
      AppPlatform.linux => '-linux-x64.tar.gz',
    };

/// macOS 的 bundle 名與裡面的執行檔（`PRODUCT_NAME = Chatroom`）。
const String kMacBundleName = 'Chatroom.app';
const List<String> kMacExePath = [
  kMacBundleName,
  'Contents',
  'MacOS',
  'Chatroom',
];

/// Linux bundle 的執行檔與 AOT 函式庫（release build 才有 `lib/libapp.so`）。
const String kLinuxExeName = 'chatroom';
const List<String> kLinuxSoPath = ['lib', 'libapp.so'];

/// 解壓後一定要有的檔案（相對於 staged 目錄）；缺任何一個都不算完整的 App。
List<List<String>> requiredAppFilesFor(AppPlatform platform) =>
    switch (platform) {
      AppPlatform.windows => const [
          ['Chatroom.exe'],
          ['data', 'app.so'],
        ],
      AppPlatform.macos => const [kMacExePath],
      AppPlatform.linux => const [
          [kLinuxExeName],
          kLinuxSoPath,
        ],
    };

/// `/Applications/Chatroom.app/Contents/MacOS/Chatroom` →
/// `/Applications/Chatroom.app`。路徑裡找不到 `.app` 回 `null`。
///
/// 取**最後一個**以 `.app` 結尾的路徑段：App 若放在
/// `Foo.app/...` 之類的怪位置，要替換的是離執行檔最近的那個 bundle。
String? macBundlePath(String exePath) {
  final parts = exePath.split('/');
  for (var i = parts.length - 1; i > 0; i--) {
    if (parts[i].endsWith('.app')) return parts.sublist(0, i + 1).join('/');
  }
  return null;
}

/// 自我更新做不到的理由；做得到回 `null`。
///
/// 這些是**下載之前**就能知道的事，早講比下載完才失敗好：
///
/// - Linux：以 AppImage 執行時執行檔在唯讀的掛載裡，換不掉自己。
/// - macOS：未簽章的 App 從下載資料夾或磁碟映像直接開，系統會把它搬到
///   `/private/var/folders/.../AppTranslocation/...` 的唯讀隨機路徑跑
///   （Gatekeeper path randomization），那份 bundle 不是使用者放的那份。
/// - macOS：執行檔不在任何 `.app` 裡（`flutter run` 的產物以外幾乎不會發生）。
AppUpdateBlocker? selfUpdateBlocker({
  required AppPlatform platform,
  required String exePath,
  required Map<String, String> environment,
}) {
  switch (platform) {
    case AppPlatform.windows:
      return null;
    case AppPlatform.linux:
      final image = environment['APPIMAGE'] ?? '';
      return image.isEmpty ? null : AppUpdateBlocker.appImage;
    case AppPlatform.macos:
      final bundle = macBundlePath(exePath);
      if (bundle == null) return AppUpdateBlocker.notInBundle;
      if (exePath.contains('/AppTranslocation/')) {
        return AppUpdateBlocker.translocated;
      }
      return null;
  }
}

enum AppUpdateBlocker { appImage, translocated, notInBundle }

/// 要起的命令。
@immutable
class UpdateCommand {
  const UpdateCommand(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}

/// 起 POSIX 更新腳本的命令：`/bin/sh <腳本> <位置參數…>`。
///
/// 路徑全走位置參數、不拼進指令字串：`Application Support` 有空白，
/// 而 shell 的引號規則不是用來信任路徑的。
UpdateCommand posixApplyUpdateCommand({
  required AppPlatform platform,
  required String scriptPath,
  required String stagedDir,
  required String backupDir,
  required String installDir,
  required String exePath,
  required int waitPid,
}) {
  switch (platform) {
    case AppPlatform.macos:
      final bundle = macBundlePath(exePath) ?? exePath;
      return UpdateCommand('/bin/sh', [
        scriptPath,
        bundle,
        '$stagedDir/$kMacBundleName',
        backupDir,
        '$waitPid',
      ]);
    case AppPlatform.linux:
      return UpdateCommand('/bin/sh', [
        scriptPath,
        installDir,
        stagedDir,
        backupDir,
        exePath,
        '$waitPid',
      ]);
    case AppPlatform.windows:
      throw ArgumentError('Windows 不走這條路');
  }
}

/// macOS：整包替換 `Chatroom.app`。
///
/// 純 ASCII、LF 換行。**不做 codesign**：新的 bundle 是 CI 簽好的（目前是
/// ad-hoc，日後換 Developer ID 也一樣只改 CI），這裡只負責換。用 `ditto`
/// 複製是為了保留符號連結（framework 的 `Versions/Current`）與 xattr。
///
/// 結束碼：0 已替換；2 等不到 App 結束（沒替換）；3 備份失敗（沒替換）；
/// 4 新 bundle 不在或替換失敗（已還原）；64 參數不對。
const String kApplyUpdateScriptMac = r'''
#!/bin/sh
# Chatroom self-update (macOS). ASCII only, LF only.
#
# usage: apply-update.sh BUNDLE STAGED_APP BACKUP_DIR WAIT_PID [TIMEOUT_SEC]
#   BUNDLE      the running Chatroom.app (replaced as a whole)
#   STAGED_APP  the new Chatroom.app, already extracted
#   BACKUP_DIR  the old bundle is moved here (kept until the next update)
#   WAIT_PID    pid of the running app; 0 = do not wait
# CHATROOM_UPDATE_NO_RELAUNCH=1 skips the final `open` (tests).
#
# Code signing is NOT done here: the staged bundle was signed by CI.

BUNDLE="$1"
STAGED="$2"
BACKUP="$3"
WAIT_PID="${4:-0}"
TIMEOUT="${5:-60}"
LOG="$(dirname "$0")/apply-update.log"

trap '' HUP

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null
}

relaunch() {
  if [ "$CHATROOM_UPDATE_NO_RELAUNCH" = "1" ]; then
    log 'relaunch skipped (CHATROOM_UPDATE_NO_RELAUNCH)'
    return 0
  fi
  if open "$BUNDLE" >/dev/null 2>&1; then
    log "relaunched $BUNDLE"
  else
    log "relaunch failed: $BUNDLE"
  fi
}

if [ -z "$BUNDLE" ] || [ -z "$STAGED" ] || [ -z "$BACKUP" ]; then
  log 'missing arguments'
  exit 64
fi
case "$BUNDLE" in
  *.app) ;;
  *) log "refusing: bundle path does not end with .app: $BUNDLE"; exit 64 ;;
esac

log "start bundle=$BUNDLE staged=$STAGED backup=$BACKUP pid=$WAIT_PID"

if [ "$WAIT_PID" -gt 0 ] 2>/dev/null; then
  waited=0
  while kill -0 "$WAIT_PID" 2>/dev/null; do
    if [ "$waited" -ge "$TIMEOUT" ]; then
      # The app is still running: opening it again would not start a new
      # instance, and replacing files under it would corrupt the live one.
      log "timeout: app still running after $TIMEOUT s, nothing replaced"
      exit 2
    fi
    sleep 1
    waited=$((waited + 1))
  done
fi
log 'app exited'

if [ ! -d "$STAGED" ]; then
  log "staged app missing, nothing replaced: $STAGED"
  relaunch
  exit 4
fi

OLD="$BACKUP/$(basename "$BUNDLE")"
rm -rf "$BACKUP"
if ! mkdir -p "$BACKUP"; then
  log 'backup dir failed, nothing replaced'
  relaunch
  exit 3
fi
if ! mv "$BUNDLE" "$OLD"; then
  log 'backup (mv) failed, nothing replaced'
  relaunch
  exit 3
fi
log 'old bundle moved to backup'

if ! ditto "$STAGED" "$BUNDLE"; then
  log 'replace failed, restoring'
  rm -rf "$BUNDLE"
  if mv "$OLD" "$BUNDLE"; then
    log 'restored'
  else
    log "restore failed: the old bundle is at $OLD"
  fi
  relaunch
  exit 4
fi

# Nothing downloaded by this app carries the quarantine flag, but clear it
# anyway; failure is not fatal.
xattr -dr com.apple.quarantine "$BUNDLE" 2>/dev/null || log 'xattr failed (ignored)'

log 'update applied'
relaunch
exit 0
''';

/// Linux：替換安裝目錄裡這一包帶來的頂層項目，然後重新啟動。
///
/// 與 Windows 腳本同一個原則：**只動這一包帶來的那些頂層項目**
/// （`chatroom`、`data/`、`lib/`…）；安裝目錄裡其他東西不備份、不刪、不搬。
///
/// 結束碼：0 已替換；2 等不到 App 結束（沒替換）；3 備份失敗（沒替換）；
/// 4 這一包讀不到（沒替換）或替換失敗（已還原）；64 參數不對。
const String kApplyUpdateScriptLinux = r'''
#!/bin/sh
# Chatroom self-update (Linux). ASCII only, LF only.
#
# usage: apply-update.sh APP_DIR STAGED_DIR BACKUP_DIR EXE_PATH WAIT_PID [TIMEOUT_SEC]
#   APP_DIR     install dir (the folder holding the chatroom executable)
#   STAGED_DIR  the new bundle's contents, already extracted
#   BACKUP_DIR  the replaced top-level entries are copied here
#   EXE_PATH    executable to start again
#   WAIT_PID    pid of the running app; 0 = do not wait
# CHATROOM_UPDATE_NO_RELAUNCH=1 skips the final start (tests).
#
# Only the top-level entries shipped in the package are touched. Anything
# else sitting next to the executable is not ours to move or delete.

APP_DIR="$1"
STAGED="$2"
BACKUP="$3"
EXE="$4"
WAIT_PID="${5:-0}"
TIMEOUT="${6:-60}"
LOG="$(dirname "$0")/apply-update.log"

trap '' HUP

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null
}

relaunch() {
  if [ "$CHATROOM_UPDATE_NO_RELAUNCH" = "1" ]; then
    log 'relaunch skipped (CHATROOM_UPDATE_NO_RELAUNCH)'
    return 0
  fi
  cd "$APP_DIR" 2>/dev/null
  nohup "$EXE" >/dev/null 2>&1 &
  log "relaunched $EXE"
}

# Run "$@ NAME" for every top-level entry of the staged package.
each_entry() {
  for entry in "$STAGED"/* "$STAGED"/.[!.]*; do
    if [ -e "$entry" ] || [ -L "$entry" ]; then
      "$@" "$(basename "$entry")" || return 1
    fi
  done
  return 0
}

backup_one() {
  if [ -e "$APP_DIR/$1" ] || [ -L "$APP_DIR/$1" ]; then
    cp -a "$APP_DIR/$1" "$BACKUP/"
  fi
}

clear_one() {
  rm -rf "$APP_DIR/${1:?}"
}

copy_one() {
  cp -a "$STAGED/$1" "$APP_DIR/"
}

restore() {
  log 'restoring from backup'
  each_entry clear_one || log 'cleanup failed'
  for entry in "$BACKUP"/* "$BACKUP"/.[!.]*; do
    if [ -e "$entry" ] || [ -L "$entry" ]; then
      cp -a "$entry" "$APP_DIR/" || log "restore failed: $entry"
    fi
  done
  log 'restore finished'
}

if [ -z "$APP_DIR" ] || [ -z "$STAGED" ] || [ -z "$BACKUP" ] || [ -z "$EXE" ]; then
  log 'missing arguments'
  exit 64
fi

log "start app=$APP_DIR staged=$STAGED backup=$BACKUP exe=$EXE pid=$WAIT_PID"

if [ "$WAIT_PID" -gt 0 ] 2>/dev/null; then
  waited=0
  while kill -0 "$WAIT_PID" 2>/dev/null; do
    if [ "$waited" -ge "$TIMEOUT" ]; then
      # The app is still running: starting it again would open a second
      # instance, and replacing files under it would corrupt the live one.
      log "timeout: app still running after $TIMEOUT s, nothing replaced"
      exit 2
    fi
    sleep 1
    waited=$((waited + 1))
  done
fi
log 'app exited'

if [ ! -d "$STAGED" ] || [ -z "$(ls -A "$STAGED" 2>/dev/null)" ]; then
  log "staged dir empty or unreadable, nothing replaced: $STAGED"
  relaunch
  exit 4
fi

rm -rf "$BACKUP"
if ! mkdir -p "$BACKUP" || ! each_entry backup_one; then
  log 'backup failed, nothing replaced'
  relaunch
  exit 3
fi
log 'backup copied'

if ! each_entry clear_one || ! each_entry copy_one; then
  log 'replace failed'
  restore
  relaunch
  exit 4
fi

log 'update applied'
relaunch
exit 0
''';
