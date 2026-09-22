import 'package:chatroom_app/api/tokens_api.dart';
import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/l10n/app_localizations.dart';
import 'package:chatroom_app/screens/settings/settings_screen.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/assignments_providers.dart';
import 'package:chatroom_app/widgets/uep_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 設定頁的字體列：畫得出來，而且點下去真的存。
///
/// locale 寫死 zh_TW——測試平台的 locale 是 en_US，不指定的話整頁是英文。
Widget _host(SettingsRepository settings) {
  final router = GoRouter(
    initialLocation: '/settings',
    routes: [
      GoRoute(
        path: '/settings',
        builder: (context, state) => const SettingsScreen(),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      settingsRepoProvider.overrideWithValue(settings),
      // 邀請區塊會去打 Hub：不擋的話測試結束時 dio 的計時器還醒著
      accessTokensProvider.overrideWith((ref) async => const <AccessToken>[]),
      initialConfigProvider.overrideWithValue(
        AppConfig.fromSettings(settings, token: '', deviceKey: 'dev-1'),
      ),
    ],
    child: MaterialApp.router(
      theme: buildUepTheme(Brightness.dark),
      routerConfig: router,
      locale: const Locale('zh', 'TW'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    ),
  );
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late SettingsRepository settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsRepository(await SharedPreferences.getInstance());
    UepText.family = FontFamilyPref.standard;
  });

  tearDown(() => UepText.family = FontFamilyPref.standard);

  testWidgets('視覺分頁列出五個字體選項，點了就落盤', (tester) async {
    await tester.pumpWidget(_host(settings));
    await tester.pump();

    await tester.tap(find.text('視覺').first);
    // 分頁切換有動畫；不用 pumpAndSettle——邀請區塊的 dio 計時器還醒著
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('字級'), findsOneWidget);

    // 800x600 的測試視窗裝不下整個視覺分頁，字體那段在摺線下
    await tester.dragUntilVisible(
        find.text('字體'), find.byType(ListView), const Offset(0, -80));
    await tester.pump();

    expect(find.text('字體'), findsOneWidget);
    // 「預設」字級也叫這個名字，所以限定在字體那排（唯一的 Wrap）裡找
    final chips = find.byType(Wrap);
    for (final label in ['預設', '芫荽', '粉圓', '辰宇落雁體', 'Glow Sans']) {
      expect(find.descendant(of: chips, matching: find.text(label)),
          findsOneWidget,
          reason: label);
    }

    await tester.tap(find.text('芫荽'));
    await tester.pump();

    expect(settings.fontFamily, FontFamilyPref.iansui);
  });

  testWidgets('字體 chip 與字級 chip 同高', (tester) async {
    await tester.pumpWidget(_host(settings));
    await tester.pump();

    await tester.tap(find.text('視覺').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.dragUntilVisible(
        find.text('字體'), find.byType(ListView), const Offset(0, -80));
    await tester.pump();

    // 字級那排的「大」（UepButton small）當基準；字體那排每一顆都要一樣高，
    // 不然兩排並排看起來像兩種控制項
    final ruler = tester.getSize(find.widgetWithText(UepButton, '大')).height;
    for (final label in ['預設', '芫荽', '粉圓', '辰宇落雁體', 'Glow Sans']) {
      final chip = find.ancestor(
        of: find.descendant(
            of: find.byType(Wrap), matching: find.text(label)),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      );
      expect(tester.getSize(chip.first).height, ruler, reason: label);
    }
  });
}
