import 'dart:async';

import 'package:logging/logging.dart';

import '../api/messages_api.dart';
import '../models/ws_event.dart';
import 'reconnect_policy.dart';
import 'room_feed.dart';
import 'ws_client.dart';
import 'ws_protocol.dart';

final _log = Logger('realtime');

/// 對 UI 曝露的連線狀態（UI-DESIGN §4.1）。
sealed class RealtimeStatus {
  const RealtimeStatus();
}

class Disconnected extends RealtimeStatus {
  const Disconnected({this.reason});
  final String? reason; // manual | token | background | null(未啟動)
  bool get tokenRejected => reason == 'token';
}

class Connecting extends RealtimeStatus {
  const Connecting();
}

class Syncing extends RealtimeStatus {
  const Syncing();
}

class Connected extends RealtimeStatus {
  Connected() : since = DateTime.now();
  final DateTime since;
}

class Reconnecting extends RealtimeStatus {
  Reconnecting({required this.attempt, required this.delay})
      : retryAt = DateTime.now().add(delay);
  final int attempt;
  final Duration delay;
  final DateTime retryAt; // UI 倒數用
}

/// 初始載入「最新視窗」用的 before_seq 上界（任何真實 seq 都小於它）。
const int kSeqInfinity = 1 << 52;

/// WS 狀態機 + 訂閱管理 + REST 補訊編排（UI-DESIGN §4 核心）。
/// 不 import 任何 flutter 套件——整層可用純 dart test 跑。
class RealtimeService {
  RealtimeService({
    required this.messagesApi,
    required this.wsUriBuilder,
    this.connector = defaultWsConnector,
    ReconnectPolicy? policy,
    this.initialWindow = 100,
    this.catchUpBatch = 200,
    this.catchUpMaxLoops = 50,
    this.heartbeatInterval = const Duration(seconds: 20),
    this.pongTimeout = const Duration(seconds: 10),
    this.feedRetention = const Duration(seconds: 30),
  }) : _policy = policy ?? ReconnectPolicy();

  final MessagesApi messagesApi;
  final Uri Function() wsUriBuilder;
  final WsConnector connector;
  final ReconnectPolicy _policy;

  final int initialWindow;
  final int catchUpBatch;
  final int catchUpMaxLoops;
  final Duration heartbeatInterval;
  final Duration pongTimeout;
  final Duration feedRetention;

  final Map<String, RoomFeed> _feeds = {};
  /// room_id → 本人在該房的 participant_id。subscribe 時一併送出，
  /// server 才知道該把哪些定向問題推過來。
  final Map<String, String> _participantIds = {};
  /// room_id → **已經隨 subscribe 送出去**的身分。與上面那份分開記，因為
  /// 「知道身分」與「server 知道我的身分」是兩件事——只記前者的話，身分在
  /// refCount 已經大於 1 時才補上（通知層先跟房、之後才開聊天室的正常時序）
  /// 就永遠不會送出去，而畫面上完全沒有異狀。
  final Map<String, String> _sentParticipantIds = {};
  final Map<String, int> _refCounts = {};
  final Map<String, Timer> _retireTimers = {};

  RealtimeStatus _status = const Disconnected();
  final _statusCtrl = StreamController<RealtimeStatus>.broadcast();

  bool _desired = false;
  WsConnection? _conn;
  Completer<void>? _connClosed;
  Completer<void>? _backoffSkip;
  int _attempt = 0;
  Timer? _heartbeatTimer;
  Timer? _pongDeadline;
  Future<void>? _loop;

  RealtimeStatus get status => _status;
  Stream<RealtimeStatus> get statusStream => _statusCtrl.stream;

  // ---------- 生命週期 ----------

  void start() {
    if (_desired) return;
    _desired = true;
    _attempt = 0;
    _loop = _runLoop();
  }

  Future<void> stop({String reason = 'manual'}) async {
    _desired = false;
    // retryNow() 可能已 complete 過同一個 completer 而 _backoff() 尚未清 null，
    // 無條件 complete 會 double-complete 丟 StateError
    final skip = _backoffSkip;
    if (skip != null && !skip.isCompleted) skip.complete();
    _backoffSkip = null;
    await _closeConn();
    await _loop;
    _setStatus(Disconnected(reason: reason));
  }

  /// 立即重試：取消退避等待並重置 attempt。
  /// 三個觸發點（UI-DESIGN §4.2）：網路恢復、回到前景、使用者按重試。
  void retryNow() {
    _attempt = 0;
    final skip = _backoffSkip;
    if (skip != null && !skip.isCompleted) skip.complete();
  }

  // ---------- 訂閱 ----------

  RoomFeed subscribe(String roomId, {String? participantId}) {
    _retireTimers.remove(roomId)?.cancel();
    if (participantId != null && participantId.isNotEmpty) {
      _participantIds[roomId] = participantId;
    }
    _refCounts[roomId] = (_refCounts[roomId] ?? 0) + 1;
    final feed = _feeds.putIfAbsent(roomId, () => RoomFeed(roomId));
    if (_refCounts[roomId] == 1 && _status is Connected) {
      // 已連線時的新訂閱：先載入再掛 WS（不阻塞呼叫端）
      unawaited(_attachRoom(roomId).catchError((Object e) {
        _log.warning('房間 $roomId 掛載失敗：$e');
      }));
    } else {
      // 已經有人訂閱著：身分若是這次才帶進來的，補送一次
      _syncSubscription(roomId);
    }
    return feed;
  }

  /// 身分是 join 之後才拿得到的，而訂閱在那之前就發生了。身分就緒時補一次
  /// subscribe，server 才知道要把哪些定向問題推過來——不補的話首次進房的人
  /// 會看不到問題，而且畫面上完全沒有異狀。
  void setParticipantId(String roomId, String participantId) {
    if (participantId.isEmpty) return;
    final firstTime = (_participantIds[roomId] ?? '').isEmpty;
    _participantIds[roomId] = participantId;
    _syncSubscription(roomId);
    // 首次拿到身分時把 REST 那半也補回來。房間是讀取邊界之後，沒有身分的
    // 那次載入會整個被拒——WS 補送 subscribe 只救得回「之後的新訊息」，
    // 歷史仍然是空的，而畫面上看起來就只是「這個房間沒有訊息」。
    if (firstTime && _feeds.containsKey(roomId)) {
      unawaited(_syncRoom(roomId).catchError((Object e) {
        _log.warning('房間 $roomId 取得身分後回補失敗：$e');
      }));
    }
  }

  void _forgetSentSubscriptions() => _sentParticipantIds.clear();

  /// server 手上的身分與我們現在知道的不一致時，補送一次 subscribe。
  void _syncSubscription(String roomId) {
    final want = _participantIds[roomId] ?? '';
    if (want.isEmpty || _sentParticipantIds[roomId] == want) return;
    if (!_feeds.containsKey(roomId) || _status is! Connected) return;
    _conn?.send(WsProtocol.subscribe(roomId, _feeds[roomId]?.cursor ?? 0,
        participantId: want));
    _sentParticipantIds[roomId] = want;
  }

  void unsubscribe(String roomId) {
    final count = (_refCounts[roomId] ?? 0) - 1;
    if (count > 0) {
      _refCounts[roomId] = count;
      return;
    }
    _refCounts.remove(roomId);
    _sentParticipantIds.remove(roomId);
    _conn?.send(WsProtocol.unsubscribe(roomId));
    // 延遲移除 store：房間之間來回切換不必重新載入
    _retireTimers[roomId]?.cancel();
    _retireTimers[roomId] = Timer(feedRetention, () {
      _retireTimers.remove(roomId);
      _feeds.remove(roomId)?.dispose();
      // feed 的生命週期到此結束，這個房的訂閱狀態整組作廢——身分也是。
      // 留著的話，下一輪全新生命週期的訂閱若沒帶 id 就會撿到上一輪的舊
      // pid。server 認得那個 pid（participant 記錄還在，只是 status 變了），
      // 所以不會報錯，只會把定向問題推給一個死掉的身分。
      //
      // ⚠️ 清理刻意**不放在 refCount 歸零的當下**：保留期的用意就是讓
      // 30 秒內的暖回訪沿用同一份訂閱狀態，提早砍會讓未帶 id 的回訪變成
      // 匿名訂閱，平白開一個定向問題收不到的短暫缺口。
      _participantIds.remove(roomId);
      _sentParticipantIds.remove(roomId);
    });
  }

  RoomFeed? feed(String roomId) => _feeds[roomId];

  /// 目前持有的所有房間 feed。跨房彙總（工作列徽章）用——通知中心跟隨
  /// 所有已加入的房間，所以這裡涵蓋的就是「我在的每個房」。
  Iterable<RoomFeed> get feeds => _feeds.values;

  /// 往上捲載入歷史（before_seq 反向翻頁）。
  Future<void> loadOlder(String roomId) async {
    final f = _feeds[roomId];
    final oldest = f?.oldestLoadedSeq;
    if (f == null || oldest == null || !f.hasMoreHistory) return;
    final page = await messagesApi.read(
      roomId, beforeSeq: oldest, limit: initialWindow);
    f.prependHistory(page.messages, hasMore: page.hasMore);
  }

  // ---------- 主迴圈 ----------

  Future<void> _runLoop() async {
    while (_desired) {
      _setStatus(const Connecting());
      WsConnection conn;
      try {
        conn = await connector(wsUriBuilder());
      } catch (e) {
        _log.info('WS 握手失敗：$e');
        if (!await _backoff()) return;
        continue;
      }
      _conn = conn;
      final closed = _connClosed = Completer<void>();
      final sub = conn.stream.listen(
        _onFrame,
        onDone: () {
          if (!closed.isCompleted) closed.complete();
        },
        onError: (Object e) {
          _log.info('WS 串流錯誤：$e');
          if (!closed.isCompleted) closed.complete();
        },
        cancelOnError: true,
      );

      var syncOk = false;
      try {
        _setStatus(const Syncing());
        await _syncAll();
        for (final roomId in _refCounts.keys) {
          conn.send(WsProtocol.subscribe(roomId, _feeds[roomId]?.cursor ?? 0,
              participantId: _participantIds[roomId]));
          _sentParticipantIds[roomId] = _participantIds[roomId] ?? '';
        }
        syncOk = true;
      } catch (e) {
        _log.warning('補訊失敗，重新連線：$e');
      }

      if (syncOk) {
        _setStatus(Connected());
        _attempt = 0; // 成功握手且補訊完成才重置，避免壞 server 的緊迫迴圈
        _startHeartbeat(conn);
        await closed.future;
      } else {
        await _closeConn();
      }

      _stopHeartbeat();
      await sub.cancel();
      final code = conn.closeCode;
      _conn = null;

      if (code == 4401) {
        // token 驗證失敗：重連只會用同一個錯 token 撞牆，直接離線
        _desired = false;
        _setStatus(const Disconnected(reason: 'token'));
        return;
      }
      if (!_desired) return;
      if (!await _backoff()) return;
    }
  }

  /// 退避等待。回傳 false 表示等待期間被要求停止。
  Future<bool> _backoff() async {
    final delay = _policy.delayFor(_attempt);
    _setStatus(Reconnecting(attempt: _attempt, delay: delay));
    _attempt++;
    final skip = _backoffSkip = Completer<void>();
    final timer = Timer(delay, () {
      if (!skip.isCompleted) skip.complete();
    });
    await skip.future;
    timer.cancel();
    _backoffSkip = null;
    return _desired;
  }

  Future<void> _closeConn() async {
    // 新連線的 server 端對我們一無所知，舊的「已送出」記錄會讓
    // _syncSubscription 誤以為不必再送
    _forgetSentSubscriptions();
    final conn = _conn;
    _conn = null;
    if (conn != null) {
      await conn.close();
      final closed = _connClosed;
      if (closed != null && !closed.isCompleted) closed.complete();
    }
  }

  // ---------- 補訊 ----------

  Future<void> _syncAll() async {
    for (final roomId in List.of(_refCounts.keys)) {
      await _syncRoom(roomId);
    }
  }

  Future<void> _attachRoom(String roomId) async {
    await _syncRoom(roomId);
    _conn?.send(WsProtocol.subscribe(roomId, _feeds[roomId]?.cursor ?? 0,
        participantId: _participantIds[roomId]));
    _sentParticipantIds[roomId] = _participantIds[roomId] ?? '';
  }

  Future<void> _syncRoom(String roomId) async {
    final f = _feeds[roomId];
    if (f == null) return;
    if (f.isEmpty) {
      await _loadLatestWindow(f);
      return;
    }
    // 斷線期間的增量補訊：after_seq 從 cursor 開始，直到追平。
    // ⚠️ 之後 subscribe 的 after_seq 必須取「補完後重新讀的 cursor」，
    // 不是補訊前快取的變數（§4.4 的競態論證靠這一行成立）。
    var loops = 0;
    while (true) {
      final page = await messagesApi.read(
        f.roomId, afterSeq: f.cursor, limit: catchUpBatch,
        participantId: _participantIds[f.roomId]);
      f.upsertAll(page.messages);
      if (!page.hasMore || page.messages.isEmpty) break;
      loops++;
      if (loops >= catchUpMaxLoops) {
        // 保險絲：放棄補訊，改為從最新開始重新載入
        _log.warning('房間 $roomId 補訊超過 $catchUpMaxLoops 圈，重置為最新視窗');
        f.reset();
        await _loadLatestWindow(f);
        break;
      }
    }
  }

  Future<void> _loadLatestWindow(RoomFeed f) async {
    final page = await messagesApi.read(
      f.roomId, beforeSeq: kSeqInfinity, limit: initialWindow,
      participantId: _participantIds[f.roomId]);
    f.upsertAll(page.messages);
    f.setHasMoreHistory(page.hasMore);
  }

  // ---------- 心跳（半開連線偵測，§4.3） ----------

  void _startHeartbeat(WsConnection conn) {
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      conn.send(WsProtocol.ping());
      _pongDeadline?.cancel();
      _pongDeadline = Timer(pongTimeout, () {
        _log.info('pong 逾時，判定連線已死');
        unawaited(_closeConn());
      });
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _pongDeadline?.cancel();
    _pongDeadline = null;
  }

  // ---------- 事件 ----------

  void _onFrame(dynamic raw) {
    if (raw is! String) return;
    final event = WsProtocol.decode(raw);
    switch (event) {
      case WsMessagesEvent(:final roomId, :final roomStatus, :final messages):
        final f = _feeds[roomId];
        if (f == null) return;
        f.upsertAll(messages);
        f.setRoomStatus(roomStatus);
      case WsQuestionsEvent(:final roomId, :final questions):
        _feeds[roomId]?.setQuestions(questions);
      case WsPongEvent():
        _pongDeadline?.cancel();
        _pongDeadline = null;
      case WsUnknownEvent(:final type):
        _log.fine('忽略未知 WS 事件：$type');
    }
  }

  void _setStatus(RealtimeStatus status) {
    _status = status;
    if (!_statusCtrl.isClosed) _statusCtrl.add(status);
  }

  Future<void> dispose() async {
    await stop();
    for (final t in _retireTimers.values) {
      t.cancel();
    }
    for (final f in _feeds.values) {
      f.dispose();
    }
    _feeds.clear();
    _participantIds.clear();
    _sentParticipantIds.clear();
    await _statusCtrl.close();
  }
}
