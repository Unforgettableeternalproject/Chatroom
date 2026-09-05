import 'dart:convert';
import 'dart:typed_data';

import 'package:chatroom_app/api/board_api.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 板的**結局**（N-2，server `c105e99` 一帶／Hub 卡 `6494641d`）。
///
/// `outcome` ∈ `''` / `completed` / `abandoned`，與 `status`
/// （`active` / `archived`）是**兩個正交的軸**：
///
/// | | active | archived |
/// |---|---|---|
/// | `''` | 進行中 | 封存了，但還沒有結局 |
/// | `completed` | 做完了，還開著 | 做完並收起來了 |
/// | `abandoned` | 放棄了，還開著 | 放棄並收起來了 |
///
/// 🔴 **兩個軸不可以合成一個徽章。** `archived` 說的是「還能不能編輯」
/// （可逆的收納），`outcome` 說的是「這件事的結局」——把封存畫成「完成」
/// 會把「收起來但沒做完」講成做完了，而那是最不該弄錯的一格。
///
/// 🔴 **`completed` 與 `abandoned` 也不可以合成「已收尾」。** 做完了與放棄
/// 了在清單上長一樣的話，那份清單就回答不了「這件事後來怎麼了」——而那正是
/// 人會回頭翻它的唯一理由。
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

BoardSummary _summary(Map<String, dynamic> json) => BoardSummary.fromJson({
      'id': 'b1',
      'name': '一塊板',
      ...json,
    });

void main() {
  group('清單列讀得到結局', () {
    test('completed / abandoned 各自讀得出來', () {
      expect(_summary({'outcome': 'completed'}).outcome, 'completed');
      expect(_summary({'outcome': 'abandoned'}).outcome, 'abandoned');
    });

    test('🔴 Hub 還沒補這一欄時當成「沒有結局」，不是崩潰也不是猜', () {
      // `_library_row` 一度沒有回 outcome（2026-09-05 UI 側發現）。那時
      // 正確的降級是「顯示為未收尾」——猜一個結局出來比少畫一個徽章糟得多
      final s = _summary(const {});
      expect(s.outcome, '');
      expect(s.isSettled, isFalse);
    });

    test('🔴 archived 與 outcome 是正交的兩個軸', () {
      final archivedButUnsettled =
          _summary({'status': 'archived', 'outcome': ''});
      expect(archivedButUnsettled.isArchived, isTrue);
      expect(archivedButUnsettled.isSettled, isFalse,
          reason: '收起來了不等於做完了——把封存畫成完成，'
              '會把「還沒做完就收起來」講成做完了');

      final doneButOpen = _summary({'status': 'active', 'outcome': 'completed'});
      expect(doneButOpen.isArchived, isFalse);
      expect(doneButOpen.isCompleted, isTrue,
          reason: '做完了也可以還開著——結局不強迫收納');
    });

    test('🔴 completed 與 abandoned 分得出來，不是都叫「已收尾」', () {
      // 合成一個的話，清單就回答不了「這件事後來怎麼了」，而那是人回頭
      // 翻它的唯一理由
      final done = _summary({'outcome': 'completed'});
      final dropped = _summary({'outcome': 'abandoned'});
      expect(done.isCompleted, isTrue);
      expect(done.isAbandoned, isFalse);
      expect(dropped.isAbandoned, isTrue);
      expect(dropped.isCompleted, isFalse);
      expect([done.isSettled, dropped.isSettled], everyElement(isTrue));
    });
  });

  group('清單請求帶得出 outcome 篩選', () {
    test('預設不帶——Hub 那邊的預設就是「只看未收尾」', () async {
      final canned = _Canned({'boards': const []});
      final api = BoardsApi(
          Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = canned);
      await api.list(sessionKey: 'k');
      expect(canned.seen.single.queryParameters.containsKey('outcome'), isFalse);
    });

    test('要看已收尾的就帶 any——不是自己在 client 端過濾', () async {
      // client 過濾的話，「已收尾」那一頁永遠是空的：Hub 預設就沒把它們
      // 送過來，篩一份沒有它們的清單篩不出它們
      final canned = _Canned({'boards': const []});
      final api = BoardsApi(
          Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = canned);
      await api.list(sessionKey: 'k', outcome: 'any');
      expect(canned.seen.single.queryParameters['outcome'], 'any');
    });
  });

  group('快照合併：`null` 與 `\'\'` 是兩件事', () {
    test('🔴 重新打開（送 `\'\'`）要真的清掉，不能當成「沒送」而保留舊值', () {
      // 這是 outcome 與 name／status 不同的地方：那些欄位的空字串代表
      // 「這次沒重送」，而這裡的空字串是一個**合法的值**。照那條規則處理
      // 的話，把一塊板重新打開之後畫面會一直以為它還是完成的
      final settled = const BoardSnapshot()
          .merge(BoardDelta.fromJson(const {
        'board_seq': 1,
        'outcome': 'completed',
      }));
      expect(settled.isCompleted, isTrue);

      final reopened =
          settled.merge(BoardDelta.fromJson(const {'board_seq': 2, 'outcome': ''}));
      expect(reopened.outcome, '');
      expect(reopened.isSettled, isFalse, reason: '重新打開了就不該還是完成的');
    });

    test('回應沒提到 outcome 時保留手上那份（舊 Hub）', () {
      final settled = const BoardSnapshot().merge(
          BoardDelta.fromJson(const {'board_seq': 1, 'outcome': 'abandoned'}));
      final next = settled.merge(BoardDelta.fromJson(const {'board_seq': 2}));
      expect(next.isAbandoned, isTrue);
    });
  });

  group('宣告結局', () {
    test('completed / abandoned / 重新打開走同一支端點', () async {
      for (final v in ['completed', 'abandoned', '']) {
        final canned = _Canned({'ok': true, 'outcome': v, 'board_seq': 9});
        final api = BoardsApi(Dio(BaseOptions(baseUrl: 'http://test'))
          ..httpClientAdapter = canned);
        await api.setOutcome('b1', sessionKey: 'k', outcome: v);
        expect(canned.seen.single.path, '/api/boards/b1/outcome');
        expect(canned.seen.single.data['outcome'], v);
      }
    });
  });
}
