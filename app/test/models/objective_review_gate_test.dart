import 'package:chatroom_app/models/board.dart';
import 'package:flutter_test/flutter_test.dart';

/// 送審按鈕什麼時候該亮。
///
/// Hub 的閘（`app.py` 的 `checklists_incomplete`）驗的是 **Checklist**：
/// 所有清單都收尾了，且至少一份真的完成——全部取消不算完成，那是「這一段
/// 不做了」，與「這一段做完了」在驗收上是兩件事。
///
/// 畫面原本數的是還剩幾張 **Task**。兩邊數的不是同一種東西，於是把卡全部
/// 做完之後按鈕就亮了，按下去必然拿 409；而在補上錯誤呈現之前，那個 409
/// 連看都看不到。
///
/// 條件本人放在 [BoardSnapshot.canReviewObjective]，測試測的是它。判斷留在
/// widget 裡的話，這裡就只能複製一份來測，而複製品永遠會通過。
BoardObjective _o(String id, {String status = 'active'}) =>
    BoardObjective(id: id, roomId: 'r', title: id, boardSeq: 1, status: status);

BoardChecklist _c(String id, {String status = 'open'}) => BoardChecklist(
      id: id,
      roomId: 'r',
      objectiveId: 'o1',
      title: id,
      boardSeq: 1,
      status: status,
    );

BoardTask _t(String id, {String status = 'todo', String checklistId = 'c1'}) =>
    BoardTask(
      id: id,
      roomId: 'r',
      checklistId: checklistId,
      title: id,
      boardSeq: 1,
      status: status,
    );

BoardSnapshot _snap({
  List<BoardObjective> objectives = const [],
  List<BoardChecklist> checklists = const [],
  List<BoardTask> tasks = const [],
}) =>
    BoardSnapshot(
      objectives: {for (final o in objectives) o.id: o},
      checklists: {for (final c in checklists) c.id: c},
      tasks: {for (final t in tasks) t.id: t},
    );

void main() {
  test('🔴 卡全做完但階段還開著：不能送審', () {
    // 這正是「按鈕亮著、按下去必然 409」的那個組合
    final snap = _snap(
      objectives: [_o('o1')],
      checklists: [_c('c1')],
      tasks: [_t('t1', status: 'done')],
    );
    expect(snap.canReviewObjective('o1'), isFalse);
  });

  test('所有階段都收尾：可以送審', () {
    final snap = _snap(
      objectives: [_o('o1')],
      checklists: [_c('c1', status: 'done')],
      tasks: [_t('t1', status: 'done')],
    );
    expect(snap.canReviewObjective('o1'), isTrue);
  });

  test('有一個階段還開著就不行，哪怕其他都收了', () {
    final snap = _snap(
      objectives: [_o('o1')],
      checklists: [_c('c1', status: 'done'), _c('c2')],
    );
    expect(snap.canReviewObjective('o1'), isFalse);
  });

  test('🔴 全部階段都被取消：不算做完，不能送審', () {
    // Hub 那句「至少一份真的完成」就是擋這個——一個全部放棄的週期送去驗收，
    // 驗的人沒有東西可以看
    final snap = _snap(
      objectives: [_o('o1')],
      checklists: [_c('c1', status: 'cancelled'), _c('c2', status: 'cancelled')],
    );
    expect(snap.canReviewObjective('o1'), isFalse);
  });

  test('取消的階段不擋路——只要還有一份是完成的', () {
    final snap = _snap(
      objectives: [_o('o1')],
      checklists: [_c('c1', status: 'done'), _c('c2', status: 'cancelled')],
    );
    expect(snap.canReviewObjective('o1'), isTrue);
  });

  test('一個階段都沒有的空週期：不能送審', () {
    expect(_snap(objectives: [_o('o1')]).canReviewObjective('o1'), isFalse);
  });

  group('只有進行中的週期送得出去', () {
    for (final status in ['review', 'verified', 'done', 'cancelled']) {
      test('$status 不能再送審一次', () {
        final snap = _snap(
          objectives: [_o('o1', status: status)],
          checklists: [_c('c1', status: 'done')],
        );
        expect(snap.canReviewObjective('o1'), isFalse);
      });
    }
  });

  test('週期不在快取裡：不亮，不是崩潰', () {
    expect(_snap().canReviewObjective('nope'), isFalse);
  });
}
