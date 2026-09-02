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
