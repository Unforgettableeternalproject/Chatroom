import 'package:chatroom_app/models/scratchpad.dart';
import 'package:flutter_test/flutter_test.dart';

/// 想法板段落卡的三個壞法（@審核用Codex-2 2026-09-03 審 `72110d8` 抓到的）。
///
/// 三條都是**靜默**的：沒有例外、沒有紅字，只是存錯段落、或者剛打的字
/// 不見了。這裡測的是它們共同的那個核心——**畫面上的字什麼時候才可以丟掉**。
void main() {
  group('段落身分', () {
    test('block id 就是 key，內容一樣的兩段仍然是兩段', () {
      // ⚠️ 沒有 ValueKey(block.id) 的話，reload 或重排之後 Flutter 會按
      // **索引**沿用同一顆 State，而 controller 只在 initState 建一次
      // ⇒ 編輯框裝著前一段的舊文字，存下去覆蓋錯段落。
      //
      // 這條守的是「拿什麼當身分」：內容一樣不代表是同一段
      final a = ScratchpadBlock.fromJson({'id': 'b1', 'content': '一樣的字'});
      final b = ScratchpadBlock.fromJson({'id': 'b2', 'content': '一樣的字'});
      expect(a.id == b.id, isFalse);
      expect(a.content == b.content, isTrue);
    });

    test('每一段有自己的 rev，不共用板的 rev', () {
      // 拿板的結構 rev 去寫某一段，會在別人只是新增了一段的時候
      // 把你的編輯擋掉——而那兩件事根本沒有衝突
      final pad = Scratchpad.fromJson({
        'id': 'p1',
        'rev': 9,
        'blocks': [
          {'id': 'b1', 'rev': 2},
          {'id': 'b2', 'rev': 5},
        ],
      });
      expect(pad.rev, 9);
      expect(pad.blockOf('b1')!.rev, 2);
      expect(pad.blockOf('b2')!.rev, 5);
    });
  });

  group('降級與恢復的文案照 Hub 的事件名走', () {
    // 🔴 我原本寫的是 `watch_delivery_degraded`，而 Hub 寫的是
    // `delivery_degraded`（app.py:6839）；`delivery_restored` 我根本沒接。
    // 差一個字的結果是收件匣掉進 default 文案——**看得見，但講不清楚**。
    test('delivery_degraded 認得出來', () {
      final s = watchNoticeLabel('delivery_degraded', 'Board V2');
      expect(s, contains('Board V2'));
      expect(s, contains('不再有聊天室'));
      expect(s, isNot(contains('delivery_degraded')));
    });

    test('delivery_restored 也要有——只講壞消息的話他會一直回來看', () {
      final s = watchNoticeLabel('delivery_restored', 'Board V2');
      expect(s, contains('又有聊天室'));
      expect(s, isNot(contains('delivery_restored')));
    });

    test('這兩個的 item_title 是板名，不套卡片的句型', () {
      // Hub 寫的是 item_kind='board'。套成卡片句型會生出
      // 「「某某板」完成了」那種讀不通的句子
      expect(watchNoticeLabel('delivery_degraded', ''), contains('你追蹤的板'));
    });

    test('我沒接過的事件仍然說得出來', () {
      // 這條是上面兩條的保險：下次 Hub 再加一種，收件匣不會少一筆
      expect(watchNoticeLabel('something_new', 'A'), contains('something_new'));
    });
  });

  _resolveGate();
}
/// 註解的「處理掉」該不該出現，用的是**段落**的 can_edit，不是想法板的。
///
/// Hub 的 resolve 守門是「這一段的作者，或人類成員」——與 can_edit 同一條
/// （`app.py:6593`）。用 pad 層級判的話，agent 會在人類寫的段落上看到一顆
/// 「處理掉」，按下去必然 403（@審核用Codex-2 2026-09-03）。
void _resolveGate() {
  group('註解處理權', () {
    test('別人的段落上不給處理鈕，即使我在這塊板上可寫', () {
      expect(canResolveNote(padCanEdit: true, blockCanEdit: false), isFalse);
    });

    test('自己的段落才給', () {
      expect(canResolveNote(padCanEdit: true, blockCanEdit: true), isTrue);
    });

    test('整塊板唯讀時一律不給', () {
      expect(canResolveNote(padCanEdit: false, blockCanEdit: true), isFalse);
    });
  });

  _reorderGate();
}
/// 段落排得動嗎——**兩個條件都要**。
///
/// 🔴 Hub 只讓人類重排（`human_only`，實測 2026-09-03）：排序會改變別人那段
/// 話的上下文，它把那歸成與改寫同一類。agent 看到拖曳把手、拖完才拿 403 的
/// 話，順序在畫面上已經變了，它會以為成功。
void _reorderGate() {
  Scratchpad pad({
    required bool canEdit,
    required bool human,
    int blocks = 2,
  }) =>
      Scratchpad.fromJson({
        'id': 'p1',
        'can_edit': canEdit,
        'i_am_human': human,
        'blocks': [
          for (var i = 0; i < blocks; i++) {'id': 'b$i'},
        ],
      });

  group('段落重排的守門', () {
    test('人類且可寫才排得動', () {
      expect(pad(canEdit: true, human: true).canReorder, isTrue);
    });

    test('agent 排不動，即使它在這塊板上可寫', () {
      expect(pad(canEdit: true, human: false).canReorder, isFalse);
    });

    test('唯讀的人排不動', () {
      expect(pad(canEdit: false, human: true).canReorder, isFalse);
    });

    test('只有一段時不給拖——拖不動的把手比沒有把手更像壞了', () {
      expect(pad(canEdit: true, human: true, blocks: 1).canReorder, isFalse);
    });

    test('Hub 沒說我是不是人類時當作不是', () {
      // 反過來的話 agent 會拖完才拿 403，而那時順序在畫面上已經變了
      final p = Scratchpad.fromJson({
        'id': 'p1',
        'can_edit': true,
        'blocks': [
          {'id': 'b0'},
          {'id': 'b1'},
        ],
      });
      expect(p.iAmHuman, isFalse);
      expect(p.canReorder, isFalse);
    });
  });
}
