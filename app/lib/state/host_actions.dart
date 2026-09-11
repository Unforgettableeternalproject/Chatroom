import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'host_kit_providers.dart';
import 'host_probe.dart';

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
    return const TunnelStatus(ProbeState.unknown, '', '找不到主持包');
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
    return const TunnelStatus(ProbeState.unknown, '', '沒有開著的隧道',
        caveat: '成員只能從內網或 VPN 連進來');
  }

  final ok = await probeHealth('$url/api/health');
  if (ok) {
    return TunnelStatus(ProbeState.ok, url, '隧道開著',
        caveat: '網址是臨時的——關掉視窗就失效，重開會是不一樣的網址');
  }
  return TunnelStatus(
    ProbeState.unknown,
    url,
    '有網址，但從這台機器打不通',
    caveat: '兩種可能，本機分不出來：①隧道其實活著，只是這台機器繞不回自己的'
        '公網網址（很常見）②隧道已經關了、這個檔案是殘留的。'
        '請成員或手機開一次那個網址',
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
  if (!Platform.isWindows) return null;
  final kit = await ref.watch(hostKitProvider.future);
  if (kit == null) return null;
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
    return ServiceStatus(false, '問不到服務狀態（$e）');
  }
});

/// 對本機 Hub 的操作。
///
/// **每一個都是既有腳本的包裝，不新增第二條真相來源**——這一頁壞掉的時候，
/// 主持人照著 README 用命令列仍然做得到同樣的事
/// （`docs/KIT-UI-DESIGN-BRIEF.md` §5 最後一條）。
class HostActions {
  const HostActions(this._kitRoot);

  final String _kitRoot;

  String _script(String name) =>
      '$_kitRoot${Platform.pathSeparator}scripts${Platform.pathSeparator}$name';

  /// kit 自帶的直譯器。**不是系統的 `python`**——kit 的依賴裝在這個 venv 裡，
  /// 走系統那支會 ModuleNotFoundError，而錯誤訊息指向的是使用者沒裝過的東西。
  String get _python => '$_kitRoot${Platform.pathSeparator}.venv'
      '${Platform.pathSeparator}Scripts${Platform.pathSeparator}python.exe';

  /// 前景啟動 Hub。
  ///
  /// 🔴 **detached 是關鍵**：這個 App 只是遙控器，關掉它不能把伺服器一起帶走。
  /// 不加這個旗標的話，Flutter 進程結束時子進程會跟著收掉——所有人在那一刻
  /// 斷線，而按下按鈕的人完全不會預期關個視窗會發生這種事。
  Future<void> startHub() => Process.start(
        'cmd',
        ['/c', 'start', '', _script('run-hub.cmd')],
        mode: ProcessStartMode.detached,
        runInShell: true,
      );

  /// 開隧道。同樣 detached，理由同上。
  Future<void> startTunnel() => Process.start(
        'cmd',
        ['/c', 'start', '', _script('run-tunnel.cmd')],
        mode: ProcessStartMode.detached,
        runInShell: true,
      );

  Future<ProcessResult> service(String action) => Process.run(
        'powershell',
        ['-NoProfile', '-File', _script('hub-service.ps1'), action],
        runInShell: true,
      );

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
  Future<ProcessResult> backup() => Process.run(
        _python,
        [_script('backup.py'), '--json'],
        runInShell: true,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );

  /// 換掉 token。**換完還要重啟 Hub 才生效**，呼叫端要講清楚這件事。
  Future<ProcessResult> rotateToken() => Process.run(
        _python,
        [_script('rotate-token.py'), '--json'],
        runInShell: true,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );

  /// 開啟日誌資料夾。**不在 App 裡做 log 檢視器**——出事時要看的東西
  /// 千奇百怪，作業系統的檔案總管比我們做得好。
  Future<void> openLogs() => Process.start(
        'explorer',
        ['$_kitRoot${Platform.pathSeparator}logs'],
        mode: ProcessStartMode.detached,
        runInShell: true,
      );

  /// 開啟備份資料夾。同上——還原是檔案總管的工作，不是這一頁的。
  Future<void> openBackups() => Process.start(
        'explorer',
        ['$_kitRoot${Platform.pathSeparator}backups'],
        mode: ProcessStartMode.detached,
        runInShell: true,
      );
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
        : (out.isNotEmpty ? out : '腳本沒有輸出（結束碼 ${result.exitCode}）'),
  };
}

final hostActionsProvider = Provider<HostActions?>((ref) {
  final kit = ref.watch(hostKitProvider).value;
  if (kit == null) return null;
  return HostActions(kit.kitRoot);
});
