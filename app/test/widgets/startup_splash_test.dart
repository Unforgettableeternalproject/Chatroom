import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/startup/startup_gate.dart';
import 'package:chatroom_app/screens/startup/startup_splash.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/l10n.dart';

Future<void> _mount(
  WidgetTester tester, {
  String splashText = '',
  List<StartupInitializer> inits = const [],
  bool disableAnimations = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsRepository(await SharedPreferences.getInstance());
  await tester.pumpWidget(ProviderScope(
    overrides: [
      settingsRepoProvider.overrideWithValue(settings),
      initialConfigProvider.overrideWithValue(AppConfig(
        serverUrl: '',
        token: '',
        themeMode: ThemeModePref.dark,
        preferredName: '',
        deviceKey: 'k',
        splashText: splashText,
      )),
      startupInitializersProvider.overrideWithValue(inits),
    ],
    child: MaterialApp(
      localizationsDelegates: kTestLocalizationsDelegates,
      supportedLocales: kTestSupportedLocales,
      locale: kTestLocale,
      theme: buildUepTheme(Brightness.dark),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(disableAnimations: disableAnimations),
        child: StartupSplashGate(child: child!),
      ),
      home: const Text('APP'),
    ),
  ));
}

void main() {
  testWidgets('預設字樣；2 秒後離開，App 本體不被重建', (tester) async {
    await _mount(tester);
    expect(find.text('正在進入聊天室'), findsOneWidget);
    final appElement = tester.element(find.text('APP'));

    await tester.pump(const Duration(milliseconds: 1900));
    expect(find.text('正在進入聊天室'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('正在進入聊天室'), findsNothing);
    expect(tester.element(find.text('APP')), same(appElement));
  });

  testWidgets('自訂固定字樣', (tester) async {
    await _mount(tester, splashText: '歡迎回來');
    expect(find.text('歡迎回來'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('初始化 3 秒 → 3 秒前仍擋著', (tester) async {
    await _mount(tester, inits: [
      () => Future<void>.delayed(const Duration(seconds: 3)),
    ]);
    await tester.pump(const Duration(milliseconds: 2500));
    expect(find.text('正在進入聊天室'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('正在進入聊天室'), findsNothing);
  });

  testWidgets('減少動態效果：靜態顯示，放行後立即移除', (tester) async {
    await _mount(tester, disableAnimations: true);
    expect(find.text('正在進入聊天室'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('正在進入聊天室'), findsNothing);
  });

  testWidgets('Logo 在旋轉；字樣無 fallback 樣式（無底線、有 Material 祖先）', (tester) async {
    await _mount(tester, inits: [
      () => Future<void>.delayed(const Duration(seconds: 3)),
    ]);
    final logo = find.descendant(
      of: find.byType(StartupSplash),
      matching: find.byType(Image),
    );
    expect(logo, findsOneWidget);
    expect((tester.widget<Image>(logo).image as AssetImage).assetName,
        'assets/logo.png');

    double turns() =>
        tester.widget<RotationTransition>(find.byType(RotationTransition))
            .turns
            .value;
    final t0 = turns();
    await tester.pump(const Duration(milliseconds: 450));
    expect(turns(), isNot(t0));

    final textFinder = find.text('正在進入聊天室');
    final style = tester
        .widget<RichText>(find
            .descendant(of: textFinder, matching: find.byType(RichText))
            .first)
        .text
        .style!;
    expect(style.decoration, anyOf(isNull, TextDecoration.none));
    expect(
      find.ancestor(of: textFinder, matching: find.byType(Material)),
      findsWidgets,
    );
    // 實際生效的樣式（含 DefaultTextStyle）也不能有底線
    final effective = DefaultTextStyle.of(tester.element(textFinder)).style;
    expect(effective.decoration, anyOf(isNull, TextDecoration.none));

    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('減少動態效果：Logo 靜止、沒有旋轉', (tester) async {
    await _mount(tester, disableAnimations: true);
    expect(find.byType(RotationTransition), findsNothing);
    expect(
      find.descendant(
          of: find.byType(StartupSplash), matching: find.byType(Image)),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 2));
  });
}
