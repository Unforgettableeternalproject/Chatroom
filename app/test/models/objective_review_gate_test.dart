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

  /// 畫面把「未分類」那一層藏起來，但 **Hub 眼裡它仍是一份 Checklist**。
  /// 送審條件排除它的話，按鈕會亮而 Hub 拒絕——正是這次要修掉的形狀。
  group('藏起來的「未分類」照樣擋送審', () {
    test('未分類還開著就送不出去', () {
      final snap = _snap(
        objectives: [_o('o1')],
        checklists: [
          _c('c1', status: 'done'),
          _c(kUncategorisedTitle),
        ],
      );
      expect(snap.canReviewObjective('o1'), isFalse);
    });

    test('未分類收尾了才放行', () {
      final snap = _snap(
        objectives: [_o('o1')],
        checklists: [
          _c('c1', status: 'done'),
          _c(kUncategorisedTitle, status: 'done'),
        ],
      );
      expect(snap.canReviewObjective('o1'), isTrue);
    });

    test('認得出哪一格是未分類', () {
      expect(_c(kUncategorisedTitle).isUncategorised, isTrue);
      expect(_c('Hub 側').isUncategorised, isFalse);
    });
  });

  /// 🔴 收尾的容器不能再收新東西。
  ///
  /// 驗收當下自己撞出來的：一張卡被建在已經 `done` 的 Checklist 底下，而
  /// 送審閘驗的是 Checklist 的狀態、不是底下 Task 的狀態 ⇒ 週期照樣送得出
  /// 去、確認得了、完成得掉。**板上寫著全部做完，實際上有一件沒做，而且
  /// 沒有任何地方會報錯。**
  ///
  /// 這是 B4 的鏡像：那次是「母體數錯」，這次是「收尾之後母體還會變」。
  /// 閘沒寫錯，是**驗的那一刻與事實變動的那一刻之間有縫**。
  group('收尾的容器拒收新東西', () {
    test('open 的階段收卡', () {
      expect(_c('c1').acceptsNewTasks, isTrue);
    });

    test('done / cancelled 的階段不收——要加先重新開啟', () {
      expect(_c('c1', status: 'done').acceptsNewTasks, isFalse);
      expect(_c('c1', status: 'cancelled').acceptsNewTasks, isFalse);
    });

    test('active 的週期收階段', () {
      expect(_o('o1').acceptsNewChecklists, isTrue);
    });

    test('🔴 review 與 verified 也不收——不是「非 done 就收」', () {
      // 送審之後加進來的階段是 open 的，而閘只在送審那一刻驗過一次：
      // 週期會一路走到 done，底下卻掛著一段從沒做完的東西。同一個 bug，
      // 只是換到上面一層
      expect(_o('o1', status: 'review').acceptsNewChecklists, isFalse);
      expect(_o('o1', status: 'verified').acceptsNewChecklists, isFalse);
      expect(_o('o1', status: 'done').acceptsNewChecklists, isFalse);
      expect(_o('o1', status: 'cancelled').acceptsNewChecklists, isFalse);
    });
  });

  test('週期不在快取裡：不亮，不是崩潰', () {
    expect(_snap().canReviewObjective('nope'), isFalse);
  });
}
