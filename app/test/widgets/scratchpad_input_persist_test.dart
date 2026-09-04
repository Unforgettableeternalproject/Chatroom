import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/scratchpad.dart';
import 'package:chatroom_app/screens/board/scratchpad_screen.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/scratchpad_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 🔴 2026-09-04：**想法板的輸入框會自己清空**（艾斯維爾在想法板上的觀察）。
///
/// 他猜「一直重複渲染」，方向對，但機制比那更具體：
/// **`ListView` 會把捲出可視範圍的 children 回收掉**，而輸入框在最下面。
/// 段落一多，它就落到視窗外 ⇒ element 被 dispose ⇒ `TextEditingController`
/// 跟著沒了 ⇒ 回到那裡時是空的。
///
/// ⚠️ 我第一版把它讀成「`_AddBlock` 沒有 key，位置一挪就被當成別人」——
/// **測出來不是**：2→3 段照樣留著，3→4 段才沒（那正是它被推出視窗的那一步）。
/// 兩種成因的修法完全不同（加 key vs. keepAlive），而畫面上長得一模一樣。
///
/// 同一件事也發生在**正在編輯的段落**上：編到一半捲出去，回來就白了。
/// 那條在 `_BlockCard` 那半，一起守。
Scratchpad _pad(int blocks) => Scratchpad.fromJson({
      'id': 'p1',
      'title': '功能',
      'rev': blocks,
      'can_edit': true,
      'i_am_human': true,
      'blocks': [
        for (var i = 0; i < blocks; i++)
          {'id': 'b$i', 'content': '第 $i 段', 'rev': 1, 'can_edit': true},
      ],
    });

const _cfg = AppConfig(
  serverUrl: 'http://test',
  token: 't',
  themeMode: ThemeModePref.dark,
  preferredName: '我',
  deviceKey: 'k',
);

/// 段落數可變，模擬「板上多了一段」。
int _blocks = 1;

Widget _app() => ProviderScope(
      overrides: [
        initialConfigProvider.overrideWithValue(_cfg),
        scratchpadProvider.overrideWith((ref, key) async => _pad(_blocks)),
      ],
      child: MaterialApp(
        theme: buildUepTheme(Brightness.dark),
        home: const Scaffold(
          body: ScratchpadScreen(boardId: 'bd1', padId: 'p1'),
        ),
      ),
    );

Finder get _addField => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.hintText == '再想到什麼就往這裡丟…');

Future<void> _grow(WidgetTester tester, int to) async {
  _blocks = to;
  final ctx = tester.element(find.byType(ScratchpadScreen));
  ProviderScope.containerOf(ctx, listen: false)
      .invalidate(scratchpadProvider(scratchpadKey('bd1', 'p1')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('🔴 段落多到把輸入框擠出畫面，還沒送出的那段字仍要留著',
      (tester) async {
    _blocks = 2;
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.enterText(_addField, '打到一半的想法');
    await tester.pump();
    expect(find.text('打到一半的想法'), findsOneWidget);

    // 3 段還看得到輸入框；**第 4 段是它掉出視窗的那一步**——
    // 舊行為就是在這裡把字弄丟的
    await _grow(tester, 3);
    await _grow(tester, 4);
    await _grow(tester, 6);

    expect(find.text('第 5 段'), findsOneWidget, reason: '新的段落要進得來');
    expect(
      find.text('打到一半的想法'),
      findsOneWidget,
      reason: 'ListView 回收了輸入框的話，這裡會是 0——那正是回報的症狀',
    );
  });

  testWidgets('編輯中的段落捲多遠都不掉——段落清單是 shrinkWrap，不回收',
      (tester) async {
    // ⚠️ **這條不是紅過的 bug**，是把「為什麼段落卡沒事、只有輸入框有事」
    // 這個差別釘住。段落走的是 `ReorderableListView(shrinkWrap: true)`，
    // 它會一次 build 全部；輸入框走的是外層真正 lazy 的 `ListView`。
    //
    // 我一度以為兩邊都要 `AutomaticKeepAliveClientMixin`，替段落卡也加了一份
    // ——**把 `wantKeepAlive` 寫死成 `false` 這條照樣綠**，那份保護從來沒在
    // 守什麼。哪天有人把 shrinkWrap 拿掉換成 lazy，這條會紅，那時才需要它。
    _blocks = 2;
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('編輯').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '第 0 段'), '改到一半');
    await tester.pump();

    await _grow(tester, 60);
    await tester.drag(find.byType(ListView), const Offset(0, -20000));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 20000));
    await tester.pumpAndSettle();

    expect(find.text('改到一半'), findsOneWidget);
  });
}
