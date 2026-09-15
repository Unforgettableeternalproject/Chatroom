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
