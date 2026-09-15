import 'dart:convert';
import 'dart:typed_data';

import 'package:chatroom_app/api/board_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// `GET /api/boards` 的兩個旗標（Hub `c1b3036`）。
///
/// 它們回答兩個**不同**的問題，合成一個就會壞：
///
///   - `you_are_host`：開關**要不要出現**（＝手上是不是主 token）
///   - `host_view`：這份清單**是不是真的用主持人視角撈的**
///
/// 🔴 `host_view` 是**唯一能確認開關生效**的訊號。Hub 的判定要兩個條件
/// （明示 `X-Host-View` 標頭 ∧ 主 token），任一沒滿足就靜靜降級成一般
/// 視角——而少掉的板本來就看不到，**畫面完全一樣**。少了這一欄，
/// 「開關壞了」與「別人根本沒有私人板」在畫面上是同一件事。
class _Canned implements HttpClientAdapter {
  _Canned(this.body);

  final Map<String, dynamic> body;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
          Future<void>? cancel) async =>
      ResponseBody.fromString(jsonEncode(body), 200,
          headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});

  @override
  void close({bool force = false}) {}
}

BoardsApi _api(Map<String, dynamic> body) => BoardsApi(
    Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = _Canned(body));

void main() {
  test('兩個旗標讀得到', () async {
    final r = await _api({
      'boards': const [],
      'you_are_host': true,
      'host_view': true,
    }).list(sessionKey: 'k');
    expect(r.youAreHost, isTrue);
    expect(r.hostView, isTrue);
  });

  test('🔴 兩個旗標是分開的——主 token 但開關沒開時，只有前者是真', () async {
    // 合成一個的話，開關會在**被打開之後**才出現，而使用者永遠找不到它
    final r = await _api({
      'boards': const [],
      'you_are_host': true,
      'host_view': false,
    }).list(sessionKey: 'k');
    expect(r.youAreHost, isTrue);
    expect(r.hostView, isFalse);
  });

  test('🔴 不是主持人時兩個都是 false——不可以從清單內容反推', () async {
    // 「清單裡有別人的板 ⇒ 我是主持人」那種推斷會在**別人把板設成公開**
    // 的時候誤判，而誤判的結果是畫出一個按下去什麼都不會發生的開關
    final r = await _api({
      'boards': [
        {'id': 'b1', 'name': '別人的公開板', 'my_role': ''},
      ],
    }).list(sessionKey: 'k');
    expect(r.youAreHost, isFalse);
    expect(r.hostView, isFalse);
    expect(r.boards, hasLength(1));
  });

  test('舊 Hub 不回這兩欄時當作沒有主持人身分，不是崩潰', () async {
    final r = await _api({'boards': const []}).list(sessionKey: 'k');
    expect(r.youAreHost, isFalse);
    expect(r.hostView, isFalse);
  });

  test('清單本身照舊解析——加旗標沒有動到板的那部分', () async {
    final r = await _api({
      'boards': [
        {'id': 'b1', 'name': '一塊板', 'my_role': 'owner', 'visibility': 'private'},
      ],
      'you_are_host': true,
      'host_view': true,
    }).list(sessionKey: 'k');
    expect(r.boards.single.name, '一塊板');
    expect(r.boards.single.isPrivate, isTrue);
    expect(r.boards.single.notMine, isFalse);
  });
}
