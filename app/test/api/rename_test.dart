import 'dart:convert';
import 'dart:typed_data';

import 'package:chatroom_app/api/board_api.dart';
import 'package:chatroom_app/api/rooms_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// c271c7ff：板與房間可以改名。線上契約（決策 2026-09-07 定死）：
///
/// - `PATCH /api/rooms/{room_id}`，body `{"name": "..."}`，權限房管理者
/// - `PATCH /api/boards/{board_id}`，body `{"name": "..."}`，權限板 owner
/// - 成功回更新後的物件；空字串 422；錯誤照既有 code 契約
///
/// ⚠️ 這組測試釘的是**送出去的東西**（method／path／body／身分標頭），
/// 不是 Hub 的行為。兩邊照同一份契約各自實作，端點落地後對得起來就通——
/// 送錯 method 或漏帶身分是那時最貴的一種失敗：它會被讀成「權限不足」。
class _Stub implements HttpClientAdapter {
  _Stub(this.body);

  final Map<String, dynamic> body;
  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(
      RequestOptions options, Stream<Uint8List>? _, Future<void>? _) async {
    seen.add(options);
    return ResponseBody.fromString(jsonEncode(body), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(_Stub stub) =>
    Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = stub;

void main() {
  test('房間改名：PATCH /api/rooms/{id}，帶身分，回更新後的房', () async {
    final stub = _Stub({
      'ok': true,
      'room': {
        'id': 'r1',
        'name': '新名字',
        'topic': '',
        'status': 'active',
        'created_at': '2026-09-01T00:00:00+00:00',
      },
    });
    final room = await RoomsApi(_dioWith(stub))
        .rename('r1', name: '新名字', sessionKey: 'k', participantId: 'p1');

    expect(stub.seen.single.method, 'PATCH');
    expect(stub.seen.single.path, '/api/rooms/r1');
    expect(stub.seen.single.data, {'name': '新名字'});
    // 兩個都帶：建立者可能還沒 join 自己的房（只有 session key），
    // 一般管理者則走 participant id——與封存／可見性同一套
    expect(stub.seen.single.headers['X-Session-Key'], 'k');
    expect(stub.seen.single.headers['X-Participant-Id'], 'p1');
    expect(room.name, '新名字');
  });

  test('板改名：PATCH /api/boards/{id}，帶 session key', () async {
    final stub = _Stub({
      'ok': true,
      'board': {'id': 'b1', 'name': '新板名', 'status': 'active'},
    });
    final name =
        await BoardsApi(_dioWith(stub)).rename('b1', sessionKey: 'k', name: '新板名');

    expect(stub.seen.single.method, 'PATCH');
    expect(stub.seen.single.path, '/api/boards/b1');
    expect(stub.seen.single.data, {'name': '新板名'});
    expect(stub.seen.single.headers['X-Session-Key'], 'k');
    expect(name, '新板名');
  });

  test('前後空白先修掉再送——送出去的名字就是之後畫面上的那一個', () async {
    final stub = _Stub({
      'ok': true,
      'room': {
        'id': 'r1',
        'name': '新名字',
        'topic': '',
        'status': 'active',
        'created_at': '2026-09-01T00:00:00+00:00',
      },
    });
    await RoomsApi(_dioWith(stub)).rename('r1', name: '  新名字  ');
    expect(stub.seen.single.data, {'name': '新名字'});
  });
}
