import 'package:chatroom_app/state/composer_drafts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 草稿依房間分開（艾斯維爾 2026-09-02）。
///
/// 這支測的是**存放的地方**；「切房間時字不會跟過去」那半由 `app.dart` 的
/// `ValueKey(roomId)` 保證，見 `composer_draft_isolation_test.dart`。
/// 兩層缺一不可，所以分成兩支測——只修好其中一層時，會有一支是紅的。
void main() {
  late ProviderContainer c;
  ComposerDrafts notifier() => c.read(composerDraftsProvider.notifier);

  setUp(() => c = ProviderContainer());
  tearDown(() => c.dispose());

  test('兩個房間的草稿互不影響', () {
    notifier().set('a', '給 A 房的話');
    notifier().set('b', '給 B 房的話');
    expect(notifier().of('a'), '給 A 房的話');
    expect(notifier().of('b'), '給 B 房的話');
  });

  test('沒打過字的房間是空的，不是別人的草稿', () {
    notifier().set('a', '給 A 房的話');
    expect(notifier().of('never-visited'), '');
  });

  test('送出後只清掉那一房', () {
    notifier().set('a', 'aaa');
    notifier().set('b', 'bbb');
    notifier().clear('a');
    expect(notifier().of('a'), '');
    expect(notifier().of('b'), 'bbb', reason: '清掉的該是那一房，不是全部');
  });

  test('清空的房間不留空字串佔位', () {
    // 留著的話，state 會隨著逛過的房間無上限成長，而那些格子沒有用處
    notifier().set('a', 'aaa');
    notifier().set('a', '');
    expect(c.read(composerDraftsProvider).containsKey('a'), isFalse);
  });

  test('內容沒變就不換 state（不必要的重建）', () {
    notifier().set('a', 'aaa');
    final first = c.read(composerDraftsProvider);
    notifier().set('a', 'aaa');
    expect(identical(first, c.read(composerDraftsProvider)), isTrue);
  });
}
