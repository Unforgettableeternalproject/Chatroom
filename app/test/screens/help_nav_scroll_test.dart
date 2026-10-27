import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/l10n/l10n.dart';
import 'package:chatroom_app/screens/help/help_screen.dart';
import 'package:chatroom_app/widgets/help_blocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../helpers/l10n.dart';

/// 分節導覽：任何捲動位置、點整列任何地方都要捲到對應節。
///
/// 視窗高度刻意用一般尺寸（不像 layout 測試開 40000）——高視窗會把整份
/// 文件都建出來，正好遮掉「目標節沒被建出來所以點了沒反應」這個問題。

Widget _app() => MaterialApp.router(
      routerConfig: GoRouter(routes: [
        GoRoute(
            path: '/', builder: (_, _) => const HelpScreen(topic: HelpTopic.main)),
      ]),
      localizationsDelegates: kTestLocalizationsDelegates,
      supportedLocales: const [Locale('zh', 'TW')],
      locale: kTestLocale,
      theme: buildUepTheme(Brightness.dark),
    );

void _view(WidgetTester tester, double width) {
  tester.view.physicalSize = Size(width, 700);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

ScrollableState _scroll(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first);

/// 第 [i] 節標題區塊的頂端 y；沒建出來就是 null。
double? _sectionTop(WidgetTester tester, String title) {
  final f = find.byWidgetPredicate(
      (w) => w is HelpSectionBlock && w.title == title);
  if (f.evaluate().isEmpty) return null;
  return tester.getTopLeft(f).dy;
}

void main() {
  final l10n = lookupAppLocalizations(kTestLocale);
  final sections = helpDocs(l10n)[HelpTopic.main]!.sections;
  final first = sections.first.title;
  final last = sections.last.title;

  for (final width in [1200.0, 600.0]) {
    final mode = width >= 900 ? '寬（側欄）' : '窄（chip）';

    testWidgets('$mode：從頂端點最後一節捲得到', (tester) async {
      _view(tester, width);
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      expect(_scroll(tester).position.pixels, 0);

      await tester.tap(find.byKey(ValueKey('help-nav-${sections.length - 1}')));
      await tester.pumpAndSettle();

      expect(_scroll(tester).position.pixels, greaterThan(0),
          reason: '點了最後一節但頁面沒動');
      final top = _sectionTop(tester, last);
      expect(top, isNotNull, reason: '最後一節沒有被建出來');
      expect(top!, inInclusiveRange(0, 700));
    });

    testWidgets('$mode：從底部點第一節捲得到', (tester) async {
      _view(tester, width);
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      final pos = _scroll(tester).position;
      pos.jumpTo(pos.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(pos.pixels, greaterThan(0));

      // 窄螢幕的 chip 在頁面最上面，捲到底後看不到；先捲回去點一次即可
      // 驗不到「從底部點」，所以窄螢幕的 chip 用「從中段點」代替。
      if (width < 900) {
        pos.jumpTo(0);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('help-nav-${sections.length - 1}')));
        await tester.pumpAndSettle();
        final mid = pos.pixels;
        pos.jumpTo(0);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('help-nav-3')));
        await tester.pumpAndSettle();
        expect(pos.pixels, greaterThan(0));
        expect(pos.pixels, lessThan(mid));
        return;
      }

      await tester.tap(find.byKey(const ValueKey('help-nav-0')));
      await tester.pumpAndSettle();
      final top = _sectionTop(tester, first);
      expect(top, isNotNull, reason: '第一節沒有被建出來');
      expect(top!, inInclusiveRange(0, 200));
      expect(pos.pixels, lessThan(200));
    });

    testWidgets('$mode：每一節從頂端點都捲到、且在視窗內', (tester) async {
      _view(tester, width);
      for (var i = 0; i < sections.length; i++) {
        await tester.pumpWidget(_app());
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('help-nav-$i')));
        await tester.pumpAndSettle();
        final top = _sectionTop(tester, sections[i].title);
        expect(top, isNotNull, reason: '第 $i 節沒有被建出來');
        expect(top!, inInclusiveRange(0, 700), reason: '第 $i 節不在視窗內');
      }
    });
  }

  testWidgets('寬：點導覽列右側空白處也觸發', (tester) async {
    _view(tester, 1200);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('help-nav-4'));
    // 列的右緣往內 4px：遠離文字，只可能落在「整列」的熱區上
    final p = tester.getTopRight(row) + const Offset(-4, 10);
    final textRight = tester.getTopRight(
        find.descendant(of: row, matching: find.byType(Text)).first);
    expect(p.dx, greaterThan(textRight.dx + 8), reason: '測試點沒有落在文字外');
    await tester.tapAt(p);
    await tester.pumpAndSettle();
    expect(_scroll(tester).position.pixels, greaterThan(0));
  });
}
