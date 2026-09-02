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
}
