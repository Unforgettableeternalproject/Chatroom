import 'dart:async';

import '../l10n/l10n.dart';
import '../models/ops_exception.dart';
import 'notification_center.dart';

/// 派工例外 → 系統通知。
///
/// 只推**需要人立刻介入**的那兩種（[OpsException.notifiable]）：
/// - `runner_offline`：機器掉線，要有人去看排程任務或那台電腦
/// - `timeout`：一筆 run 已經被強制終止，原本期待的結果不會來了
///
/// 停滯／額度受限／恢復只進面板：它們是已知會自動恢復的暫時狀態，推播
/// 只會製造疲勞，然後連該看的那兩種也一起被忽略。
///
/// 「App 開著才發」是這條管線的既有前提——通知由 App 進程投出，關掉就沒有
/// 人在輪詢。**首批不通知**：第一次拿到的是歷史視窗，逐則投出等於一開 App
/// 就被昨天的事轟炸（同 `NotificationCenter` 的基準線作法）。
class OpsExceptionNotifier {
  OpsExceptionNotifier({required this.fetch, required this.show});

  /// 撈最近的例外（由 provider 層接上 `OpsExceptionsApi`）。
  final Future<List<OpsException>> Function() fetch;

  /// 投一則 OS 通知。
  final void Function(RoomNotification) show;

  /// 已經投過（或被當成歷史略過）的最新事件時間。空＝還沒有基準線。
  String _watermark = '';
  bool _seeded = false;
  Timer? _timer;

  String get watermark => _watermark;

  /// 跑一輪：撈、過濾、投。回傳這一輪投出去的則數（測試用）。
  Future<int> pollOnce() async {
    final List<OpsException> list;
    try {
      list = await fetch();
    } catch (_) {
      // 撈不到就這一輪不做事：Hub 斷線本身不是派工例外，投一則「監控器
      // 失敗」只會蓋掉真正的訊息
      return 0;
    }
    if (list.isEmpty) return 0;
    final newest = list
        .map((e) => e.createdAt)
        .reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
    if (!_seeded) {
      _seeded = true;
      _watermark = newest;
      return 0;
    }
    final fresh = list
        .where((e) => e.notifiable && e.createdAt.compareTo(_watermark) > 0)
        .toList()
      // 舊的先投：通知列上最後一則才是最新的那件事
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    for (final e in fresh) {
      show(RoomNotification(
        roomId: e.roomId,
        roomName: e.roomName.isEmpty
            ? L10n.current.opsExceptionFallbackRoom
            : e.roomName,
        body: e.title,
        // 例外不是「有人提及你」。借用 mentioned 會讓標題變成一句假話
        mentioned: false,
      ));
    }
    if (newest.compareTo(_watermark) > 0) _watermark = newest;
    return fresh.length;
  }

  /// 開始輪詢。重複呼叫只會有一條迴圈。
  void start({Duration every = const Duration(seconds: 30)}) {
    _timer?.cancel();
    unawaited(pollOnce());
    _timer = Timer.periodic(every, (_) => unawaited(pollOnce()));
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
