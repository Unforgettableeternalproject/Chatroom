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

  // ── 宣告的前置條件（卡 27bee744 / 47f0ee5a）─────────────────────────
  //
  // 規則：**曾掛過房 && 目前掛接數為 0** 才宣告得了。判準只存在 server
  // 一份，UI 轉述它的結論（`outcome_eligible` + `outcome_block_reason`）。
  //
  // 🔴 UI 不重寫這條規則。兩份判準遲早漂移，而漂移的時候沒有任何一邊會
  // 報錯——畫面說可以、server 說不行，使用者只看得到一個沒有理由的失敗。
  group('宣告結局的前置條件', () {
    test('server 說不行就不畫入口，理由照它給的那組字串', () {
      final s = _summary({
        'outcome_eligible': false,
        'outcome_block_reason': 'still_attached',
      });
      expect(s.canDeclareOutcome, isFalse);
      expect(s.outcomeBlockReason, 'still_attached');
    });

    test('never_attached 與 still_attached 是兩個不同的擋法', () {
      expect(
        _summary({'outcome_eligible': false, 'outcome_block_reason': 'never_attached'})
            .outcomeBlockReason,
        'never_attached',
      );
      expect(
        _summary({'outcome_eligible': false, 'outcome_block_reason': 'still_attached'})
            .outcomeBlockReason,
        'still_attached',
      );
    });

    test('🔴 舊 Hub 不回這一欄時照舊給按，由 409 兜底', () {
      // `null` ≠ `false`。當成 false 的話 owner 連按都按不到，而畫面上
      // 看不出是「被擋」還是「這個功能不見了」——那是最糟的一種降級。
      final s = _summary({});
      expect(s.outcomeEligible, isNull, reason: '沒說就是沒說');
      expect(s.canDeclareOutcome, isTrue);
    });

    test('🔴 已經收尾的板一律給按——reopen 不受前置條件管', () {
      // 否則：收尾之後又掛回房的板會卡在 completed 拿不下來。
      final s = _summary({
        'outcome': 'completed',
        'outcome_eligible': false,
        'outcome_block_reason': 'still_attached',
      });
      expect(s.canDeclareOutcome, isTrue);
    });

    test('詳情快照同一套判準', () {
      final blocked = const BoardSnapshot().merge(BoardDelta.fromJson(const {
        'board_seq': 1,
        'outcome_eligible': false,
        'outcome_block_reason': 'never_attached',
      }));
      expect(blocked.canDeclareOutcome, isFalse);
      expect(blocked.outcomeBlockReason, 'never_attached');

      final ok = const BoardSnapshot().merge(BoardDelta.fromJson(
          const {'board_seq': 1, 'outcome_eligible': true}));
      expect(ok.canDeclareOutcome, isTrue);
    });

    test('🔴 掛接關係一變就要跟著變——`false` 是結論，不是「沒提到」', () {
      // 照 outcome 那條「null 才保留舊值」處理。若寫成「有值才覆寫」，
      // 解除掛接之後畫面會一直以為還被擋著。
      final blocked = const BoardSnapshot().merge(BoardDelta.fromJson(const {
        'board_seq': 1,
        'outcome_eligible': false,
        'outcome_block_reason': 'still_attached',
      }));
      final freed = blocked.merge(BoardDelta.fromJson(const {
        'board_seq': 2,
        'outcome_eligible': true,
        'outcome_block_reason': '',
      }));
      expect(freed.canDeclareOutcome, isTrue);
      expect(freed.outcomeBlockReason, isEmpty);
    });

    test('回應沒提到時保留手上那份（增量不重送）', () {
      final blocked = const BoardSnapshot().merge(BoardDelta.fromJson(const {
        'board_seq': 1,
        'outcome_eligible': false,
        'outcome_block_reason': 'still_attached',
      }));
      final next = blocked.merge(BoardDelta.fromJson(const {'board_seq': 2}));
      expect(next.canDeclareOutcome, isFalse);
      expect(next.outcomeBlockReason, 'still_attached');
    });
  });
}
