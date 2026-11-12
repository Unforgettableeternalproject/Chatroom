import 'dart:async';

import 'package:chatroom_app/api/rooms_api.dart';
import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/config/build_info.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/host_kit.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/app_updater.dart';
import 'package:chatroom_app/state/host_kit_providers.dart';
import 'package:chatroom_app/state/kit_installer.dart';
import 'package:chatroom_app/state/kit_prereq.dart';
import 'package:chatroom_app/state/reconnect_update.dart';
import 'package:chatroom_app/widgets/reconnect_update_dialog.dart';
import 'package:chatroom_app/ws/realtime_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import '../helpers/l10n.dart';

/// 斷線重連後的更新提示。
///
/// 全部是 fake：不打 GitHub、不起真進程、不碰真的 Hub。測的是「什麼時候
/// 問、問什麼、選了之後走哪條既有流程」，更新流程本身另有自己的測試。
class _FakeRoomsApi extends RoomsApi {
  _FakeRoomsApi(this.hubVersion) : super(Dio());

  String hubVersion;
  String hubCommit = 'deadbeef1234';
  String? hubBuiltAt;
  int calls = 0;

  @override
  Future<HealthResult> health() async {
    calls++;
    return HealthResult(
      ok: true,
      version: hubVersion,
      build: {
        'version': hubVersion,
        'commit': hubCommit,
        if (hubBuiltAt != null) 'built_at': hubBuiltAt,
      },
    );
  }
}

class _FakeAppUpdate extends AppUpdate {
  String? latestTag;
  int checks = 0;
  int downloads = 0;
  int restarts = 0;

  @override
  Future<void> check() async {
    checks++;
    state = latestTag == null
        ? const AppUpdateState(phase: AppUpdatePhase.upToDate)
        : AppUpdateState(phase: AppUpdatePhase.available, tag: latestTag!);
  }

  @override
  Future<void> download() async {
    downloads++;
    state = AppUpdateState(phase: AppUpdatePhase.ready, tag: latestTag!);
  }

  @override
  Future<void> restart() async => restarts++;
}

class _FakeKitInstalls extends KitInstalls {
  final hubInstalls = <(KitRelease, String, bool)>[];
  Map<KitId, KitInstallState> initial = const {};

  @override
  Map<KitId, KitInstallState> build() => initial;

  @override
  Future<void> installHub({
    required KitRelease release,
    required String targetDir,
    required bool restart,
  }) async {
    hubInstalls.add((release, targetDir, restart));
    state = {
      ...state,
      KitId.hub: const KitInstallState(phase: KitInstallPhase.done),
    };
  }
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  var appBuild =
      const BuildInfo(version: '1.2.8', commit: 'abc1234', builtAt: '', hotfix: 1);
  const hubRelease = KitRelease(tag: 'v1.2.8-hotfix1', assets: {
    'chatroom-hub-kit.zip': 'https://example.invalid/hub.zip',
  });

  late StreamController<RealtimeStatus> status;
  late _FakeRoomsApi api;
  late _FakeAppUpdate appUpdate;
  late _FakeKitInstalls kits;

  setUp(() {
    status = StreamController<RealtimeStatus>.broadcast();
    api = _FakeRoomsApi('1.2.8');
    appUpdate = _FakeAppUpdate();
    kits = _FakeKitInstalls();
    appBuild = const BuildInfo(
        version: '1.2.8', commit: 'abc1234', builtAt: '', hotfix: 1);
  });

  tearDown(() => status.close());

  List<Override> overrides({
    String serverUrl = 'http://127.0.0.1:8787',
    bool localKit = true,
    KitRelease? release = hubRelease,
    List<KitPrereq> prereqs = const [KitPrereq(KitPrereqKind.python)],
  }) =>
      [
        initialConfigProvider.overrideWithValue(AppConfig(
          serverUrl: serverUrl,
          token: 't',
          themeMode: ThemeModePref.dark,
          preferredName: '',
          deviceKey: 'k',
        )),
        appBuildProvider.overrideWithValue(appBuild),
        appBuildInfoProvider.overrideWithValue(appBuild),
        appUpdatePlatformProvider.overrideWithValue(true),
        kitInstallSupportedProvider.overrideWithValue(true),
        roomsApiProvider.overrideWithValue(api),
        connectionStatusProvider.overrideWith((ref) => status.stream),
        appUpdateProvider.overrideWith(() => appUpdate),
        kitInstallsProvider.overrideWith(() => kits),
        hostKitProvider.overrideWith((ref) async => localKit
            ? const HostKit(kitRoot: r'C:\hub-kit', envFile: '')
            : null),
        hostEnvProvider.overrideWith((ref) async => null),
        kitReleaseProvider.overrideWith((ref) async => release),
        kitPrereqsProvider.overrideWith((ref, kit) async => prereqs),
      ];

  ProviderContainer make([List<Override>? o]) {
    final container = ProviderContainer(overrides: o ?? overrides());
    // 保活：和真實 App 裡 AppShell 一直 watch 它一樣
    container.listen(reconnectUpdateProvider, (_, _) {});
    container.listen(connectionStatusProvider, (_, _) {});
    addTearDown(container.dispose);
    return container;
  }

  Future<void> tick() async {
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> send(RealtimeStatus s) async {
    status.add(s);
    await tick();
  }

  /// 斷線 → 重連中 → 再連上。
  Future<void> reconnect() async {
    await send(const Disconnected(reason: 'background'));
    await send(const Connecting());
    await send(Connected());
  }

  group('觸發時機', () {
    test('首次連上不觸發（即使 App 比 Hub 舊、也有新版）', () async {
      api.hubVersion = '1.3.0';
      appUpdate.latestTag = 'v1.3.0';
      final c = make();
      await send(Connected());
      expect(c.read(reconnectUpdateProvider), isNull);
      expect(appUpdate.checks, 0);
      expect(api.calls, 0);
    });

    test('啟動時先斷後連（還沒連上過）也不算重連', () async {
      api.hubVersion = '1.3.0';
      appUpdate.latestTag = 'v1.3.0';
      final c = make();
      await send(const Disconnected());
      await send(Connected());
      expect(c.read(reconnectUpdateProvider), isNull);
      expect(appUpdate.checks, 0);
    });

    test('斷線本身、沒有斷線的重複 Connected 都不觸發', () async {
      api.hubVersion = '1.3.0';
      appUpdate.latestTag = 'v1.3.0';
      final c = make();
      await send(Connected());
      await send(const Disconnected(reason: 'background'));
      expect(appUpdate.checks, 0);
      await send(Connected());
      expect(appUpdate.checks, 1, reason: '重連一次評估一次');
      await send(Connected());
      expect(appUpdate.checks, 1, reason: '沒有斷線的重複 Connected 不重評估');
      expect(c.read(reconnectUpdateProvider), isNotNull);
    });

    test('版本相同（含只差熱修）不問也不查', () async {
      final c = make();
      await send(Connected());
      await reconnect();
      expect(c.read(reconnectUpdateProvider), isNull);
      expect(appUpdate.checks, 0);
      expect(kits.hubInstalls, isEmpty);
    });
  });

  group('App 比 Hub 舊', () {
    setUp(() => api.hubVersion = '1.3.0');

    test('有較新的 Release → 問', () async {
      appUpdate.latestTag = 'v1.3.0';
      final c = make();
      await send(Connected());
      await reconnect();
      final p = c.read(reconnectUpdateProvider);
      expect(p?.kind, ReconnectUpdateKind.app);
      expect(p?.tag, 'v1.3.0');
      expect(appUpdate.downloads, 0, reason: '還沒選更新，不能先下載');
    });

    test('沒有較新的 Release → 什麼都不做', () async {
      appUpdate.latestTag = null;
      final c = make();
      await send(Connected());
      await reconnect();
      expect(appUpdate.checks, 1);
      expect(c.read(reconnectUpdateProvider), isNull);
      expect(appUpdate.downloads, 0);
    });

    test('選更新 → 走既有的下載與重新啟動', () async {
      appUpdate.latestTag = 'v1.3.0';
      final c = make();
      await send(Connected());
      await reconnect();
      final ok = await c.read(reconnectUpdateProvider.notifier).accept();
      expect(ok, isTrue);
      expect(appUpdate.downloads, 1);
      expect(appUpdate.restarts, 1);
      expect(c.read(reconnectUpdateProvider), isNull);
    });

    test('選稍後 → 同一版本本次執行期間不再問；更新的版本會再問', () async {
      appUpdate.latestTag = 'v1.3.0';
      final c = make();
      await send(Connected());
      await reconnect();
      c.read(reconnectUpdateProvider.notifier).decline();
      expect(c.read(reconnectUpdateProvider), isNull);

      await reconnect();
      expect(c.read(reconnectUpdateProvider), isNull, reason: '同一版本不再問');

      appUpdate.latestTag = 'v1.3.1';
      await reconnect();
      expect(c.read(reconnectUpdateProvider)?.tag, 'v1.3.1');
    });
  });

  group('Hub 比 App 舊', () {
    setUp(() => api.hubVersion = '1.2.7');

    test('本機 Hub → 問；選更新才走既有的 Hub 更新', () async {
      final c = make();
      await send(Connected());
      await reconnect();
      final p = c.read(reconnectUpdateProvider);
      expect(p?.kind, ReconnectUpdateKind.hub);
      expect(p?.tag, 'v1.2.8-hotfix1');
      expect(kits.hubInstalls, isEmpty, reason: '選更新之前不能動 Hub');

      final ok = await c.read(reconnectUpdateProvider.notifier).accept();
      expect(ok, isTrue);
      expect(kits.hubInstalls, hasLength(1));
      final (release, dir, restart) = kits.hubInstalls.single;
      expect(release.tag, 'v1.2.8-hotfix1');
      expect(dir, r'C:\hub-kit');
      expect(restart, isTrue);
    });

    test('選稍後 → 不更新，同一版本不再問', () async {
      final c = make();
      await send(Connected());
      await reconnect();
      c.read(reconnectUpdateProvider.notifier).decline();
      await reconnect();
      expect(c.read(reconnectUpdateProvider), isNull);
      expect(kits.hubInstalls, isEmpty);
    });

    test('Hub 不是本機（沒登記主持包）→ 不問', () async {
      final c = make(overrides(localKit: false));
      await send(Connected());
      await reconnect();
      expect(c.read(reconnectUpdateProvider), isNull);
    });

    test('有主持包、但 App 連的是別台 Hub → 不問', () async {
      final c = make(overrides(serverUrl: 'https://hub.example.com'));
      await send(Connected());
      await reconnect();
      expect(c.read(reconnectUpdateProvider), isNull);
    });

    test('沒有對應的 Release → 不問', () async {
      final c = make(overrides(release: null));
      await send(Connected());
      await reconnect();
      expect(c.read(reconnectUpdateProvider), isNull);
    });

    test('前置條件不過（沒有 Python）→ 不問', () async {
      final c = make(overrides(prereqs: const [
        KitPrereq(KitPrereqKind.python, issue: KitPrereqIssue.missing),
      ]));
      await send(Connected());
      await reconnect();
      expect(c.read(reconnectUpdateProvider), isNull);
    });

    test('Hub 更新進行中 → 不問', () async {
      kits.initial = {
        KitId.hub: const KitInstallState(phase: KitInstallPhase.installing),
      };
      final c = make();
      await send(Connected());
      await reconnect();
      expect(c.read(reconnectUpdateProvider), isNull);
    });
  });

  group('同 x.y.z 靠建置時間判斷（熱修）', () {
    BuildInfo app(String builtAt) => BuildInfo(
        version: '1.2.8', commit: 'abc1234', builtAt: builtAt, hotfix: 1);

    test('App 建置較早 → 視為 App 較舊，交給 check() 決定', () async {
      appBuild = app('2026-11-01T00:00:00Z');
      api.hubBuiltAt = '2026-11-12T00:00:00Z';
      appUpdate.latestTag = 'v1.2.8-hotfix1';
      final c = make();
      await send(Connected());
      await reconnect();
      expect(appUpdate.checks, 1);
      expect(c.read(reconnectUpdateProvider)?.kind, ReconnectUpdateKind.app);
    });

    test('Hub 建置較早 → 視為 Hub 較舊，本機 → 問', () async {
      appBuild = app('2026-11-12T00:00:00Z');
      api.hubBuiltAt = '2026-11-01T00:00:00Z';
      final c = make();
      await send(Connected());
      await reconnect();
      expect(appUpdate.checks, 0);
      expect(c.read(reconnectUpdateProvider)?.kind, ReconnectUpdateKind.hub);
      expect(c.read(reconnectUpdateProvider)?.tag, 'v1.2.8-hotfix1');
    });

    test('同一個 build（commit 相同）→ 不觸發', () async {
      appBuild = app('2026-11-01T00:00:00Z');
      api.hubCommit = 'abc1234ffff';
      api.hubBuiltAt = '2026-11-12T00:00:00Z';
      appUpdate.latestTag = 'v1.2.8-hotfix1';
      final c = make();
      await send(Connected());
      await reconnect();
      expect(c.read(reconnectUpdateProvider), isNull);
      expect(appUpdate.checks, 0);
    });

    test('建置時間相同但 commit 不同 → 判不出誰舊，不觸發', () async {
      appBuild = app('2026-11-12T00:00:00Z');
      api.hubBuiltAt = '2026-11-12T00:00:00Z';
      final c = make();
      await send(Connected());
      await reconnect();
      expect(c.read(reconnectUpdateProvider), isNull);
    });
  });

  group('Dialog', () {
    Widget host(ProviderContainer c, ReconnectUpdatePrompt p) =>
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            locale: kTestLocale,
            localizationsDelegates: kTestLocalizationsDelegates,
            supportedLocales: kTestSupportedLocales,
            theme: buildUepTheme(Brightness.dark),
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: TextButton(
                  onPressed: () => askReconnectUpdate(context, ref, p),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        );

    testWidgets('App 較舊：出現 Dialog，選稍後不更新、記住這一版', (tester) async {
      api.hubVersion = '1.3.0';
      appUpdate.latestTag = 'v1.3.0';
      final c = make();
      await tester.runAsync(
          () => c.read(reconnectUpdateProvider.notifier).evaluate());
      final p = c.read(reconnectUpdateProvider)!;

      await tester.pumpWidget(host(c, p));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('v1.3.0'), findsOneWidget);

      await tester.tap(find.text('稍後再說'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(appUpdate.downloads, 0);
      expect(c.read(reconnectUpdateProvider), isNull);
    });

    testWidgets('Hub 較舊：選更新 → 觸發 Hub 更新', (tester) async {
      api.hubVersion = '1.2.7';
      final c = make();
      await tester.runAsync(
          () => c.read(reconnectUpdateProvider.notifier).evaluate());
      final p = c.read(reconnectUpdateProvider)!;

      await tester.pumpWidget(host(c, p));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.textContaining('本機 Hub'), findsOneWidget);
      expect(kits.hubInstalls, isEmpty);

      await tester.tap(find.text('更新'));
      await tester.pumpAndSettle();
      expect(kits.hubInstalls, hasLength(1));
    });
  });
}
