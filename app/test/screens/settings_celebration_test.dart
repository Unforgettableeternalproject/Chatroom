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
      closeToTraySupportedProvider.overrideWithValue(false),
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

  testWidgets('個人化有慶祝模式開關，預設關；打開會落盤', (tester) async {
    await tester.pumpWidget(_host(settings));
    await tester.pump();
    await tester.tap(find.text('個人化').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.dragUntilVisible(
        find.text('慶祝模式'), find.byType(ListView), const Offset(0, -80));
    await tester.pump();

    final toggle = find.descendant(
      of: find
          .ancestor(of: find.text('慶祝模式'), matching: find.byType(Row))
          .first,
      matching: find.byType(Switch),
    );
    expect(toggle, findsOneWidget);
    expect(tester.widget<Switch>(toggle).value, isFalse);

    await tester.tap(toggle);
    await tester.pump();

    expect(settings.celebrationMode, isTrue);
    expect(tester.widget<Switch>(toggle).value, isTrue);
  });
}
