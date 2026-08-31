import 'dart:convert';
import 'dart:typed_data';

import 'package:chatroom_app/api/rooms_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 回一份指定的 JSON，並記下請求。
class _Stub implements HttpClientAdapter {
  _Stub(this.body);

  final Map<String, dynamic> body;
  static const status = 200;
  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(
      RequestOptions options, Stream<Uint8List>? _, Future<void>? _) async {
    seen.add(options);
    return ResponseBody.fromString(jsonEncode(body), status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(_Stub stub) =>
    Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = stub;

void main() {
  group('封存的一個入口兩種結果', () {
    test('建立者按下去 → 房封了', () async {
      final stub = _Stub({'ok': true, 'archived': true});
      final r = await RoomsApi(_dioWith(stub)).archive('r1');
      expect(r.archived, isTrue);
      expect(r.request, isNull);
    });

    test('成員按下去 → 掛上一筆請求，房沒封', () async {
      final stub = _Stub({
        'ok': true,
        'archived': false,
        'request': {
          'id': 'ar1',
          'requester_id': 'p1',
          'requester_name': 'Alpha',
          'reason': '跑完了',
          'status': 'pending',
        },
      });
      final r = await RoomsApi(_dioWith(stub)).archive('r1');
      expect(r.archived, isFalse);
      expect(r.request!.id, 'ar1');
      expect(r.request!.requesterName, 'Alpha');
      expect(r.alreadyPending, isFalse);
    });

    test('第二個人提 → already_pending，訊息要講得不一樣', () async {
      final stub = _Stub({
        'ok': true,
        'archived': false,
        'already_pending': true,
        'request': {'id': 'ar1', 'status': 'pending'},
      });
      final r = await RoomsApi(_dioWith(stub)).archive('r1');
      expect(r.alreadyPending, isTrue);
    });

    test('舊版 Hub 不回 archived 時當成「已封存」——它的實際行為就是直接封，'
        '當成 false 會顯示一則假的「已送出請求」而房其實已經封了', () async {
      final stub = _Stub({'ok': true});
      final r = await RoomsApi(_dioWith(stub)).archive('r1');
      expect(r.archived, isTrue);
    });
  });

  group('房間詳情帶得出待處理的封存請求', () {
    test('有 pending 時解得出來', () async {
      final stub = _Stub({
        'room': {'id': 'r1', 'name': '房', 'status': 'active'},
        'participants': [],
        'you_are_admin': true,
        'archive_request': {
          'id': 'ar1',
          'requester_id': 'p1',
          'requester_name': 'Alpha',
          'reason': '',
          'status': 'pending',
        },
      });
      final d = await RoomsApi(_dioWith(stub)).detail('r1');
      expect(d.archiveRequest!.requesterId, 'p1');
    });

    test('沒有 pending 時是 null；舊版 Hub 沒這個欄位也是 null——'
        '兩種情況下 UI 行為必須一致', () async {
      final stub = _Stub({
        'room': {'id': 'r1', 'name': '房', 'status': 'active'},
        'participants': [],
      });
      final d = await RoomsApi(_dioWith(stub)).detail('r1');
      expect(d.archiveRequest, isNull);
    });
  });

  group('拍板與收回送得出身分', () {
    test('核准帶兩種身分——建立者可能還沒 join 自己的房', () async {
      final stub = _Stub({'ok': true});
      await RoomsApi(_dioWith(stub)).resolveArchiveRequest('ar1',
          approve: true, sessionKey: 'dev-key', participantId: 'p9');
      expect(stub.seen.single.headers['X-Session-Key'], 'dev-key');
      expect(stub.seen.single.headers['X-Participant-Id'], 'p9');
      expect(stub.seen.single.data['approve'], isTrue);
    });

    test('婉拒帶得出理由', () async {
      final stub = _Stub({'ok': true});
      await RoomsApi(_dioWith(stub)).resolveArchiveRequest('ar1',
          approve: false, reason: '還在跑測試', sessionKey: 'dev-key');
      expect(stub.seen.single.data['approve'], isFalse);
      expect(stub.seen.single.data['reason'], '還在跑測試');
    });

    test('收回只帶 participant——限本人，session key 在這裡沒有意義', () async {
      final stub = _Stub({'ok': true});
      await RoomsApi(_dioWith(stub))
          .cancelArchiveRequest('ar1', participantId: 'p1');
      expect(stub.seen.single.headers['X-Participant-Id'], 'p1');
      expect(stub.seen.single.method, 'DELETE');
    });
  });
}
