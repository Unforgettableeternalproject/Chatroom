import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/api/tokens_api.dart';
import 'package:chatroom_app/l10n/app_localizations.dart';
import 'package:chatroom_app/screens/settings/settings_screen.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/assignments_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// i18n 骨架的端對端一小段：ARB → gen-l10n → 畫面。
///
/// 驗的是「換一個 locale，設定頁真的講英文」——只驗 ARB 有那個鍵，
/// 證明不了 delegate 掛上了，也證明不了畫面讀的是它。
Widget _host(SettingsRepository settings, Locale locale) {
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
      locale: locale,
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
  });

  testWidgets('locale = en 時設定頁的標題與分頁是英文', (tester) async {
    await tester.pumpWidget(_host(settings, const Locale('en')));
    // 不 pumpAndSettle：邀請區塊會去打 Hub，這個測試不等它
    await tester.pump();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Connection'), findsOneWidget);
    expect(find.text('Appearance'), findsWidgets);
    expect(find.text('設定'), findsNothing);
  });

  testWidgets('locale = zh_TW 時仍是繁中', (tester) async {
    await tester.pumpWidget(_host(settings, const Locale('zh', 'TW')));
    await tester.pump();

    expect(find.text('設定'), findsOneWidget);
    expect(find.text('連線'), findsOneWidget);
    expect(find.text('Settings'), findsNothing);
  });
}
