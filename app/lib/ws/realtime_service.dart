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
    _backoffSkip?.complete();
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

  RoomFeed subscribe(String roomId) {
    _retireTimers.remove(roomId)?.cancel();
    _refCounts[roomId] = (_refCounts[roomId] ?? 0) + 1;
    final feed = _feeds.putIfAbsent(roomId, () => RoomFeed(roomId));
    if (_refCounts[roomId] == 1 && _status is Connected) {
      // 已連線時的新訂閱：先載入再掛 WS（不阻塞呼叫端）
      unawaited(_attachRoom(roomId).catchError((Object e) {
        _log.warning('房間 $roomId 掛載失敗：$e');
      }));
    }
    return feed;
  }

  void unsubscribe(String roomId) {
    final count = (_refCounts[roomId] ?? 0) - 1;
    if (count > 0) {
      _refCounts[roomId] = count;
      return;
    }
    _refCounts.remove(roomId);
    _conn?.send(WsProtocol.unsubscribe(roomId));
    // 延遲移除 store：房間之間來回切換不必重新載入
    _retireTimers[roomId]?.cancel();
    _retireTimers[roomId] = Timer(feedRetention, () {
      _retireTimers.remove(roomId);
      _feeds.remove(roomId)?.dispose();
    });
  }

  RoomFeed? feed(String roomId) => _feeds[roomId];

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
          conn.send(WsProtocol.subscribe(roomId, _feeds[roomId]?.cursor ?? 0));
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
    _conn?.send(WsProtocol.subscribe(roomId, _feeds[roomId]?.cursor ?? 0));
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
        f.roomId, afterSeq: f.cursor, limit: catchUpBatch);
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
      f.roomId, beforeSeq: kSeqInfinity, limit: initialWindow);
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
    await _statusCtrl.close();
  }
}
