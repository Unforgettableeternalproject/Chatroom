import 'dart:convert';
import 'dart:typed_data';

import 'package:chatroom_app/api/board_api.dart';
import 'package:chatroom_app/api/scratchpad_api.dart';
import 'package:chatroom_app/core/errors/api_exception.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/models/scratchpad.dart';
import 'package:chatroom_app/widgets/scratchpad_tag.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 想法板段落標籤的 UI 半邊（server 半邊 `28137c6`，契約 #411）。
///
/// 定案：**單選**、預設集合 `bug/feature/design/question`、每塊板可自訂額外
/// 標籤、刪除還有段落在用的自訂標籤回 409 帶 `block_ids`／`pad_ids`。
///
/// 🔴 **選單內容一律來自 `allowed_tags`（預設 ∪ 這塊板自訂的），UI 不得自己
/// 寫死一份預設集合。** 寫死的那份是第二個判準：板自訂的標籤它永遠不會知道，
/// 而兩份判準漂移的時候沒有任何一邊會報錯。
///
/// schema 寬、行為窄：欄位是陣列（之後要改多選不必動資料），UI 只給選一個。
class _Canned implements HttpClientAdapter {
  _Canned(this.body, {this.status = 200});

  final Map<String, dynamic> body;
  final int status;
  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancel) async {
    seen.add(options);
    return ResponseBody.fromString(jsonEncode(body), status,
        headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('段落帶著自己的標籤回來', () {
    test('讀得到 tags', () {
      final b = ScratchpadBlock.fromJson(const {
        'id': 'blk1',
        'content': '主持人模式按了沒反應',
        'tags': ['bug'],
      });
      expect(b.tags, ['bug']);
      expect(b.tag, 'bug', reason: '行為是單選，畫面要的是那一個');
    });

    test('沒有標籤的段落不是壞掉——舊資料本來就沒有', () {
      final b = ScratchpadBlock.fromJson(const {'id': 'blk1'});
      expect(b.tags, isEmpty);
      expect(b.tag, isNull, reason: 'null 才分得出「沒標」與「標了空字串」');
    });
  });

  group('選單內容來自板，不是寫死在 UI', () {
    test('BoardDelta 讀得到 allowed_tags', () {
      final d = BoardDelta.fromJson(const {
        'board_seq': 1,
        'allowed_tags': ['bug', 'feature', 'design', 'question', '權限'],
      });
      expect(d.allowedTags, contains('權限'), reason: '板自訂的那些只有 Hub 知道');
      expect(d.allowedTags, hasLength(5));
    });

    test('🔴 舊 Hub 不回這一欄時是空的，UI 不可以自己補一份預設集合', () {
      final d = BoardDelta.fromJson(const {'board_seq': 1});
      expect(d.allowedTags, isEmpty,
          reason: '補了就是第二個判準——板自訂的標籤它永遠不會知道，'
              '而兩份漂移時沒有一邊會報錯');
    });

    test('🔴 `[]` 與「沒有這個欄位」必須分得出來（Hub 13af69c）', () {
      // Hub 刻意在沒有自訂標籤時回 `[]` 而不是省略欄位：兩者要畫的東西不同
      // ——「這塊板沒有自訂標籤」時預設那四個要鎖起來，「舊 Hub 不會回」時
      // 什麼都鎖不了。用 `as List? ?? const []` 解析會把兩者壓成同一個值
      final saidNone = BoardDelta.fromJson(const {
        'board_seq': 1,
        'allowed_tags': ['bug', 'feature', 'design', 'question'],
        'custom_tags': <String>[],
      });
      expect(saidNone.customTags, isEmpty);
      expect(saidNone.customTags, isNotNull, reason: 'Hub 說了：一個都沒有');

      final didNotSay = BoardDelta.fromJson(const {'board_seq': 1});
      expect(didNotSay.customTags, isNull, reason: '舊 Hub 沒說，不是說了沒有');
    });

    test('🔴 哪些刪得掉＝allowed − custom，不是 UI 自己那份翻譯表', () {
      final d = BoardDelta.fromJson(const {
        'board_seq': 1,
        'allowed_tags': ['bug', 'feature', 'design', 'question', '權限'],
        'custom_tags': ['權限'],
      });
      expect(removableTags(allowed: d.allowedTags, custom: d.customTags),
          ['權限']);
      // 舊 Hub（沒說）時**全部都當可刪**，由 Hub 用 422 擋——鎖錯比多一次
      // 拒絕貴：把某塊板真的自訂的標籤鎖起來，那個標籤就永遠刪不掉了
      expect(
        removableTags(allowed: const ['bug', '權限'], custom: null),
        ['bug', '權限'],
      );
    });

    test('🔴 增量沒帶這一欄時保留手上那份，不是清空', () {
      // 跟著清空的話，選單會在第二次拉取之後整個消失——而畫面上那看起來
      // 像「這塊板沒有標籤功能」，不像掉了一份資料
      final full = const BoardSnapshot().merge(BoardDelta.fromJson(const {
        'board_seq': 1,
        'allowed_tags': ['bug', 'feature', '權限'],
      }));
      expect(full.allowedTags, hasLength(3));

      final next = full.merge(BoardDelta.fromJson(const {'board_seq': 2}));
      expect(next.allowedTags, hasLength(3), reason: '增量不重送中繼資料');
    });
  });

  group('寫入時把標籤一起送出', () {
    test('新增段落帶 tags', () async {
      final canned = _Canned({'ok': true, 'id': 'blk9'});
      final api = ScratchpadApi(
          Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = canned);
      await api.addBlock('b1', 'p1',
          sessionKey: 'k', content: '一則觀察', tags: const ['bug']);
      expect(canned.seen.single.data['tags'], ['bug']);
    });

    test('改段落也帶 tags——改內容與改標籤走同一支，rev 照舊必填', () async {
      final canned = _Canned({'ok': true, 'rev': 3});
      final api = ScratchpadApi(
          Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = canned);
      final rev = await api.writeBlock('b1', 'p1', 'blk1',
          sessionKey: 'k', content: '改過', rev: 2, tags: const ['feature']);
      expect(rev, 3);
      expect(canned.seen.single.data['tags'], ['feature']);
      expect(canned.seen.single.data['rev'], 2);
    });

    test('不指定 tags 時送空陣列——那是「沒有標籤」，不是「別動它」', () async {
      final canned = _Canned({'ok': true, 'id': 'blk9'});
      final api = ScratchpadApi(
          Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = canned);
      await api.addBlock('b1', 'p1', sessionKey: 'k', content: '一則觀察');
      expect(canned.seen.single.data['tags'], isEmpty);
    });
  });

  group('🔴 衝突重試不可以拿本地的舊標籤去蓋', () {
    // 審核用Codex 2026-09-05 用現行 API 重現：另一端先把標籤改成 `bug`
    // （rev 2）→ 舊內容寫入拿 409 → 依 UI 的「保留我的」retry 後 200，
    // 但最終 tags 變回 `[]`。**資料損失級。**
    //
    // 怎麼進來的：`_save` 帶 `tags: b.tags` 是對的（剛編輯完，手上就是最新
    // 的），那一行被複製到 `_resolveConflict`，而**衝突的定義就是「對方改過
    // 了」**——那條路徑上的 `b` 必然是舊的。同一行程式碼，前提相反。
    //
    // 兩邊各自的測試都不會紅：兩條路徑都「有把 tags 送出去」。要有人真的
    // 讓兩端交錯才看得見。
    test('409 帶了 fresh tags 就用它，不用本地那份', () {
      final tags = conflictTags(
        const {'content': '對方寫的', 'rev': 2, 'tags': ['bug']},
        fallback: const ['feature'],
      );
      expect(tags, ['bug'], reason: '對方剛改成 bug，重試不可以把它蓋回 feature');
    });

    test('409 明確說「現在沒有標籤」也要照做', () {
      // `[]` 是一個值（對方把標籤拿掉了），不是「沒講」
      expect(
        conflictTags(const {'tags': <String>[]}, fallback: const ['bug']),
        isEmpty,
      );
    });

    test('⚠️ 舊 Hub 不帶 tags 時只能退回本地那份——**那條路徑仍會覆蓋**', () {
      // 沒有更好的選擇：API 要的是整份新值，不送等於清空（更糟）。
      // 這是已知的降級，不是修好了——server 補上 409 帶 tags 之後這條
      // fallback 就不會再被走到
      expect(
        conflictTags(const {'content': '對方寫的', 'rev': 2},
            fallback: const ['feature']),
        ['feature'],
      );
    });
  });

  group('板自訂標籤', () {
    test('註冊新標籤，回傳新的選單內容', () async {
      final canned = _Canned({
        'ok': true,
        'tags': ['權限'],
        'allowed': ['bug', 'feature', 'design', 'question', '權限'],
        'added': ['權限'],
      });
      final api = BoardsApi(
          Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = canned);
      final r = await api.addTags('b1', sessionKey: 'k', tags: const ['權限']);
      expect(r.allowed, contains('權限'));
      expect(canned.seen.single.data['tags'], ['權限']);
    });

    test('🔴 刪不掉的時候要講出「幾則」，不是丟一句操作失敗', () {
      expect(
        tagRemovalError('tag_in_use', 'bug', blockCount: 2),
        allOf(contains('2 則'), contains('Bug')),
        reason: 'Hub 特地在 409 裡附上 block_ids 就是為了這句話——'
            '沒有它，人會反覆按同一顆刪除鈕',
      );
      expect(tagRemovalError('tag_is_default', 'feature'),
          allOf(contains('新功能'), contains('刪不掉')));
      // 沒認出來的 code 用 Hub 的原話，不要自己編一句更模糊的
      expect(tagRemovalError('whatever', 'x', fallback: 'Hub 說的話'),
          'Hub 說的話');
    });

    test('🔴 刪除還有段落在用的標籤 → 409，而且指得出是哪幾則', () async {
      // 擋下來而已是把問題換個地方放；擋下來**並指得出路**才是這個做法
      final canned = _Canned({
        'detail': {
          'code': 'tag_in_use',
          'message': '還有段落在用這個標籤',
          'block_ids': ['blk1', 'blk2'],
          'pad_ids': ['p1'],
        }
      }, status: 409);
      final api = BoardsApi(
          Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = canned);
      // ⚠️ 刻意**不新開一個例外型別**：`ConflictException` 已經把拒絕裡的
      // 其餘欄位原樣帶過來（`api_client.dart` 的既有決定——每加一個欄位就
      // 改一次型別的話，那些資訊多半就不會有人接）
      await expectLater(
        api.removeTag('b1', '權限', sessionKey: 'k'),
        throwsA(isA<ConflictException>()
            .having((e) => e.code, 'code', 'tag_in_use')
            .having((e) => e.detail['block_ids'], 'block_ids', ['blk1', 'blk2'])
            .having((e) => e.detail['pad_ids'], 'pad_ids', ['p1'])),
      );
    });
  });

  // ── 段落狀態（卡 287c903b / 6b1e6ecc）──────────────────────────────
  //
  // 「這則觀察後來怎麼了」：`null` / `implemented` / `abandoned`。
  // 與標籤是**正交的兩個軸**——標籤講性質，狀態講結局。
  group('段落狀態', () {
    ScratchpadBlock block(Map<String, dynamic> json) =>
        ScratchpadBlock.fromJson({'id': 'blk1', ...json});

    test('三態各自讀得出來', () {
      expect(block(const {'state': 'implemented'}).isImplemented, isTrue);
      expect(block(const {'state': 'abandoned'}).isAbandoned, isTrue);
      expect(block(const {}).state, isNull);
    });

    test('🔴 「還沒標」不是「已放棄」', () {
      // 三態最容易壓成兩態的地方。壓掉的話，畫面會對一則沒有人決定過的
      // 觀察宣告「放棄了」——而那正是想法板最不該說錯的一句話。
      final unset = block(const {});
      expect(unset.isAbandoned, isFalse);
      expect(unset.isSettled, isFalse, reason: '沒標不是一種結局，是還沒到那一步');
      expect(block(const {'state': 'abandoned'}).isSettled, isTrue);
    });

    test('空字串當成沒標——Hub 清除時送 null 或 \'\' 都收得住', () {
      expect(block(const {'state': ''}).state, isNull);
      expect(block(const {'state': null}).state, isNull);
    });

    test('狀態與標籤是正交的，同一則兩個軸都說得出來', () {
      final b = block(const {'tags': ['bug'], 'state': 'implemented'});
      expect(b.tag, 'bug');
      expect(b.isImplemented, isTrue);
    });

    group('誰標得動（`can_set_state`，決策 #95 放寬）', () {
      test('🔴 別人寫的段落：內容改不動，但狀態標得動', () {
        // 兩道門判的是兩件事——`_block_guard` 保護的是不可逆的原文，
        // 標狀態不動任何人的原文。共用一道門的話「決定放棄」只有原作者
        // 做得到，而那正好是最不需要標它的人。
        final b = block(const {'can_edit': false, 'can_set_state': true});
        expect(b.canEdit, isFalse);
        expect(b.canSetState, isTrue);
      });

      test('viewer／封存的板：兩個都不行', () {
        final b = block(const {'can_edit': false, 'can_set_state': false});
        expect(b.canSetState, isFalse);
      });

      test('🔴 舊 Hub 不回這一欄時退回 can_edit，不是預設放行', () {
        // 這一欄是新的。缺了它而預設 true 的話，UI 會在舊 Hub 上畫出一個
        // 按下去必然 403 的入口——而預設 false 又會讓連作者自己都標不動。
        // 退回 `can_edit` 是舊行為的等價物：那正是放寬之前的規則。
        expect(block(const {'can_edit': true}).canSetState, isTrue);
        expect(block(const {'can_edit': false}).canSetState, isFalse);
      });
    });

    // Hub 的語意（決策 09/06 裁定、`5674198` 實作）：
    //   沒送＝不動、送 ""＝清除、送值＝設定
    // 判準是 `model_fields_set`——**欄位在不在 body 裡**，不是它的值。
    // 所以 client 這邊「不動」與「清除」必須真的送出不同的東西。
    group('三態的寫入（containsKey 語意）', () {
      ScratchpadApi api(_Canned c) => ScratchpadApi(
          Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = c);

      test('🔴 改內容時**不送** state——那是「不動」', () async {
        // 送現值也能得到一樣的結果，但那要仰賴「改 state 一定會升 rev」
        // 這個前提。真正照契約用的話，這條路徑根本不碰 state 那一欄。
        final c = _Canned({'ok': true, 'rev': 3});
        await api(c).writeBlock('b1', 'p1', 'blk1',
            sessionKey: 'k', content: '改個錯字', rev: 2);
        expect(c.seen.single.data.containsKey('state'), isFalse,
            reason: '沒有要改狀態，就不該出現在那句 UPDATE 裡');
      });

      test('設定狀態送值', () async {
        final c = _Canned({'ok': true, 'rev': 3});
        await api(c).writeBlock('b1', 'p1', 'blk1',
            sessionKey: 'k', content: 'x', rev: 2, state: 'implemented');
        expect(c.seen.single.data['state'], 'implemented');
      });

      test('🔴 清除標記送空字串——不是把欄位省掉', () async {
        // `null` 在這支 API 上是一個**合法值**（清除），不是「沒給」。
        // 兩者用同一個表示法的話，清除這個動作就寫不出來了。
        final c = _Canned({'ok': true, 'rev': 3});
        await api(c).writeBlock('b1', 'p1', 'blk1',
            sessionKey: 'k', content: 'x', rev: 2, state: null);
        expect(c.seen.single.data.containsKey('state'), isTrue);
        expect(c.seen.single.data['state'], '');
      });
    });

    test('🔴 衝突重試不送 state——對方剛標的要留著', () async {
      // 「保留我的」保留的是使用者剛打的那段內容，不包括他根本沒碰的
      // 狀態欄；而衝突的定義就是「對方改過了」，本地那份必然舊。
      //
      // tags 得靠 conflictTags 特地把 409 帶回來的現值撈出來重送，state
      // 什麼都不必做——**需要一個 conflict helper 這件事本身，就是整份
      // 覆寫語意的成本**。這條測試釘的是那個差別。
      final c = _Canned({'ok': true, 'rev': 4});
      final api = ScratchpadApi(
          Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = c);
      // 「我看過了，還是要蓋掉」：用對方的 rev 重送自己的內容
      await api.writeBlock('b1', 'p1', 'blk1',
          sessionKey: 'k',
          content: '我的內容',
          rev: 3,
          tags: const ['bug']);
      expect(c.seen.single.data.containsKey('state'), isFalse);
      expect(c.seen.single.data['tags'], ['bug'],
          reason: 'tags 是整份覆寫，那一欄非送不可');
    });
  });
}
