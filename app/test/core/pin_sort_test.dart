import 'package:chatroom_app/core/util/pin_sort.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  bool pinned(String s, Set<String> ids) => ids.contains(s);

  test('關注項置頂，其餘維持原順序', () {
    final out = pinnedFirst(['a', 'b', 'c', 'd'], (s) => pinned(s, {'c'}));
    expect(out, ['c', 'a', 'b', 'd']);
  });

  test('多個關注項之間維持原本的排序（穩定）', () {
    final out =
        pinnedFirst(['a', 'b', 'c', 'd', 'e'], (s) => pinned(s, {'e', 'b', 'd'}));
    expect(out, ['b', 'd', 'e', 'a', 'c']);
  });

  test('先過濾再置頂：被過濾掉的關注項不會冒出來', () {
    final all = ['alpha', 'beta', 'gamma', 'alps'];
    final filtered = all.where((s) => s.startsWith('al')).toList();
    final out = pinnedFirst(filtered, (s) => pinned(s, {'alps', 'gamma'}));
    expect(out, ['alps', 'alpha']);
  });

  test('沒有關注項或空清單時原樣回傳，且不改動輸入', () {
    final input = ['a', 'b'];
    expect(pinnedFirst(input, (_) => false), ['a', 'b']);
    expect(pinnedFirst(<String>[], (_) => true), isEmpty);
    pinnedFirst(input, (s) => s == 'b');
    expect(input, ['a', 'b']);
  });
}
