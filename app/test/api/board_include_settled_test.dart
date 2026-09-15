import 'dart:convert';
import 'dart:typed_data';

import 'package:chatroom_app/api/board_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 🔴 卡 442f3813：**人類打開板，先前的週期全不見了**（艾斯維爾 09/07 實機）。
///
/// 成因不是 App 的 bug，是**兩個讀者共用一支端點**：Hub 從 `659e9ff0` 起把
/// 全量讀取的預設收窄成「只回進行中的週期」，那是為 **agent 讀板會爆量**修
/// 的（實測 274,701 字元讀不動）。App 走同一支、沒表態，於是跟著只拿到本
/// 週期——而畫面上沒有任何一句話說其他週期去哪了。
///
/// **UI 沒有讀取上限問題，該看全量。** 修法是 App 明確帶
/// `include_settled=true`，不是把 Hub 的預設改回去——agent 那側的收窄要留著。
///
/// ⚠️ **兩條軸都要帶**：只補房軸的話，從聊天室進去看得到歷史、從 BOARDS
/// 分頁進去看不到，而那種不一致比兩邊都缺更難查——它會被當成「板壞了」。
class _Rec implements HttpClientAdapter {
  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(
      RequestOptions options, Stream<Uint8List>? _, Future<void>? _) async {
    seen.add(options);
    return ResponseBody.fromString(
      jsonEncode({'board_seq': 1, 'full': true, 'board_id': 'b1'}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _dio(_Rec rec) =>
    Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = rec;

void main() {
  test('🔴 房軸讀板要帶 include_settled=true', () async {
    final rec = _Rec();
    await BoardApi(_dio(rec)).fetch('r1', participantId: 'p1');

    final q = rec.seen.single.queryParameters;
    expect(q['include_settled'], true);
    expect(q['after_board_seq'], 0, reason: '既有參數不可以被這次改動弄掉');
  });

  test('🔴 板軸（BOARDS 分頁）讀板也要帶——兩條軸不可以不一致', () async {
    final rec = _Rec();
    await BoardsApi(_dio(rec)).fetch('b1', sessionKey: 'k');

    final q = rec.seen.single.queryParameters;
    expect(q['include_settled'], true);
  });

  test('增量讀取照樣帶——水位不影響「我要看全部」這件事', () async {
    // 增量路徑 Hub 那側本來就不篩，但參數該帶還是要帶：兩條路徑帶不同的
    // 參數，日後只要有人改動其中一條的語意，差異就會從這裡漏進來
    final rec = _Rec();
    await BoardApi(_dio(rec)).fetch('r1', afterBoardSeq: 42, participantId: 'p1');

    final q = rec.seen.single.queryParameters;
    expect(q['include_settled'], true);
    expect(q['after_board_seq'], 42);
  });
}
