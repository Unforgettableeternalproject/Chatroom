import 'package:chatroom_app/state/composer_history.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 輸入歷史的持有者。widget 測試驗的是「按鍵怎麼走」，這裡驗的是
/// 「記了什麼」——兩件事分開，否則按鍵測試會被 provider 的邏輯拖著跑。
void main() {
  late ProviderContainer container;
  late ComposerHistory history;

  setUp(() {
    container = ProviderContainer();
    history = container.read(composerHistoryProvider.notifier);
  });

  tearDown(() => container.dispose());

  test('依房分開——一個房的歷史不會出現在另一個房', () {
    history.add('roomA', '甲房說的話');
    history.add('roomB', '乙房說的話');

    expect(history.of('roomA'), ['甲房說的話']);
    expect(history.of('roomB'), ['乙房說的話']);
  });

  test('沒說過話的房間拿到空清單，不是 null', () {
    expect(history.of('沒去過的房'), isEmpty);
  });

  test('由舊到新', () {
    history.add('r', '先說的');
    history.add('r', '後說的');
    expect(history.of('r'), ['先說的', '後說的']);
  });

  test('🔴 連續重複的內容不重複記', () {
    history.add('r', '同一句');
    history.add('r', '同一句');
    expect(history.of('r'), ['同一句'],
        reason: '同一句送兩次，↑ 要按兩下才回到前一則——沒有人預期得到');
  });

  test('中間隔了別的話，重複的內容照記', () {
    history.add('r', 'A');
    history.add('r', 'B');
    history.add('r', 'A');
    expect(history.of('r'), ['A', 'B', 'A'],
        reason: '只擋連續重複，不是全域去重——去重過頭會讓歷史對不上實際說過的順序');
  });

  test('空字串不記', () {
    history.add('r', '');
    expect(history.of('r'), isEmpty);
  });

  test('🔴 超過上限時丟掉最舊的，不是拒收最新的', () {
    for (var i = 0; i < ComposerHistory.maxPerRoom + 10; i++) {
      history.add('r', '第 $i 則');
    }
    final kept = history.of('r');
    expect(kept.length, ComposerHistory.maxPerRoom);
    expect(kept.last, '第 ${ComposerHistory.maxPerRoom + 9} 則',
        reason: '最新的那則一定要在——丟錯方向的話 ↑ 第一下就拿到很久以前的話');
    expect(kept.first, '第 10 則');
  });
}
