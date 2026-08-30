import 'dart:async';
import 'dart:collection';

import '../models/message.dart';
import '../models/question.dart';

/// 單一房間的訊息 store。REST 與 WS 都走同一條 upsert 路徑——
/// 重連補訊、冷啟動載入、往上捲歷史共用同一份合併邏輯。
///
/// cursor 契約（與 UI-DESIGN §3.3 的差異，實作時已修正）：
/// seq 與 update_seq 共用 room.next_seq 計數器，seq 天生有洞，
/// 「連續前綴」演算法會在洞上永遠卡住。cursor 一律取
/// max(seq, update_seq) 的最大值，與 server long-poll 的 last_seq 同語意。
/// 漏訊由 WS subscribe 的 pump 補（server 端從 after_seq 起掃，不會漏）。
class RoomFeed {
  RoomFeed(this.roomId);

  final String roomId;

  final SplayTreeMap<int, Message> _bySeq = SplayTreeMap();
  final Map<String, int> _idToSeq = {};

  int _cursor = 0;
  int? _oldestLoadedSeq;
  bool _hasMoreHistory = false;
  String? _roomStatus;

  final _changes = StreamController<void>.broadcast();

  /// 訊息以 seq 遞增排列的唯讀視圖。
  Iterable<Message> get messages => _bySeq.values;
  int get length => _bySeq.length;
  bool get isEmpty => _bySeq.isEmpty;

  /// 送給 WS subscribe.after_seq 與 REST after_seq 的 cursor。
  int get cursor => _cursor;

  int? get oldestLoadedSeq => _oldestLoadedSeq;
  bool get hasMoreHistory => _hasMoreHistory;

  /// WS 推播順帶的房間狀態（archived 偵測）。
  String? get roomStatus => _roomStatus;

  List<Question> _questions = const [];

  /// 目前指名問「我」的待答問題（server 推完整快照，直接覆蓋）。
  List<Question> get questions => _questions;

  final _vanished = StreamController<List<Question>>.broadcast();

  /// 「本來在待答清單上、這次不見了」的題目。
  ///
  /// 題目會消失有三種原因：我回答了、逾時了、或**發問者撤回了**。前兩種
  /// 使用者自己知道，第三種不講的話，畫面上就是一題無聲消失——他會以為是
  /// 自己漏看了，而下一次他就不會信任這個清單。
  Stream<List<Question>> get questionsVanished => _vanished.stream;

  /// 覆蓋而非合併：已被回答或略過的問題會從 server 的快照中消失，
  /// 用合併的話它們會永遠留在畫面上。
  void setQuestions(List<Question> incoming) {
    if (_sameQuestionIds(incoming)) return;
    final ids = {for (final q in incoming) q.id};
    final gone = [for (final q in _questions) if (!ids.contains(q.id)) q];
    _questions = List.unmodifiable(incoming);
    if (gone.isNotEmpty && !_vanished.isClosed) _vanished.add(gone);
    _notify();
  }

  bool _sameQuestionIds(List<Question> incoming) {
    if (_questions.length != incoming.length) return false;
    for (var i = 0; i < incoming.length; i++) {
      if (_questions[i].id != incoming[i].id) return false;
    }
    return true;
  }

  Stream<void> get changes => _changes.stream;

  Message? byId(String id) {
    final seq = _idToSeq[id];
    return seq == null ? null : _bySeq[seq];
  }

  Message? bySeq(int seq) => _bySeq[seq];

  /// 唯一的訊息寫入入口。**覆寫，不是 skip**——server 推的是完整快照，
  /// 同一 seq 第二次到達時 pinned/deleted 可能已變。
  ///
  /// 回傳「本次新增（先前不存在）的訊息數」，供未讀提示用。
  int upsertAll(Iterable<Message> incoming) {
    var added = 0;
    for (final m in incoming) {
      // cursor 永遠推進（否則 resubscribe 會反覆重推同一批更新）
      if (m.cursor > _cursor) _cursor = m.cursor;
      // 舊於已載入視窗的訊息不進 store：釘選/刪除舊訊息時 pump 會推完整
      // 快照，把它塞進來會在時間軸上造成「假連續」的洞。
      final oldest = _oldestLoadedSeq;
      if (oldest != null && m.seq < oldest) {
        continue;
      }
      if (!_bySeq.containsKey(m.seq)) added++;
      _bySeq[m.seq] = m;
      _idToSeq[m.id] = m.seq;
    }
    if (_bySeq.isNotEmpty) {
      _oldestLoadedSeq ??= _bySeq.firstKey();
    }
    _notify();
    return added;
  }

  /// 往上捲載入的歷史批次（before_seq 分頁的結果）。
  void prependHistory(Iterable<Message> older, {required bool hasMore}) {
    for (final m in older) {
      if (m.cursor > _cursor) _cursor = m.cursor;
      if (!_bySeq.containsKey(m.seq)) {
        _bySeq[m.seq] = m;
        _idToSeq[m.id] = m.seq;
      }
    }
    if (_bySeq.isNotEmpty) _oldestLoadedSeq = _bySeq.firstKey();
    _hasMoreHistory = hasMore;
    _notify();
  }

  /// 冷啟動 / 補訊保險絲超限時的全量重置。
  void reset() {
    _bySeq.clear();
    _idToSeq.clear();
    _cursor = 0;
    _oldestLoadedSeq = null;
    _hasMoreHistory = false;
    _questions = const [];
    _notify();
  }

  void setHasMoreHistory(bool value) {
    _hasMoreHistory = value;
    _notify();
  }

  void setRoomStatus(String? status) {
    if (status == null || status == _roomStatus) return;
    _roomStatus = status;
    _notify();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void dispose() {
    _vanished.close();
    _changes.close();
  }
}
