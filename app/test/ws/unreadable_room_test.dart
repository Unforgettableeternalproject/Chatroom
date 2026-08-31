import 'dart:async';

import 'package:chatroom_app/api/messages_api.dart';
import 'package:chatroom_app/core/errors/api_exception.dart';
import 'package:chatroom_app/models/message.dart';
import 'package:chatroom_app/ws/realtime_service.dart';
import 'package:chatroom_app/ws/reconnect_policy.dart';
import 'package:chatroom_app/ws/ws_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _ZeroPolicy extends ReconnectPolicy {
  @override
  Duration delayFor(int attempt) => Duration.zero;
}

class _FakeConnection implements WsConnection {
  final _incoming = StreamController<dynamic>();
  final sent = <String>[];

  @override
  int? closeCode;

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  void send(String data) => sent.add(data);

  @override
  Future<void> close() async {
    if (!_incoming.isClosed) await _incoming.close();
  }
}

/// 讀取一律拋指定的例外，並記下被呼叫幾次。
class _RejectingApi extends MessagesApi {
  _RejectingApi(this.error) : super(Dio());

  final Object error;
  int reads = 0;

  @override
  Future<MessagePage> read(
    String roomId, {
    int? afterSeq,
    int? beforeSeq,
    int? aroundSeq,
    int radius = 25,
    int limit = 100,
    bool pinnedOnly = false,
    String? participantId,
  }) async {
    reads++;
    throw error;
  }
}

void main() {
  late List<_FakeConnection> connections;

  RealtimeService build(MessagesApi api) => RealtimeService(
        messagesApi: api,
        wsUriBuilder: () => Uri.parse('ws://test/ws'),
        connector: (uri) async {
          final c = _FakeConnection();
          connections.add(c);
          return c;
        },
        policy: _ZeroPolicy(),
        heartbeatInterval: const Duration(minutes: 5),
      );

  setUp(() => connections = []);

  group('讀不到某個房不是連線壞了', () {
    test('補訊 401 不會觸發重連風暴', () async {
      // 實際發生過：主持人用主持人模式封了一個自己沒份的房，再把模式關掉。
      // WS 連上 → 補訊 401 → 被當成「補訊失敗，重新連線」→ 關掉重連 →
      // 再 401，每秒數次打向 Hub，畫面上只顯示「重連中」。
      final api = _RejectingApi(const ParticipantHeaderMissingException());
      final service = build(api);
      addTearDown(service.dispose);
      service.subscribe('r1');
      service.start();
      await Future<void>.delayed(const Duration(milliseconds: 120));

      // 一條連線就夠。重連風暴的形狀就是這個數字失控
      expect(connections.length, 1,
          reason: '401 重連一百次也不會變成 200，不該重連');
      expect(service.status, isA<Connected>(),
          reason: '連線本身是好的，壞的是那個房讀不到');
    });

    test('403 身分失效同理', () async {
      final api = _RejectingApi(const ParticipantInvalidException());
      final service = build(api);
      addTearDown(service.dispose);
      service.subscribe('r1');
      service.start();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(connections.length, 1);
    });

    test('網路層錯誤**仍然**要重連——那正是重連機制存在的理由，'
        '不可以被這次的修正一起關掉', () async {
      final api = _RejectingApi(const NetworkException());
      final service = build(api);
      addTearDown(service.dispose);
      service.subscribe('r1');
      service.start();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(connections.length, greaterThan(1),
          reason: '連不上是暫時的，重試有用');
    });

    test('一個房讀不到，不該讓其他房跟著斷', () async {
      // _syncAll 是跑所有訂閱中的房間的迴圈：其中一個拋例外就整條連線
      // 重來，等於一個沒權限的房把整個 App 的即時通道拖下水
      var calls = 0;
      final api = _PartialApi(() {
        calls++;
        // r1 讀不到、r2 正常
        if (calls.isOdd) throw const ParticipantHeaderMissingException();
      });
      final service = build(api);
      addTearDown(service.dispose);
      service.subscribe('r1');
      service.subscribe('r2');
      service.start();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(connections.length, 1);
      expect(service.status, isA<Connected>());
    });
  });
}

/// 由 callback 決定要不要拋。
class _PartialApi extends MessagesApi {
  _PartialApi(this.gate) : super(Dio());

  final void Function() gate;

  @override
  Future<MessagePage> read(
    String roomId, {
    int? afterSeq,
    int? beforeSeq,
    int? aroundSeq,
    int radius = 25,
    int limit = 100,
    bool pinnedOnly = false,
    String? participantId,
  }) async {
    gate();
    return const MessagePage(messages: <Message>[], hasMore: false);
  }
}
