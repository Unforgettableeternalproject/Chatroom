import 'package:chatroom_app/api/tokens_api.dart';
import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/core/window/window_tray.dart';
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

/// 設定頁的系統匣開關：只在支援的平台出現，點了就落盤。
///
/// 支援與否用 [closeToTraySupportedProvider] 覆寫——跑測試那台機器的
/// 作業系統不是被測的條件。locale 寫死 zh_TW（測試平台是 en_US）。
Widget _host(SettingsRepository settings, {required bool traySupported}) {
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
      closeToTraySupportedProvider.overrideWithValue(traySupported),
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

const _label = '開發者模式';

Future<void> _openPersonalTab(WidgetTester tester) async {
  await tester.pump();
  await tester.tap(find.text('個人化').first);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late SettingsRepository settings;
  final realSupported = WindowTray.supportedOverride;

  setUp(() async {
    WindowTray.supportedOverride = false;
    SharedPreferences.setMockInitialValues({});
    settings = SettingsRepository(await SharedPreferences.getInstance());
    UepText.family = FontFamilyPref.standard;
  });

  tearDown(() {
    WindowTray.supportedOverride = realSupported;
    UepText.family = FontFamilyPref.standard;
  });

  // 開關不依賴系統匣支援：兩種平台設定下都要在
  for (final tray in [true, false]) {
    testWidgets('系統匣${tray ? "支援" : "不支援"}時都有開關，預設關；打開會落盤',
        (tester) async {
      await tester.pumpWidget(_host(settings, traySupported: tray));
      await _openPersonalTab(tester);

      await tester.dragUntilVisible(
          find.text(_label), find.byType(ListView), const Offset(0, -80));
      await tester.pump();

      final toggle = find.descendant(
        of: find
            .ancestor(of: find.text(_label), matching: find.byType(Row))
            .first,
        matching: find.byType(Switch),
      );
      expect(toggle, findsOneWidget);
      expect(tester.widget<Switch>(toggle).value, isFalse);

      await tester.tap(toggle);
      await tester.pump();

      expect(settings.devMode, isTrue);
      expect(tester.widget<Switch>(toggle).value, isTrue);
    });
  }
}
