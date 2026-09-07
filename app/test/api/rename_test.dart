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
/// - 空字串 422；錯誤照既有 code 契約
///
/// 🔴 **回應形狀原本是我猜的，猜錯了。** 我先寫 App 半邊時假設它回
/// `{"room": {...}}` / `{"board": {...}}`，而 Hub 落地後（`51b420c`）實際
/// 回的是扁平的 `{ok, id, name, changed}` / `{ok, board_id, board_seq,
/// name, changed}`。房那支原本會在 `res.data!['room']` 上當場炸。
///
/// **兩邊照同一份文字各自實作，對得起來才算數**——這組測試現在釘的是
/// 比對過的形狀，不是我以為的那個。
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
  test('房間改名：PATCH /api/rooms/{id}，帶身分，回生效後的名字', () async {
    final stub = _Stub({'ok': true, 'id': 'r1', 'name': '新名字', 'changed': true});
    final name = await RoomsApi(_dioWith(stub))
        .rename('r1', name: '新名字', sessionKey: 'k', participantId: 'p1');

    expect(stub.seen.single.method, 'PATCH');
    expect(stub.seen.single.path, '/api/rooms/r1');
    expect(stub.seen.single.data, {'name': '新名字'});
    // 兩個都帶：建立者可能還沒 join 自己的房（只有 session key），
    // 一般管理者則走 participant id——與封存／可見性同一套
    expect(stub.seen.single.headers['X-Session-Key'], 'k');
    expect(stub.seen.single.headers['X-Participant-Id'], 'p1');
    expect(name, '新名字');
  });

  test('板改名：PATCH /api/boards/{id}，帶 session key', () async {
    final stub = _Stub({
      'ok': true,
      'board_id': 'b1',
      'board_seq': 12,
      'name': '新板名',
      'changed': ['name'],
    });
    final name =
        await BoardsApi(_dioWith(stub)).rename('b1', sessionKey: 'k', name: '新板名');

    expect(stub.seen.single.method, 'PATCH');
    expect(stub.seen.single.path, '/api/boards/b1');
    expect(stub.seen.single.data, {'name': '新板名'});
    expect(stub.seen.single.headers['X-Session-Key'], 'k');
    expect(name, '新板名');
  });

  test('前後空白先修掉再送', () async {
    final stub = _Stub({'ok': true, 'id': 'r1', 'name': '新名字'});
    await RoomsApi(_dioWith(stub)).rename('r1', name: '  新名字  ');
    expect(stub.seen.single.data, {'name': '新名字'});
  });

  test('拿 Hub 說的那個名字，不是自己送出去的那份', () async {
    // 正規化（trim、長度截斷）發生在 Hub 那邊，兩者不保證相同。
    // 回自己送出去的值，畫面就會顯示一個伺服器上並不存在的名字
    final stub = _Stub({'ok': true, 'id': 'r1', 'name': '被截斷的名'});
    final name = await RoomsApi(_dioWith(stub)).rename('r1', name: '很長的名字');
    expect(name, '被截斷的名');
  });

  test('板沒有實際變更時 Hub 不回 name——那時退回送出的值', () async {
    // `changed: []` 的回應裡沒有 `name` 鍵。硬讀會拿到 null，
    // 而呼叫端要的是「現在叫什麼」，這時送出的那份就是答案
    final stub = _Stub({'ok': true, 'board_id': 'b1', 'changed': []});
    final name =
        await BoardsApi(_dioWith(stub)).rename('b1', sessionKey: 'k', name: '同名');
    expect(name, '同名');
  });
}
