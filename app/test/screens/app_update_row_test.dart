import 'package:chatroom_app/api/tokens_api.dart';
import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/config/build_info.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/core/window/window_tray.dart';
import 'package:chatroom_app/l10n/app_localizations.dart';
import 'package:chatroom_app/screens/settings/app_update_row.dart';
import 'package:chatroom_app/screens/settings/settings_screen.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/app_updater.dart';
import 'package:chatroom_app/state/assignments_providers.dart';
import 'package:chatroom_app/widgets/uep_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/l10n.dart';

/// 設定頁的檢查更新列：每個狀態的那一行字與那一顆按鈕。
///
/// 狀態直接塞進去（[_FixedUpdate]），不走真的查詢與下載——那些在
/// `app_updater_test` 驗。字串一律從 l10n 物件取。
class _FixedUpdate extends AppUpdate {
  _FixedUpdate(this.initial, this.calls);

  final AppUpdateState initial;
  final List<String> calls;

  @override
  AppUpdateState build() => initial;

  @override
  Future<void> check() async => calls.add('check');

  @override
  Future<void> download() async => calls.add('download');

  @override
  Future<void> restart() async => calls.add('restart');
}

const _release = BuildInfo(version: '1.2.5', commit: 'abc123def456', builtAt: '');

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  final l10n = lookupAppLocalizations(kTestLocale);
  late List<String> calls;

  setUp(() => calls = []);

  Widget wrap(
    AppUpdateState state, {
    BuildInfo info = _release,
    bool windows = true,
  }) =>
      ProviderScope(
        overrides: [
          appUpdatePlatformProvider.overrideWithValue(windows),
          appBuildInfoProvider.overrideWithValue(info),
          appUpdateProvider.overrideWith(() => _FixedUpdate(state, calls)),
        ],
        child: MaterialApp(
          locale: kTestLocale,
          localizationsDelegates: kTestLocalizationsDelegates,
          supportedLocales: kTestSupportedLocales,
          theme: buildUepTheme(Brightness.dark),
          home: const Scaffold(body: AppUpdateRow()),
        ),
      );

  UepButton button(WidgetTester tester) =>
      tester.widget<UepButton>(find.byType(UepButton));

  /// 畫面上所有 `Text` 的內容，扣掉按鈕自己的那一個。
  List<String> lines(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .where((t) => find
          .ancestor(of: find.byWidget(t), matching: find.byType(UepButton))
          .evaluate()
          .isEmpty)
      .map((t) => t.data ?? '')
      .toList();

  group('停用條件：不顯示按鈕', () {
    testWidgets('dev build', (tester) async {
      await tester.pumpWidget(wrap(const AppUpdateState(),
          info: const BuildInfo(version: '1.0.0', commit: '', builtAt: '')));
      expect(find.byType(UepButton), findsNothing);
    });

    testWidgets('dirty build', (tester) async {
      await tester.pumpWidget(wrap(const AppUpdateState(),
          info: const BuildInfo(
              version: '1.2.5', commit: 'abc123-dirty', builtAt: '')));
      expect(find.byType(UepButton), findsNothing);
    });

    testWidgets('非 Windows', (tester) async {
      await tester.pumpWidget(wrap(const AppUpdateState(), windows: false));
      expect(find.byType(UepButton), findsNothing);
    });
  });

  testWidgets('idle：只有「檢查更新」，按了才查', (tester) async {
    await tester.pumpWidget(wrap(const AppUpdateState()));
    expect(button(tester).label, l10n.settingsUpdateCheck);
    expect(lines(tester), isEmpty);
    // 畫出來不等於查過：沒有自動檢查
    expect(calls, isEmpty);

    await tester.tap(find.byType(UepButton));
    expect(calls, ['check']);
  });

  testWidgets('checking：轉圈、按鈕按不動', (tester) async {
    await tester.pumpWidget(
        wrap(const AppUpdateState(phase: AppUpdatePhase.checking)));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(button(tester).onPressed, isNull);
    expect(lines(tester), isEmpty);
  });

  testWidgets('upToDate：已是最新版本，可以再查', (tester) async {
    await tester.pumpWidget(
        wrap(const AppUpdateState(phase: AppUpdatePhase.upToDate)));
    expect(lines(tester), [l10n.settingsUpdateUpToDate]);
    expect(button(tester).label, l10n.settingsUpdateCheck);
    expect(button(tester).onPressed, isNotNull);
  });

  testWidgets('checkFailed：查不到，不是已是最新', (tester) async {
    await tester.pumpWidget(
        wrap(const AppUpdateState(phase: AppUpdatePhase.checkFailed)));
    expect(lines(tester), [l10n.settingsUpdateCheckFailed]);
    expect(find.text(l10n.settingsUpdateUpToDate), findsNothing);
    expect(button(tester).label, l10n.settingsUpdateCheck);
  });

  testWidgets('available：帶 tag，按鈕變成下載並更新', (tester) async {
    await tester.pumpWidget(wrap(const AppUpdateState(
        phase: AppUpdatePhase.available, tag: 'v1.2.6')));
    expect(lines(tester), [l10n.settingsUpdateAvailable('v1.2.6')]);
    expect(lines(tester).single, contains('v1.2.6'));
    expect(button(tester).label, l10n.settingsUpdateDownload);

    await tester.tap(find.byType(UepButton));
    expect(calls, ['download']);
  });

  testWidgets('downloading：百分比，按鈕按不動', (tester) async {
    await tester.pumpWidget(wrap(const AppUpdateState(
        phase: AppUpdatePhase.downloading, tag: 'v1.2.6', progress: 0.42)));
    expect(lines(tester), [l10n.settingsUpdateDownloading('42')]);
    expect(button(tester).label, l10n.settingsUpdateDownload);
    expect(button(tester).onPressed, isNull);
  });

  testWidgets('ready：按鈕是重新啟動並更新，按了不另跳對話框', (tester) async {
    await tester.pumpWidget(wrap(
        const AppUpdateState(phase: AppUpdatePhase.ready, tag: 'v1.2.6')));
    expect(lines(tester), [l10n.settingsUpdateReady('v1.2.6')]);
    expect(button(tester).label, l10n.settingsUpdateRestart);

    await tester.tap(find.byType(UepButton));
    await tester.pump();
    expect(calls, ['restart']);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('applying：轉圈、按鈕按不動', (tester) async {
    await tester.pumpWidget(wrap(const AppUpdateState(
        phase: AppUpdatePhase.applying, tag: 'v1.2.6')));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(button(tester).onPressed, isNull);
  });

  testWidgets('failed：一句原因，按鈕回到檢查更新', (tester) async {
    final expected = {
      AppUpdateFailure.notWritable: l10n.settingsUpdateFailNotWritable,
      AppUpdateFailure.download: l10n.settingsUpdateFailDownload,
      AppUpdateFailure.sizeMismatch: l10n.settingsUpdateFailVerify,
      AppUpdateFailure.digestMismatch: l10n.settingsUpdateFailVerify,
      AppUpdateFailure.incomplete: l10n.settingsUpdateFailVerify,
      AppUpdateFailure.extract: l10n.settingsUpdateFailExtract,
      AppUpdateFailure.launch: l10n.settingsUpdateFailLaunch,
    };
    expect(expected.keys.toSet(), AppUpdateFailure.values.toSet());
    for (final MapEntry(key: failure, value: text) in expected.entries) {
      await tester.pumpWidget(wrap(AppUpdateState(
          phase: AppUpdatePhase.failed, tag: 'v1.2.6', failure: failure)));
      await tester.pump();
      expect(lines(tester), [text], reason: '$failure');
      expect(button(tester).label, l10n.settingsUpdateCheck);
      expect(button(tester).onPressed, isNotNull);
      // 換下一個狀態前把整棵樹拆掉，override 才會重建
      await tester.pumpWidget(const SizedBox());
    }
  });

  group('設定頁', () {
    final realSupported = WindowTray.supportedOverride;
    late SettingsRepository settings;

    setUp(() async {
      WindowTray.supportedOverride = false;
      SharedPreferences.setMockInitialValues({});
      settings = SettingsRepository(await SharedPreferences.getInstance());
    });

    tearDown(() => WindowTray.supportedOverride = realSupported);

    Widget host({required BuildInfo info}) {
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
          // 邀請區塊會去打 Hub：不擋的話測試結束時 dio 的計時器還醒著
          accessTokensProvider.overrideWith((ref) async => const <AccessToken>[]),
          initialConfigProvider.overrideWithValue(
            AppConfig.fromSettings(settings, token: '', deviceKey: 'dev-1'),
          ),
          appUpdatePlatformProvider.overrideWithValue(true),
          appBuildInfoProvider.overrideWithValue(info),
          appUpdateProvider
              .overrideWith(() => _FixedUpdate(const AppUpdateState(), calls)),
        ],
        child: MaterialApp.router(
          theme: buildUepTheme(Brightness.dark),
          routerConfig: router,
          locale: kTestLocale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      );
    }

    Finder checkButton() => find.byWidgetPredicate(
        (w) => w is UepButton && w.label == l10n.settingsUpdateCheck);

    testWidgets('Release 版：連線分頁有檢查更新，進頁面不會自己去查',
        (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(host(info: _release));
      await tester.pump();

      expect(checkButton(), findsOneWidget);
      expect(calls, isEmpty);
    });

    testWidgets('dev build：連線分頁沒有檢查更新', (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(host(
          info: const BuildInfo(version: '1.0.0', commit: '', builtAt: '')));
      await tester.pump();

      expect(find.text(l10n.settingsAppVersion), findsOneWidget);
      expect(checkButton(), findsNothing);
    });
  });
}
