import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/l10n/l10n.dart';
import 'package:chatroom_app/screens/help/help_screen.dart';
import 'package:chatroom_app/widgets/help_blocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../helpers/l10n.dart';

/// 說明頁整頁在窄／寬視窗、每一檔字級、三種語言下都能排出來而不溢出。
///
/// 視窗高度開得很高，ListView 才會把整份文件都建出來——不然只驗得到
/// 第一屏，後面的卡片與表格從沒被排版過。

Widget _app(HelpTopic topic, FontScalePref pref, Locale locale) =>
    MaterialApp.router(
      // 返回鈕靠 GoRouter 判斷能不能 pop，所以要掛在 router 底下
      routerConfig: GoRouter(routes: [
        GoRoute(path: '/', builder: (_, _) => HelpScreen(topic: topic)),
      ]),
      localizationsDelegates: kTestLocalizationsDelegates,
      supportedLocales: const [
        Locale('zh', 'TW'),
        Locale('zh'),
        Locale('en'),
      ],
      locale: locale,
      theme: buildUepTheme(Brightness.dark),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(fontScaleFactor(pref))),
        child: child!,
      ),
    );

void _view(WidgetTester tester, double width) {
  tester.view.physicalSize = Size(width, 40000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  for (final topic in HelpTopic.values) {
    for (final width in [360.0, 1200.0]) {
      for (final pref in FontScalePref.values) {
        testWidgets('${topic.name} / $width px / ${pref.name}', (tester) async {
          _view(tester, width);
          await tester.pumpWidget(_app(topic, pref, kTestLocale));
          await tester.pump();
          expect(tester.takeException(), isNull);
          // 整份文件都有排進去：最後一節的標題畫得出來
          final doc = helpDocs(lookupAppLocalizations(kTestLocale))[topic]!;
          expect(find.text(doc.sections.last.title), findsWidgets);
        });
      }
    }
  }

  for (final locale in const [Locale('zh'), Locale('en')]) {
    for (final topic in HelpTopic.values) {
      testWidgets('${topic.name} / 窄 / 最大字級 / $locale', (tester) async {
        _view(tester, 360);
        await tester.pumpWidget(_app(topic, FontScalePref.xlarge, locale));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('主頁真的用到卡片、表格、步驟與提示區塊', (tester) async {
    _view(tester, 1200);
    await tester.pumpWidget(_app(HelpTopic.main, FontScalePref.medium, kTestLocale));
    await tester.pump();
    expect(find.byType(HelpCardGrid), findsWidgets);
    expect(find.byType(HelpTable), findsWidgets);
    expect(find.byType(HelpSteps), findsWidgets);
    expect(find.byType(HelpCallout), findsWidgets);
  });
}
