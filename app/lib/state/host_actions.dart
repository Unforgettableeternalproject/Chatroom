import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/platform/app_platform.dart';
import '../l10n/l10n.dart';
import 'host_kit_providers.dart';
import 'host_probe.dart';
import 'posix_service.dart';

/// 隧道現在的樣子。
@immutable
class TunnelStatus {
  const TunnelStatus(this.state, this.url, this.detail, {this.caveat = ''});

  final ProbeState state;

  /// `.tunnel-url` 裡那份；沒開時是空字串。
  final String url;
  final String detail;
  final String caveat;

  bool get hasUrl => url.isNotEmpty;
}

/// 隧道狀態。
///
/// `scripts/tunnel.py` 起來時把網址寫進 `server/.tunnel-url`，結束時在
/// `finally` 裡刪掉——所以那個檔案在**正常**情況下就是「隧道開著」的信號。
///
/// 🔴 **但它會殘留。** 隧道視窗被強制關掉、當機、機器直接斷電時，`finally`
/// 不會執行，檔案留在原地——那時 App 會顯示一個早就失效的網址，而主持人會
/// 把它發給成員。所以讀到網址之後還要驗一次。
///
/// ⚠️ 而那個驗證**天生驗不準**：從 Hub 這台機器打自己的公網網址，常常因為
/// 路由器不支援 hairpin 或本機 DNS 解到沒有出口的那一族而失敗
/// （`scripts/tunnel.py` 的註解已經記過這件事）。所以「有網址但打不通」
/// 只能是 `unknown`——它同時可能是「殘留的死網址」與「活著但本機繞不回來」，
/// 而這兩種在這台機器上分不出來。畫成紅燈會讓人去關一條好好的隧道。
final tunnelStatusProvider = FutureProvider<TunnelStatus>((ref) async {
  final kit = await ref.watch(hostKitProvider.future);
  if (kit == null) {
    return TunnelStatus(ProbeState.unknown, '', L10n.current.hostTunnelNoKit);
  }
  final file = File('${kit.kitRoot}${Platform.pathSeparator}server'
      '${Platform.pathSeparator}.tunnel-url');
  String url = '';
  try {
    if (await file.exists()) url = (await file.readAsString()).trim();
  } on Object {
    url = '';
  }
  if (url.isEmpty) {
    return TunnelStatus(ProbeState.unknown, '', L10n.current.hostTunnelOff);
  }

  final ok = await probeHealth('$url/api/health');
  if (ok) {
    return TunnelStatus(ProbeState.ok, url, L10n.current.hostTunnelOn);
  }

  // 🔴 打不通的時候先問一句「Hub 還在嗎」。
  //
  // 原本這裡只講隧道的兩種可能，於是 Hub 沒跑的人會盯著隧道找原因——
  // 而那是**這一頁答得出來的問題**：`hostHealthProvider` 知道本機 Hub 在不在。
  // 「兩種可能，本機分不出來」在 Hub 已經停掉時是**假的**：分得出來，
  // 只是沒有人去問。
  final health = await ref.watch(hostHealthProvider.future);
  if (health != null && health.process.state == ProbeState.bad) {
    return TunnelStatus(
      ProbeState.bad,
      url,
      L10n.current.hostTunnelHubStopped,
    );
  }

  return TunnelStatus(
    ProbeState.unknown,
    url,
    L10n.current.hostTunnelUnreachable,
  );
});

/// 服務（排程任務）的註冊狀態。
@immutable
class ServiceStatus {
  const ServiceStatus(this.registered, this.raw);

  final bool registered;

  /// `hub-service.ps1 status` 的原文。**原樣顯示**——它已經把該講的講清楚了
  /// （任務狀態、上次執行結果、Hub 進程 PID），重寫一遍只會讓兩邊不一致。
  final String raw;
}

final serviceStatusProvider = FutureProvider<ServiceStatus?>((ref) async {
  final platform = ref.watch(appPlatformProvider);
  if (platform == null) return null;
  final kit = await ref.watch(hostKitProvider.future);
  if (kit == null) return null;
  if (platform.isPosix) {
    // 服務管理員（systemd／LaunchAgent）由 kit 自帶的 service.py 問
    return posixHubServiceStatus(HostActions(kit.kitRoot, platform: platform));
  }
  try {
    final r = await Process.run(
      'powershell',
      [
        '-NoProfile',
        '-File',
        '${kit.kitRoot}${Platform.pathSeparator}scripts'
            '${Platform.pathSeparator}hub-service.ps1',
        'status',
      ],
      runInShell: true,
    );
    final out = '${r.stdout}'.trim();
    return ServiceStatus(!out.startsWith('未註冊'), out);
  } on Object catch (e) {
    return ServiceStatus(false, L10n.current.hostServiceStatusError('$e'));
  }
});

/// 對本機 Hub 的操作。
///
/// **每一個都是既有腳本的包裝，不新增第二條真相來源**——這一頁壞掉的時候，
/// 主持人照著 README 用命令列仍然做得到同樣的事
/// （kit UI 設計簡報 §5 最後一條）。
class HostActions {
  const HostActions(this._kitRoot, {AppPlatform? platform, ProcessRun? run})
      : _platformOverride = platform,
        // 具名參數不能是私有的，所以不能用 initializing formal
        // ignore: prefer_initializing_formals
        _run = run;

  final String _kitRoot;

  /// 命令與路徑跟著它走。測試注入來覆蓋另一個平台的分支；省略就看這台機器。
  final AppPlatform? _platformOverride;

  AppPlatform get _platform =>
      _platformOverride ?? detectAppPlatform() ?? AppPlatform.windows;

  /// 測試換掉子進程。省略時真的跑。
  final ProcessRun? _run;

  bool get _posix => _platform.isPosix;

  String get _sep => _platform.sep;

  String _script(String name) => '$_kitRoot${_sep}scripts$_sep$name';

  /// kit 自帶的直譯器。**不是系統的 `python`**——kit 的依賴裝在這個 venv 裡，
  /// 走系統那支會 ModuleNotFoundError，而錯誤訊息指向的是使用者沒裝過的東西。
  String get _python => _posix
      ? '$_kitRoot$_sep.venv${_sep}bin${_sep}python'
      : '$_kitRoot$_sep.venv${_sep}Scripts${_sep}python.exe';

  /// 跑一支腳本並等結果。**encoding 一定要設**（見 [service] 的說明）。
  ///
  /// `runInShell` 只在 Windows：那邊要靠 shell 解析 `powershell` 這類名字；
  /// POSIX 上它只是把參數用空白接起來丟給 /bin/sh，路徑有空白
  /// （`Application Support`）就會被拆開。
  Future<ProcessResult> _exec(String executable, List<String> arguments) {
    final run = _run;
    if (run != null) return run(executable, arguments);
    return Process.run(
      executable,
      arguments,
      runInShell: !_posix,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
  }

  /// 服務管理員那支（`service.py hub <action>`）。
  Future<ProcessResult> _posixService(String action) {
    final c = posixServiceCommand(
        kitRoot: _kitRoot, kind: ServiceKind.hub, action: action);
    return _exec(c.executable, c.arguments).then(normalizeServiceResult);
  }

  /// 登入自啟（systemd／LaunchAgent）現在的樣子。
  ///
  /// service.py 沒印出可解析的 JSON 時丟 [StateError]（帶 stderr 第一行）。
  Future<PosixServiceStatus> posixServiceStatus() async {
    final c = posixServiceCommand(
        kitRoot: _kitRoot, kind: ServiceKind.hub, action: 'status');
    final r = await _exec(c.executable, c.arguments);
    final parsed = parsePosixServiceStatus('${r.stdout}');
    if (parsed != null) return parsed;
    final err = '${r.stderr}'.trim();
    final first = err.isNotEmpty ? const LineSplitter().convert(err).first : '';
    throw StateError(first.isNotEmpty ? first : 'exit ${r.exitCode}');
  }

  /// 無視窗啟動，而且**不綁這個 App**。
  ///
  /// 🔴 這兩件事必須同時成立，而 Windows 上從 Dart 做不到：
  /// `ProcessStartMode.detached` 對應 `DETACHED_PROCESS`，而 console 程式用
  /// 那個旗標啟動時會**自己配一個新 console**——那就是那個空的黑視窗。
  /// `CREATE_NO_WINDOW` 才是要的，但 Dart 沒有開放那個旗標。
  ///
  /// 所以繞道 `wscript`（GUI 宿主）。2026-09-11 實測四種起法，只有這條的
  /// `IsWindowVisible` 是 0，理由與數據寫在 `scripts/hidden-launch.vbs`。
  ///
  /// ⚠️ 隱藏之後 log 從方便升級成**唯一**的診斷來源。`run-hub.cmd` 已經把
  /// stdout/stderr 導進 `logs\hub-YYYYMMDD.log`，那條路徑不能再被拿掉。
  Future<void> _launchHidden(String script) => Process.start(
        'wscript',
        ['//nologo', _script('hidden-launch.vbs'), script],
        mode: ProcessStartMode.detached,
        runInShell: true,
      );

  /// POSIX 的背景啟動：沒有主控台視窗的問題，`detached` 就是「不綁這個 App」。
  /// 用 `/bin/sh <腳本>` 起，不靠檔案的執行位元（腳本第一行就是 `#!/bin/sh`）。
  /// 輸出由腳本自己導進 `logs/`——那條路徑與 Windows 一樣是唯一的診斷來源。
  @visibleForTesting
  ({String executable, List<String> arguments, Map<String, String> environment})
      backgroundLaunch(String scriptName, {bool hidden = false}) => (
            executable: '/bin/sh',
            arguments: [_script(scriptName)],
            // run-tunnel.sh 看這個決定「輸出進 log、不 pause」，
            // 等同 Windows 上 hidden-launch.vbs 設的變數
            environment: hidden ? const {'CHATROOM_HIDDEN': '1'} : const {},
          );

  Future<void> _launchBackground(String scriptName, {bool hidden = false}) {
    final c = backgroundLaunch(scriptName, hidden: hidden);
    return Process.start(
      c.executable,
      c.arguments,
      workingDirectory: _kitRoot,
      environment: c.environment,
      mode: ProcessStartMode.detached,
    );
  }

  /// 前景啟動 Hub（無視窗）。
  ///
  /// 🔴 **不綁 App 是關鍵**：這個 App 只是遙控器，關掉它不能把伺服器一起帶走。
  /// 所有人會在那一刻斷線，而按下按鈕的人完全不會預期關個視窗會發生這種事。
  ///
  /// 停止入口不再依賴這個視窗——`7f56a8a` 之後「停止 Hub」就在「啟動 Hub」
  /// 旁邊。**順序很重要**：先隱藏視窗、後補停止鍵的話，中間會有一段
  /// Hub 關不掉的空窗。
  Future<void> startHub() => _posix
      ? _launchBackground('run-hub.sh')
      : _launchHidden(_script('run-hub.cmd'));

  /// 開隧道。同樣無視窗、同樣不綁 App。
  ///
  /// ⚠️ 隱藏之後那個視窗就不再是網址的出口了。網址沒有消失——`tunnel.py`
  /// 會寫 `server/.tunnel-url`，上面的隧道區塊讀的就是它；出錯時的細節在
  /// `logs\tunnel-YYYYMMDD.log`（`run-tunnel.cmd` 只在隱藏啟動時重導向，
  /// 雙擊執行仍然留在螢幕上並 pause）。
  Future<void> startTunnel() => _posix
      ? _launchBackground('run-tunnel.sh', hidden: true)
      : _launchHidden(_script('run-tunnel.cmd'));

  /// 關隧道。
  ///
  /// 🔴 這裡原本刻意**不做**這顆按鈕，理由是「做一顆按鈕去殺別人的進程，
  /// 會在殺錯的時候完全看不出來」。那個顧慮成立，但它的解法不是不做，
  /// 是讓它認得出自己殺的是誰——`tunnel.py` 現在把 cloudflared 的 PID 寫進
  /// `server/.tunnel-pid`，`stop-tunnel.py` 殺之前會比對那個 PID 的命令列。
  /// 對不上就拒絕動手（PID 會被系統重用，光看號碼不構成證據）。
  ///
  /// 不做的代價是使用者只剩「去把那個黑視窗關掉」一條路——而那條路
  /// 從來沒有人告訴過他，跟「停止 Hub」原本的處境一模一樣。
  Future<ProcessResult> stopTunnel() => _exec(_python, [_script('stop-tunnel.py'), '--json']);

  /// 有哪些備份可以還原。
  Future<ProcessResult> listBackups() => _exec(_python, [_script('restore.py'), '--list', '--json']);

  /// 從某一份備份還原。
  ///
  /// ⚠️ 腳本自己擋著三件事（Hub 還在跑、備份打不開、沒先備份現況），
  /// **UI 不重複實作那些判斷**——兩份判準會在某次改動後分岔，而分岔的那一刻
  /// 沒有任何地方報錯。這裡只負責把結果講給使用者聽。
  Future<ProcessResult> restoreBackup(String path) => _exec(_python, [_script('restore.py'), '--from', path, '--json']);

  /// ⚠️ **encoding 一定要設。** 不設的話 Windows 上拿回來的是被系統碼頁
  /// 解讀過的位元組，腳本講的每一句中文都變成亂碼——而這支腳本的輸出
  /// 正是「停止到底成功了沒」的唯一來源。
  /// （backup／rotateToken／stopTunnel 都設了，只有這支漏掉。）
  ///
  /// POSIX 走 `service.py hub <action>`（systemd／LaunchAgent）。結果攤平成
  /// 同一個形狀：成功＝exit 0、說明在 stdout；失敗＝非 0、原因在 stderr。
  Future<ProcessResult> service(String action) => _posix
      ? _posixService(action)
      : _exec('powershell',
          ['-NoProfile', '-File', _script('hub-service.ps1'), action]);

  /// 停止 Hub——**前景跑的那個也停得掉**。
  ///
  /// 包的是 `hub-service.ps1 stop`，它停用排程觸發器之後會殺掉所有
  /// command line 含 `chatroom_server` 的 python 進程，手動起的也在內。
  /// 排程沒註冊時前半段靜靜跳過，後半段照樣做事。
  ///
  /// 🔴 這支與「取消註冊」是兩件事，UI 上不可以只有一個按鈕：
  /// 停止＝現在關掉、還會自己回來；取消註冊＝以後不要再自己起來。
  Future<ProcessResult> stopHub() => service('stop');

  /// 備份資料庫與附件。
  ///
  /// 同步等結果（不是 detached）——**使用者需要知道備份到哪裡、有多大**。
  /// 一個「已開始備份」的提示對備份這種功能沒有意義：它的價值全在
  /// 「那份東西真的在磁碟上」，而那件事只有跑完才知道。
  Future<ProcessResult> backup() => _exec(_python, [_script('backup.py'), '--json']);

  /// 換掉 token。**換完還要重啟 Hub 才生效**，呼叫端要講清楚這件事。
  Future<ProcessResult> rotateToken() => _exec(_python, [_script('rotate-token.py'), '--json']);

  /// 開啟日誌資料夾。**不在 App 裡做 log 檢視器**——出事時要看的東西
  /// 千奇百怪，作業系統的檔案總管比我們做得好。
  Future<void> openLogs() => _openFolder('$_kitRoot${_sep}logs');

  /// 開啟備份資料夾。同上——還原是檔案總管的工作，不是這一頁的。
  Future<void> openBackups() => _openFolder('$_kitRoot${_sep}backups');

  /// 用作業系統的檔案管理員開資料夾。命令見 [openFolderCommand]。
  Future<void> _openFolder(String path) {
    final c = openFolderCommand(_platform, path);
    return Process.start(
      c.executable,
      c.arguments,
      mode: ProcessStartMode.detached,
      // explorer 在 Windows 要靠 shell 找；POSIX 的 open／xdg-open 直接 exec
      runInShell: !_posix,
    );
  }
}

/// 測試用：換掉子進程。
typedef ProcessRun = Future<ProcessResult> Function(
    String executable, List<String> arguments);

/// Hub 登入自啟的狀態（POSIX）。問不到（service.py 沒印 JSON、跑不起來）
/// 回「沒註冊」並帶原因——與 Windows 那邊出錯時同一個形狀。
Future<ServiceStatus> posixHubServiceStatus(HostActions actions) async {
  try {
    final st = await actions.posixServiceStatus();
    return ServiceStatus(st.installed, st.detail);
  } on Object catch (e) {
    return ServiceStatus(false, L10n.current.hostServiceStatusError('$e'));
  }
}

/// 把腳本的 `--json` 輸出解析回來。
///
/// 🔴 **解析失敗要當成失敗**，不可以回一個「成功但沒有細節」的結果。
/// 腳本在 Windows 主控台可能吐出編碼壞掉的字、或在 stderr 留下 traceback，
/// 那時 stdout 不是 JSON——而把它當成功的話，使用者會看到一個綠色的
/// 「備份完成」，磁碟上什麼都沒有。
Map<String, dynamic> parseScriptResult(ProcessResult result) {
  final out = '${result.stdout}'.trim();
  if (out.isNotEmpty) {
    try {
      final decoded = jsonDecode(out);
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } on FormatException {
      // 落到下面的錯誤路徑
    }
  }
  final err = '${result.stderr}'.trim();
  return {
    'ok': false,
    'error': err.isNotEmpty
        ? err
        : (out.isNotEmpty
            ? out
            : L10n.current.hostScriptNoOutput('${result.exitCode}')),
  };
}

final hostActionsProvider = Provider<HostActions?>((ref) {
  final kit = ref.watch(hostKitProvider).value;
  if (kit == null) return null;
  return HostActions(kit.kitRoot, platform: ref.watch(appPlatformProvider));
});
