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
}
