import 'dart:convert';
import 'dart:typed_data';

import 'package:chatroom_app/api/board_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 板的封存已移除（2026-11-12），只剩結局；已收尾的板可手動永久刪除。
class _Canned implements HttpClientAdapter {
  _Canned(this.body);

  final Map<String, dynamic> body;
  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancel) async {
    seen.add(options);
    return ResponseBody.fromString(jsonEncode(body), 200,
        headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
  }

  @override
  void close({bool force = false}) {}
}

BoardsApi _api(_Canned canned) => BoardsApi(
    Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = canned);

void main() {
  test('永久刪除打 DELETE /api/boards/{id} 並帶 session key', () async {
    final canned = _Canned({'ok': true, 'board_id': 'b1'});
    await _api(canned).delete('b1', sessionKey: 'k');
    expect(canned.seen.single.method, 'DELETE');
    expect(canned.seen.single.path, '/api/boards/b1');
    expect(canned.seen.single.headers['X-Session-Key'], 'k');
  });

  test('結局打 /outcome，空字串＝重新打開', () async {
    final canned = _Canned({'ok': true, 'outcome': 'completed', 'board_seq': 3});
    await _api(canned)
        .setOutcome('b1', sessionKey: 'k', outcome: 'completed');
    expect(canned.seen.single.path, '/api/boards/b1/outcome');
  });
}
