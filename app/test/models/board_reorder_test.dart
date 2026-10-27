import 'package:chatroom_app/models/board.dart';
import 'package:flutter_test/flutter_test.dart';

/// 拖曳排序的位移計算。
///
/// Flutter 的 `onReorder` 給的 `newIndex` 是**移除之前**的插入位置，
/// 往後拖時要先減一。少了那一行只有往後拖會錯，往前拖是對的——
/// 隨手試一下很容易以為它好了。
void main() {
  const ids = ['a', 'b', 'c', 'd'];

  test('往後拖一格', () {
    expect(reorderedIds(ids, 0, 2), ['b', 'a', 'c', 'd']);
  });

  test('往前拖一格', () {
    expect(reorderedIds(ids, 2, 0), ['c', 'a', 'b', 'd']);
  });

  test('拖到最後', () {
    expect(reorderedIds(ids, 0, 4), ['b', 'c', 'd', 'a']);
  });

  test('拖到原位不動', () {
    expect(reorderedIds(ids, 1, 2), ids);
  });

  test('不改動傳進來的那份', () {
    final original = [...ids];
    reorderedIds(original, 0, 3);
    expect(original, ids);
  });

  _atSemantics();
  _partialOrder();
  _stageAndMoveTargets();
}

/// `onReorderItem` 那條路。索引語意與上面那組不同——**這裡的 newIndex
/// 已經是移除之後的最終位置**，不能再減一次。
void _atSemantics() {
  const ids = ['a', 'b', 'c', 'd'];

  test('往後拖：最終位置就是最終位置，不再減一', () {
    // onReorder 的 (0, 2) 與 onReorderItem 的 (0, 1) 是同一個動作。
    // 兩邊都減一次的話，往後拖會少跳一格——而往前拖仍然正確，
    // 所以隨手拖一下很容易以為它好了
    expect(reorderedIdsAt(ids, 0, 1), ['b', 'a', 'c', 'd']);
    expect(reorderedIdsAt(ids, 0, 3), ['b', 'c', 'd', 'a']);
  });

  test('往前拖：兩種語意在這個方向上一致', () {
    expect(reorderedIdsAt(ids, 2, 0), reorderedIds(ids, 2, 0));
  });
}

/// 只排得動一部分時，送出去的仍然是完整順序。
void _partialOrder() {
  test('拖不動的留在原位，不會被擠到最後', () {
    // A(active) B(done) C(active) D(active)，把 D 拖到最前面。
    // done 的 B 該留在第二格——它待在哪不是這次拖曳要回答的問題
    expect(
      spliceOrder(['a', 'b', 'c', 'd'], ['d', 'a', 'c']),
      ['d', 'b', 'a', 'c'],
    );
  });

  test('每個 id 恰好出現一次，長度不變', () {
    final out = spliceOrder(['a', 'b', 'c', 'd'], ['c', 'a', 'd']);
    expect(out, hasLength(4));
    expect(out.toSet(), {'a', 'b', 'c', 'd'});
  });

  test('全部都排得動時就是 movable 本身', () {
    expect(spliceOrder(['a', 'b'], ['b', 'a']), ['b', 'a']);
  });

  test('一個都排不動時原封不動', () {
    expect(spliceOrder(['a', 'b'], const []), ['a', 'b']);
  });

  _reorderPayload();
}
/// 送給 Hub 的那一份母體。
///
/// 🔴 Hub `510d6ed` 起要求「這一層現在的每一張卡，一張不多一張不少」，而
/// 它眼中被取消的週期**仍然是一個 sibling**（只排除 deleted）。顯示側用的
/// `sortedObjectives` 會濾掉 cancelled——送那一份就少了。
///
/// 在全集檢查落地之前，這個錯是**靜默**的：沒送到的那些保留舊 order_index，
/// 與新的 0、1、2 直接重疊，而 API 回 200。
void _reorderPayload() {
  BoardSnapshot snap(List<Map<String, dynamic>> objectives) =>
      const BoardSnapshot().merge(BoardDelta.fromJson({
        'board_seq': 1,
        'full': true,
        'objectives': objectives,
      }));

  test('母體含被取消的週期，顯示清單則不含', () {
    final s = snap([
      {'id': 'a', 'title': 'A', 'order_index': 0},
      {'id': 'b', 'title': 'B', 'order_index': 1, 'status': 'cancelled'},
      {'id': 'c', 'title': 'C', 'order_index': 2},
    ]);
    // 顯示側看不到 b——那是對的，取消的週期不該佔畫面
    expect(s.sortedObjectives.map((o) => o.id), ['a', 'c']);
    // 但送出去的順序必須含它，否則 Hub 的全集檢查會退回整批
    expect(s.allObjectiveIdsInOrder, ['a', 'b', 'c']);
  });

  test('照 order_index 排，而不是 map 的插入順序', () {
    final s = snap([
      {'id': 'x', 'title': 'X', 'order_index': 5},
      {'id': 'y', 'title': 'Y', 'order_index': 1},
    ]);
    expect(s.allObjectiveIdsInOrder, ['y', 'x']);
  });

  test('拖曳之後仍然是完整的一份，且每個 id 恰好一次', () {
    final s = snap([
      {'id': 'a', 'title': 'A', 'order_index': 0},
      {'id': 'b', 'title': 'B', 'order_index': 1, 'status': 'cancelled'},
      {'id': 'c', 'title': 'C', 'order_index': 2},
    ]);
    // 畫面上只排得動 a 與 c；把 c 拖到最前面
    final sent = spliceOrder(s.allObjectiveIdsInOrder, ['c', 'a']);
    expect(sent.toSet(), {'a', 'b', 'c'});
    expect(sent, hasLength(3));
    // 被取消的 b 留在原位，不被這次拖曳擠走
    expect(sent[1], 'b');
  });
}

/// 階段拖曳排序的母體，與拖放搬卡的落點判斷。
void _stageAndMoveTargets() {
  final s = const BoardSnapshot().merge(BoardDelta.fromJson({
    'board_seq': 1,
    'full': true,
    'board_id': 'b1',
    'objectives': [
      {'id': 'o1', 'title': 'O1', 'status': 'active'},
      {'id': 'o2', 'title': 'O2', 'status': 'done'},
      {'id': 'o3', 'title': 'O3', 'status': 'review'},
    ],
    'checklists': [
      {'id': 'u', 'objective_id': 'o1', 'title': '未分類', 'order_index': 0},
      {'id': 'a', 'objective_id': 'o1', 'title': 'A', 'order_index': 1},
      {
        'id': 'x',
        'objective_id': 'o1',
        'title': 'X',
        'order_index': 2,
        'status': 'cancelled'
      },
      {'id': 'b', 'objective_id': 'o1', 'title': 'B', 'order_index': 3},
      {
        'id': 'd',
        'objective_id': 'o1',
        'title': 'D',
        'order_index': 4,
        'status': 'done'
      },
      {'id': 'z', 'objective_id': 'o3', 'title': 'Z', 'order_index': 0},
    ],
    'tasks': [
      {'id': 't1', 'checklist_id': 'a', 'title': 'T1'},
      {'id': 't2', 'checklist_id': 'a', 'title': 'T2', 'status': 'done'},
    ],
  }));

  group('階段拖曳的完整母體', () {
    test('含被取消的、未分類的，且只含該週期', () {
      expect(s.allChecklistIdsInOrder('o1'), ['u', 'a', 'x', 'b', 'd']);
      // checklistsOf 濾掉 cancelled——送那份會 409 reorder_incomplete
      expect(s.checklistsOf('o1').map((c) => c.id), ['u', 'a', 'b', 'd']);
    });

    test('拖 B 到 A 前面：未分類與被取消的階段留在原位', () {
      final movable = ['a', 'b', 'd'];
      final sent = spliceOrder(
          s.allChecklistIdsInOrder('o1'), reorderedIdsAt(movable, 1, 0));
      expect(sent, ['u', 'b', 'x', 'a', 'd']);
      expect(sent.toSet(), s.allChecklistIdsInOrder('o1').toSet());
    });
  });

  group('搬卡落點', () {
    BoardChecklist cl(String id) => s.checklists[id]!;
    BoardTask tk(String id) => s.tasks[id]!;

    test('開著的、非原地的階段可放', () {
      expect(canMoveTaskInto(tk('t1'), cl('b')), isTrue);
      expect(canMoveTaskInto(tk('t1'), cl('u')), isTrue);
    });

    test('原階段、已收尾、已取消的階段不可放', () {
      expect(canMoveTaskInto(tk('t1'), cl('a')), isFalse);
      expect(canMoveTaskInto(tk('t1'), cl('d')), isFalse);
      expect(canMoveTaskInto(tk('t1'), cl('x')), isFalse);
    });

    test('已完成的卡搬不動', () {
      expect(tk('t2').isMovable, isFalse);
      expect(canMoveTaskInto(tk('t2'), cl('b')), isFalse);
    });

    test('落點週期只有進行中與送審中的', () {
      expect(s.moveTargetObjectives.map((o) => o.id), ['o1', 'o3']);
      expect(s.moveTargetChecklists('o1', 'a').map((c) => c.id), ['u', 'b']);
    });
  });
}
