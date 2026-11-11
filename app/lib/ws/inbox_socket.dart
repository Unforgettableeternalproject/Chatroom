import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';

import 'reconnect_policy.dart';
import 'ws_client.dart';

final _log = Logger('inbox');

/// `/ws/inbox` 推來的一則事件：未讀數與最新一則通知的 id。
///
/// [latestId] 是最新一則通知的整數 id，沒有通知時為 null。
class InboxEvent {
  const InboxEvent({required this.unreadCount, this.latestId});

  final int unreadCount;
  final int? latestId;

  static InboxEvent? decode(String raw) {
    try {
      final data = jsonDecode(raw);
      if (data is! Map<String, dynamic> || data['type'] != 'inbox') return null;
      final unread = data['unread_count'];
      final latest = data['latest_id'];
      return InboxEvent(
        unreadCount: unread is int ? unread : 0,
        latestId: latest is int ? latest : int.tryParse('${latest ?? ''}'),
      );
    } catch (_) {
      return null;
    }
  }
}

/// 通知中心的 WS 連線。認證與 `/ws` 相同（token／host_view 走 query）。
///
/// 只負責「喚醒」：事件不帶通知內容，內容由 REST 拉。斷線用同一套指數退避
/// 重連；4401（token 被拒）不重試。
class InboxSocket {
  InboxSocket({
    required this.uriBuilder,
    this.connector = defaultWsConnector,
    ReconnectPolicy? policy,
  }) : _policy = policy ?? ReconnectPolicy();

  final Uri Function() uriBuilder;
  final WsConnector connector;
  final ReconnectPolicy _policy;

  final _events = StreamController<InboxEvent>.broadcast();
  final _connected = StreamController<void>.broadcast();
  WsConnection? _conn;
  bool _desired = false;
  int _attempt = 0;
  Completer<void>? _skip;

  Stream<InboxEvent> get events => _events.stream;

  /// 每次（重新）連上就發一次——斷線期間的通知要靠呼叫端補拉。
  Stream<void> get connected => _connected.stream;

  void start() {
    if (_desired) return;
    _desired = true;
    unawaited(_run());
  }

  Future<void> _run() async {
    while (_desired) {
      WsConnection conn;
      try {
        conn = await connector(uriBuilder());
      } catch (e) {
        _log.info('inbox 握手失敗：$e');
        if (!await _backoff()) return;
        continue;
      }
      if (!_desired) {
        // 握手期間被 dispose 了
        unawaited(conn.close());
        return;
      }
      _conn = conn;
      _attempt = 0;
      if (!_connected.isClosed) _connected.add(null);
      final closed = Completer<void>();
      final sub = conn.stream.listen(
        (frame) {
          if (frame is! String) return;
          final e = InboxEvent.decode(frame);
          if (e != null && !_events.isClosed) _events.add(e);
        },
        onDone: () {
          if (!closed.isCompleted) closed.complete();
        },
        onError: (Object e) {
          _log.info('inbox 串流錯誤：$e');
          if (!closed.isCompleted) closed.complete();
        },
        cancelOnError: true,
      );
      // 連上後 server 先推一次現況；之後每 25 秒 ping 一次保活（回 pong，
      // 不是 inbox 事件，decode 會略過）
      final ping = Timer.periodic(const Duration(seconds: 25), (_) {
        try {
          conn.send(jsonEncode({'type': 'ping'}));
        } catch (_) {}
      });
      await closed.future;
      ping.cancel();
      await sub.cancel();
      final code = conn.closeCode;
      _conn = null;
      // 4401＝token 錯；4400＝缺 session_key。重連只會撞同一面牆
      if (code == 4401 || code == 4400) {
        _desired = false;
        return;
      }
      if (!_desired) return;
      if (!await _backoff()) return;
    }
  }

  Future<bool> _backoff() async {
    final delay = _policy.delayFor(_attempt);
    _attempt++;
    final skip = _skip = Completer<void>();
    final timer = Timer(delay, () {
      if (!skip.isCompleted) skip.complete();
    });
    await skip.future;
    timer.cancel();
    _skip = null;
    return _desired;
  }

  Future<void> dispose() async {
    _desired = false;
    final skip = _skip;
    if (skip != null && !skip.isCompleted) skip.complete();
    final conn = _conn;
    _conn = null;
    try {
      await conn?.close();
    } catch (_) {}
    await _events.close();
    await _connected.close();
  }
}
