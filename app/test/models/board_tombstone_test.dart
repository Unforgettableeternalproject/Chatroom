import 'package:chatroom_app/models/board.dart';
import 'package:flutter_test/flutter_test.dart';

/// 板被刪掉之後，房間怎麼看它（029e24f6，艾斯維爾 09/07 裁定第 3 點）。
///
/// Hub 回的 `previous_board` 是**事實**：進行中的房也拿得到它。要畫成
/// 「沒綁板＋可重綁」還是「原先的任務板已刪除」由房的 status 決定——
/// 判斷放兩邊的話，同一份事實會有兩個真相來源。
///
/// 🔴 **「從沒有過板」與「原先那塊被刪了」在畫面上長得一模一樣**，而它們
/// 對讀的人意義完全不同：後者是「你看到的空白有原因」。封存房尤其——
/// 那間房裡的人做過的事去了哪裡，是他回頭翻它的唯一理由。
BoardSnapshot _snap({Map<String, dynamic>? previous, String boardId = ''}) =>
    const BoardSnapshot().merge(BoardDelta.fromJson({
      'board_seq': 1,
      'full': true,
      'board_id': boardId,
      'previous_board': ?previous,
    }));

void main() {
  group('入口該畫哪一種', () {
    test('載入中不做判斷——空快照與真的沒板長得一樣', () {
      expect(
          boardEntryKind(
              loaded: false,
              boardId: '',
              hasObjectives: false,
              archived: false,
              hadDeletedBoard: false),
          BoardEntryKind.board,
          reason: '載入中要維持原樣，不然每次進房都會閃一下「掛接任務板」');
    });

    test('有板就是有板', () {
      expect(
          boardEntryKind(
              loaded: true,
              boardId: 'b1',
              hasObjectives: false,
              archived: true,
              hadDeletedBoard: true),
          BoardEntryKind.board,
          reason: '綁著板的時候不該畫墓碑，哪怕以前刪過一塊');
    });

    test('進行中的房沒板 → 可以掛一塊（即使原先那塊被刪了）', () {
      // 墓碑那句話留給**沒有下一步**的那一種。這裡有下一步，畫面該講的
      // 是下一步，不是追悼
      expect(
          boardEntryKind(
              loaded: true,
              boardId: '',
              hasObjectives: false,
              archived: false,
              hadDeletedBoard: true),
          BoardEntryKind.attachable);
    });

    test('🔴 封存房 + 原先那塊被刪了 → 墓碑', () {
      expect(
          boardEntryKind(
              loaded: true,
              boardId: '',
              hasObjectives: false,
              archived: true,
              hadDeletedBoard: true),
          BoardEntryKind.deleted);
    });

    test('封存房 + 從沒有過板 → 只說沒有，不要編一段歷史', () {
      expect(
          boardEntryKind(
              loaded: true,
              boardId: '',
              hasObjectives: false,
              archived: true,
              hadDeletedBoard: false),
          BoardEntryKind.none);
    });

    test('舊 Hub 不回 board_id 但有卡：那是有板', () {
      expect(
          boardEntryKind(
              loaded: true,
              boardId: '',
              hasObjectives: true,
              archived: false,
              hadDeletedBoard: false),
          BoardEntryKind.board);
    });
  });

  group('墓碑的解析與清除', () {
    test('沒有這個鍵時是 null——沒發生過這件事', () {
      expect(_snap().previousBoard, isNull);
    });

    test('有的話名字與時間都讀得到', () {
      final p = _snap(previous: {
        'name': '09/06 週期',
        'deleted_at': '2026-09-07T05:00:00+00:00',
      }).previousBoard;
      expect(p!.name, '09/06 週期');
      expect(p.deletedAt, '2026-09-07T05:00:00+00:00');
    });

    test('🔴 綁上新板之後墓碑要消失——這一個是直接覆寫，不是「沒送就保留」',
        () {
      // 與 `liveAttachedRoomCount` 相反，而理由正是它們的差別：墓碑必須
      // 能被清掉。保留舊值的話，房間掛上新板之後畫面仍會說原先那塊被刪了
      final tomb = _snap(previous: {'name': '舊板'});
      expect(tomb.previousBoard, isNotNull);
      final after = tomb.merge(BoardDelta.fromJson({
        'board_seq': 2,
        'board_id': 'b-new',
      }));
      expect(after.previousBoard, isNull);
    });
  });
}
