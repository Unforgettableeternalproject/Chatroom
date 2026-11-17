import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/platform/app_platform.dart';

/// macOS／Linux 的服務管理（systemd user／LaunchAgent）。
///
/// 對應 Windows 的 `hub-service.ps1` 與 `install-task.ps1`，由 kit 自帶的
/// `scripts/service.py` 負責：
///
///     <kit venv python> <service.py> {hub|runner} {install|uninstall|start|stop|status} [--json]
///
/// `status --json` 的欄位是與 Python 端約好的契約：
/// `{"manager": "systemd|launchd|none", "installed", "enabled", "running", "detail"}`。
/// 其他動作用 `--json` 時印 `{"ok", "manager", "detail"}`。

/// service.py 在 kit 根目錄底下的位置。**單一常數**：Hub kit 與 Runner kit
/// 都是 `scripts/service.py`；Python 端搬動時只改這裡。
const List<String> kServiceScriptRelPath = ['scripts', 'service.py'];

enum ServiceKind { hub, runner }

/// 要執行的一條命令。
@immutable
class CommandLine {
  const CommandLine(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}

/// 組出 `<python> <service.py> <kind> <action> --json`。
///
/// [python] 省略時用 kit 自己的 venv（`.venv/bin/python`）——**不是系統的
/// `python3`**：service.py 雖只用標準庫，但服務單元記下的直譯器路徑要指向 kit
/// 的 venv，那也是 Python 端預設的做法。
CommandLine posixServiceCommand({
  required String kitRoot,
  required ServiceKind kind,
  required String action,
  String? python,
  bool json = true,
}) {
  final sep = AppPlatform.linux.sep; // POSIX 一律正斜線
  final py = (python != null && python.trim().isNotEmpty)
      ? python.trim()
      : [kitRoot, '.venv', 'bin', 'python'].join(sep);
  final script = [kitRoot, ...kServiceScriptRelPath].join(sep);
  return CommandLine(py, [
    script,
    kind.name,
    action,
    if (json) '--json',
  ]);
}

/// `service.py ... status --json` 的結果。
@immutable
class PosixServiceStatus {
  const PosixServiceStatus({
    required this.manager,
    required this.installed,
    required this.enabled,
    required this.running,
    required this.detail,
  });

  /// `systemd`／`launchd`／`none`。
  final String manager;
  final bool installed;
  final bool enabled;
  final bool running;
  final String detail;
}

/// 解析 `status --json`。**解析失敗回 `null`**——呼叫端要當成「問不到」，
/// 不能編一個「沒註冊」出來（那會讓使用者去重新註冊一個其實存在的服務）。
PosixServiceStatus? parsePosixServiceStatus(String stdout) {
  final text = stdout.trim();
  if (text.isEmpty) return null;
  // 取最後一行 JSON：服務管理員偶爾會在前面印進度
  for (final line in const LineSplitter().convert(text).reversed) {
    final t = line.trim();
    if (!t.startsWith('{')) continue;
    try {
      final decoded = jsonDecode(t);
      if (decoded is! Map) continue;
      bool flag(String key) => decoded[key] == true;
      return PosixServiceStatus(
        manager: '${decoded['manager'] ?? 'none'}',
        installed: flag('installed'),
        enabled: flag('enabled'),
        running: flag('running'),
        detail: '${decoded['detail'] ?? ''}',
      );
    } on FormatException {
      continue;
    }
  }
  return null;
}

/// 把 `--json` 的動作結果（`{"ok", "detail"}`）攤平成呼叫端習慣的
/// 形狀：成功＝exit 0、detail 在 stdout；失敗＝非 0、原因在 stderr。
///
/// 🔴 **用 exit code 與 `ok` 判成敗**，不用「stderr 有沒有東西」：POSIX 這支
/// 沒有 PowerShell 的 `Write-Warning` 那條路。
ProcessResult normalizeServiceResult(ProcessResult r) {
  final out = '${r.stdout}'.trim();
  final err = '${r.stderr}'.trim();
  Map<dynamic, dynamic>? json;
  for (final line in const LineSplitter().convert(out).reversed) {
    final t = line.trim();
    if (!t.startsWith('{')) continue;
    try {
      final d = jsonDecode(t);
      if (d is Map) {
        json = d;
        break;
      }
    } on FormatException {
      continue;
    }
  }
  if (json == null) {
    // 不是 JSON（腳本在更早的地方就倒了）：照原樣，失敗時把 stdout 補進 stderr
    if (r.exitCode != 0 && err.isEmpty && out.isNotEmpty) {
      return ProcessResult(r.pid, r.exitCode, '', out);
    }
    return r;
  }
  final detail = '${json['detail'] ?? ''}'.trim();
  final ok = r.exitCode == 0 && json['ok'] != false;
  if (ok) return ProcessResult(r.pid, 0, detail, err);
  return ProcessResult(r.pid, r.exitCode != 0 ? r.exitCode : 1, '',
      detail.isNotEmpty ? detail : err);
}

/// 開資料夾的命令（日誌、備份）。Windows `explorer`、macOS `open`、
/// Linux `xdg-open`。
CommandLine openFolderCommand(AppPlatform platform, String path) =>
    switch (platform) {
      AppPlatform.windows => CommandLine('explorer', [path]),
      AppPlatform.macos => CommandLine('open', [path]),
      AppPlatform.linux => CommandLine('xdg-open', [path]),
    };
