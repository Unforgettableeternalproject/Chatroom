import 'dart:async';
import 'dart:convert';

import 'package:chatroom_app/api/messages_api.dart';
import 'package:chatroom_app/models/message.dart';
import 'package:chatroom_app/ws/realtime_service.dart';
import 'package:chatroom_app/ws/reconnect_policy.dart';
import 'package:chatroom_app/ws/ws_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------- fakes ----------

class _ZeroPolicy extends ReconnectPolicy {
  @override
  Duration delayFor(int attempt) => Duration.zero;
}

class _FakeConnection implements WsConnection {
  final _incoming = StreamController<dynamic>();
  final sent = <String>[];
  bool closed = false;

  @override
  int? closeCode;

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  void send(String data) => sent.add(data);

  @override
  Future<void> close() async {
    closed = true;
    if (!_incoming.isClosed) await _incoming.close();
  }

  /// 模擬 server 推播。
  void push(Map<String, dynamic> event) => _incoming.add(jsonEncode(event));

  /// 模擬連線中斷（server 端 / 網路層）。
  Future<void> drop({int? code}) async {
    closeCode = code;
    if (!_incoming.isClosed) await _incoming.close();
  }
}

class _FakeMessagesApi extends MessagesApi {
  _FakeMessagesApi() : super(Dio());

  /// 房內的完整訊息序列（模擬 server DB）。
  final List<Message> serverMessages = [];

  @override
  Future<MessagePage> read(
    String roomId, {
    int? afterSeq,
    int? beforeSeq,
    int limit = 100,
    bool pinnedOnly = false,
  }) async {
    List<Message> result;
    if (beforeSeq != null) {
      result = serverMessages.where((m) => m.seq < beforeSeq).toList()
        ..sort((a, b) => b.seq.compareTo(a.seq));
      final page = result.take(limit).toList().reversed.toList();
      return MessagePage(
          messages: page, hasMore: result.length > limit);
    }
    result = serverMessages
        .where((m) => m.seq > (afterSeq ?? 0))
        .toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));
    final page = result.take(limit).toList();
    return MessagePage(messages: page, hasMore: result.length > limit);
  }
}

Message _msg(int seq) => Message(
      id: 'm$seq',
      seq: seq,
      updateSeq: 0,
      kind: 'chat',
      content: '訊息 $seq',
      createdAt: '2026-08-28T00:00:00+00:00',
    );

Future<void> _waitFor(bool Function() condition,
    {Duration timeout = const Duration(seconds: 2)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待逾時');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late _FakeMessagesApi api;
  late List<_FakeConnection> connections;
  late RealtimeService service;

  RealtimeService build() => RealtimeService(
        messagesApi: api,
        wsUriBuilder: () => Uri.parse('ws://test/ws'),
        connector: (uri) async {
          final c = _FakeConnection();
          connections.add(c);
          return c;
        },
        policy: _ZeroPolicy(),
        heartbeatInterval: const Duration(minutes: 5), // 測試中不觸發
      );

  setUp(() {
    api = _FakeMessagesApi();
    connections = [];
    service = build();
  });

  tearDown(() async {
    await service.dispose();
  });

  test('連線 → 補訊 → subscribe 帶 cursor → Connected', () async {
    api.serverMessages.addAll([_msg(1), _msg(2), _msg(3)]);
    final feed = service.subscribe('r1');
    service.start();

    await _waitFor(() => service.status is Connected);
    expect(feed.messages.map((m) => m.seq), [1, 2, 3]);

    final sub = connections.single.sent
        .map((s) => jsonDecode(s) as Map<String, dynamic>)
        .firstWhere((m) => m['type'] == 'subscribe');
    expect(sub['room_id'], 'r1');
    // subscribe 的 after_seq 必須是「補完後」的 cursor（競態論證的關鍵行）
    expect(sub['after_seq'], 3);
  });

  test('WS 推播 upsert 進 feed；釘選快照覆寫既有訊息', () async {
    api.serverMessages.add(_msg(1));
    final feed = service.subscribe('r1');
    service.start();
    await _waitFor(() => service.status is Connected);

    connections.single.push({
      'type': 'messages',
      'room_id': 'r1',
      'room_status': 'active',
      'messages': [
        {
          'id': 'm1',
          'seq': 1,
          'update_seq': 2,
          'kind': 'chat',
          'content': '訊息 1',
          'mentions': <String>[],
          'pinned': true,
          'deleted': false,
          'created_at': '2026-08-28T00:00:00+00:00',
        },
      ],
    });
    await _waitFor(() => feed.bySeq(1)!.pinned);
    expect(feed.cursor, 2);
  });

  test('斷線 → 自動重連 → 以 cursor 補回斷線期間的訊息，無重複無遺漏', () async {
    api.serverMessages.addAll([_msg(1), _msg(2)]);
    final feed = service.subscribe('r1');
    service.start();
    await _waitFor(() => service.status is Connected);

    // 斷線期間 server 又多了兩則
    api.serverMessages.addAll([_msg(3), _msg(4)]);
    await connections.single.drop();

    await _waitFor(() => connections.length == 2);
    await _waitFor(() => service.status is Connected);
    expect(feed.messages.map((m) => m.seq), [1, 2, 3, 4]);
    expect(feed.length, 4, reason: '重複會被 seq upsert 吸收');

    final sub = connections[1].sent
        .map((s) => jsonDecode(s) as Map<String, dynamic>)
        .firstWhere((m) => m['type'] == 'subscribe');
    expect(sub['after_seq'], 4);
  });

  test('close code 4401 → 直接離線不重連（重連只會撞同一個錯 token）', () async {
    service.subscribe('r1');
    service.start();
    await _waitFor(() => service.status is Connected);

    await connections.single.drop(code: 4401);
    await _waitFor(() => service.status is Disconnected);
    expect((service.status as Disconnected).tokenRejected, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(connections.length, 1, reason: '不得再嘗試連線');
  });

  test('refCount 歸零送 unsubscribe；30 秒保留期內重訂閱沿用同一 store', () async {
    final feed = service.subscribe('r1');
    service.start();
    await _waitFor(() => service.status is Connected);

    service.unsubscribe('r1');
    final unsub = connections.single.sent
        .map((s) => jsonDecode(s) as Map<String, dynamic>)
        .where((m) => m['type'] == 'unsubscribe');
    expect(unsub, isNotEmpty);

    final again = service.subscribe('r1');
    expect(identical(feed, again), isTrue, reason: '保留期內不應重建 store');
  });

  test('退避期間 retryNow 緊接 stop 不可 double-complete（Codex blocker）', () async {
    await service.dispose();
    // 連不上 + 長退避：讓服務停在 Reconnecting 等待 skip completer
    service = RealtimeService(
      messagesApi: api,
      wsUriBuilder: () => Uri.parse('ws://test/ws'),
      connector: (uri) async => throw Exception('握手失敗'),
      policy: _FixedPolicy(const Duration(minutes: 5)),
    );
    service.start();
    await _waitFor(() => service.status is Reconnecting);

    // retryNow 已 complete skip、_backoff 尚未醒來清 null——此刻 stop 進場
    service.retryNow();
    await service.stop(); // 修復前這裡丟 StateError: Future already completed

    expect(service.status, isA<Disconnected>());
  });
}

class _FixedPolicy extends ReconnectPolicy {
  _FixedPolicy(this.delay);
  final Duration delay;

  @override
  Duration delayFor(int attempt) => delay;
}
