import 'dart:convert';
import 'dart:typed_data';

import 'package:chatroom_app/api/board_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 板的封存／解除封存（`947deba7`）。server 端點早就在（`app.py:6865`／
/// `:6893`），缺的一直只有 App 這側的入口。
///
/// 🔴 **封存與結局是兩件事**，這一點在畫面與 API 上都要維持：
///
///   - `status`（active／archived）＝**還能不能改**。可逆的收納
///   - `outcome`（''／completed／abandoned）＝**這件事後來怎麼了**
///
/// 封存一塊板時，掛接的房**照樣聊天**（Hub docstring §3.2）——房封存與板
/// 封存在畫面上必須長得不一樣，否則使用者分不出「這個對話結束了」與
/// 「這份工作收尾了」。
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
  test('封存打對端點，回新的 status', () async {
    final canned = _Canned({'ok': true, 'status': 'archived', 'board_seq': 9});
    final status = await _api(canned).archive('b1', sessionKey: 'k');
    expect(canned.seen.single.path, '/api/boards/b1/archive');
    expect(canned.seen.single.headers['X-Session-Key'], 'k');
    expect(status, 'archived');
  });

  test('解除封存是另一支端點，不是同一支帶參數', () async {
    // Hub 分成兩支（`/archive` 與 `/unarchive`），client 照它的形狀走——
    // 自己合成一支「toggle」的話，畫面上的狀態與送出的意圖會在競態時分歧：
    // 兩個人同時按，第二個人送出的其實是「切回去」
    final canned = _Canned({'ok': true, 'status': 'active', 'board_seq': 10});
    final status = await _api(canned).unarchive('b1', sessionKey: 'k');
    expect(canned.seen.single.path, '/api/boards/b1/unarchive');
    expect(status, 'active');
  });

  test('🔴 舊 Hub 不回 status 時退回推定值，不是空字串', () {
    // 空字串會讓 `isArchived` 這類判斷變成「兩邊都不是」，而那個狀態在
    // 畫面上沒有畫法
    expect(BoardsApi(Dio()).archivedStatusFallback(archive: true), 'archived');
    expect(BoardsApi(Dio()).archivedStatusFallback(archive: false), 'active');
  });
}
