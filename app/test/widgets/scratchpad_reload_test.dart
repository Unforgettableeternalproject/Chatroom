import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/scratchpad.dart';
import 'package:chatroom_app/screens/board/scratchpad_screen.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/scratchpad_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 🔴 2026-09-04：艾斯維爾「**寫到一半他會跳一下，然後字就被清空了**」。
///
/// 上午修的是「捲出視窗被 ListView 回收」（`038ba76`）——那是真的，但**不是
/// 全部**：他手上跑的正是含那個修的版本，症狀還在。
///
/// 這條驗的是另一半：**provider 重算時 `.when(loading:)` 會把整棵子樹換成
/// 一個轉圈圈**。`skipLoadingOnRefresh` 預設 true（invalidate 保留舊值），
/// 但 **`skipLoadingOnReload` 預設 false**——provider 的**依賴**變動而重算時，
/// 畫面會真的閃過 loading，底下的 State 全部 dispose。
///
/// 那個「閃一下」就是他說的「跳一下」，字是在那一瞬間沒的。
class _Dep extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final _dep = NotifierProvider<_Dep, int>(_Dep.new);

Scratchpad _pad() => Scratchpad.fromJson({
      'id': 'p1',
      'title': '功能',
      'rev': 1,
      'can_edit': true,
      'i_am_human': true,
      'blocks': [
        {'id': 'b0', 'content': '第 0 段', 'rev': 1, 'can_edit': true},
      ],
    });

const _cfg = AppConfig(
  serverUrl: 'http://test',
  token: 't',
  themeMode: ThemeModePref.dark,
  preferredName: '我',
  deviceKey: 'k',
);

void main() {
  testWidgets('🔴 provider 因依賴變動而重算時，打到一半的字不可以消失',
      (tester) async {
    final container = ProviderContainer(overrides: [
      initialConfigProvider.overrideWithValue(_cfg),
      scratchpadProvider.overrideWith((ref, key) async {
        // 真實情況：這份 provider 依賴別的東西（身分、板水位…），
        // 那些一動它就整份重算
        ref.watch(_dep);
        return _pad();
      }),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildUepTheme(Brightness.dark),
        home: const Scaffold(
          body: ScratchpadScreen(boardId: 'bd1', padId: 'p1'),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byWidgetPredicate((w) =>
          w is TextField && w.decoration?.hintText == '再想到什麼就往這裡丟…'),
      '打到一半的想法',
    );
    await tester.pump();
    expect(find.text('打到一半的想法'), findsOneWidget);

    // 依賴變動 ⇒ provider 重算（reload，不是 refresh）
    container.read(_dep.notifier).bump();
    await tester.pump();

    // 這一格是關鍵：重算的那一瞬間畫面上是什麼
    final spinner =
        find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
    await tester.pumpAndSettle();

    expect(
      find.text('打到一半的想法'),
      findsOneWidget,
      reason: spinner
          ? '重算時整棵樹被換成 loading，輸入框連同 controller 一起被 dispose'
          : '重算時字不見了（但沒有經過 loading）',
    );
  });
}
