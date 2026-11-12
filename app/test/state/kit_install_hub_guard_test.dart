import 'dart:io';

import 'package:chatroom_app/api/hub_active_runs_api.dart';
import 'package:chatroom_app/core/errors/api_exception.dart';
import 'package:chatroom_app/state/host_actions.dart';
import 'package:chatroom_app/state/kit_installer.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 更新本機 Hub 之前的「進行中工作」保護。
///
/// 全部是 fake：不打 Hub、不起進程。斷言的是「有 run 就不停 Hub」與
/// 「新端點 404 時退回逐房查、仍不確定就回 null」。
class _FakeRunsApi extends HubActiveRunsApi {
  _FakeRunsApi() : super(Dio());

  HubActiveRuns? result = const HubActiveRuns(0);

  @override
  Future<HubActiveRuns?> check() async => result;
}

/// 只覆寫兩個端點的取用，驗證 `check()` 的退路邏輯本身。
class _SplitRunsApi extends HubActiveRunsApi {
  _SplitRunsApi({this.global, this.rooms}) : super(Dio());

  Future<HubActiveRuns> Function()? global;
  Future<HubActiveRuns> Function()? rooms;
  int globalCalls = 0;
  int roomCalls = 0;

  @override
  Future<HubActiveRuns> fetchGlobal() {
    globalCalls++;
    return global!();
  }

  @override
  Future<HubActiveRuns> fetchByRooms() {
    roomCalls++;
    return rooms!();
  }
}

class _FakeActions extends HostActions {
  _FakeActions() : super('');

  final log = <String>[];

  @override
  Future<ProcessResult> stopHub() async {
    log.add('stop');
    return ProcessResult(0, 0, '', '');
  }

  @override
  Future<ProcessResult> service(String action) async {
    log.add(action);
    return ProcessResult(0, 0, '', '');
  }
}

class _FakeInstaller extends KitInstaller {
  _FakeInstaller()
      : super(
          http: _NoHttp(),
          processRunner: _NoRunner(),
          installRoot: '',
        );

  int installs = 0;

  @override
  Future<KitInstallResult> install(
    KitId kit, {
    required KitRelease release,
    String? targetDir,
    List<String> extraArgs = const [],
    void Function(KitInstallPhase phase, double progress)? onProgress,
  }) async {
    installs++;
    return const KitInstallResult(ok: true, version: '1.2.8');
  }
}

class _NoHttp implements KitHttpClient {
  @override
  Future<(int, Object?)> getJson(String url) => throw UnimplementedError();

  @override
  Future<void> download(String url, String savePath,
          {void Function(int received, int total)? onProgress}) =>
      throw UnimplementedError();
}

class _NoRunner implements KitProcessRunner {
  @override
  Future<ProcessResult> run(String executable, List<String> arguments,
          {String? workingDirectory}) =>
      throw UnimplementedError();
}

void main() {
  const release = KitRelease(tag: 'v1.2.8', assets: {
    'chatroom-hub-kit.zip': 'https://example.invalid/hub.zip',
  });

  late _FakeRunsApi runs;
  late _FakeActions actions;
  late _FakeInstaller installer;
  late ProviderContainer c;

  setUp(() {
    runs = _FakeRunsApi();
    actions = _FakeActions();
    installer = _FakeInstaller();
    c = ProviderContainer(overrides: [
      hubActiveRunsApiProvider.overrideWithValue(runs),
      hostActionsProvider.overrideWithValue(actions),
      kitInstallerProvider.overrideWithValue(installer),
    ]);
    addTearDown(c.dispose);
  });

  Future<void> update() => c.read(kitInstallsProvider.notifier).installHub(
      release: release, targetDir: r'C:\hub-kit', restart: true);

  group('installHub 的保護', () {
    test('有進行中的 run → 不停 Hub、不安裝，講出數量', () async {
      runs.result = const HubActiveRuns(3);
      await update();
      expect(actions.log, isEmpty, reason: '不能停 Hub');
      expect(installer.installs, 0);
      final st = c.read(kitInstallsProvider)[KitId.hub]!;
      expect(st.phase, KitInstallPhase.failed);
      expect(st.failure, KitInstallFailure.hubBusy);
      expect(st.detail, '3');
    });

    test('沒有進行中的 run → 照常 停 → 裝 → 起', () async {
      await update();
      expect(actions.log, ['stop', 'start']);
      expect(installer.installs, 1);
      expect(c.read(kitInstallsProvider)[KitId.hub]!.phase,
          KitInstallPhase.done);
    });

    test('查不出來（null）→ 照常更新，不擋', () async {
      runs.result = null;
      await update();
      expect(installer.installs, 1);
      expect(actions.log, ['stop', 'start']);
    });
  });

  group('HubActiveRunsApi.check 的退路', () {
    test('新端點可用 → 不逐房查', () async {
      final api = _SplitRunsApi(global: () async => const HubActiveRuns(2));
      final r = await api.check();
      expect(r?.count, 2);
      expect(api.roomCalls, 0);
    });

    test('新端點 404 → 退回逐房查', () async {
      final api = _SplitRunsApi(
        global: () async => throw const NotFoundException('not_found'),
        rooms: () async => const HubActiveRuns(1),
      );
      final r = await api.check();
      expect(r?.count, 1);
      expect(api.roomCalls, 1);
    });

    test('404 之後逐房也失敗 → 無法確認（null），不是 0', () async {
      final api = _SplitRunsApi(
        global: () async => throw const NotFoundException('not_found'),
        rooms: () async => throw const NetworkException(),
      );
      expect(await api.check(), isNull);
    });

    test('新端點是 404 以外的錯 → 不逐房查，無法確認', () async {
      final api = _SplitRunsApi(
        global: () async => throw const NetworkException(),
        rooms: () async => const HubActiveRuns(0),
      );
      expect(await api.check(), isNull);
      expect(api.roomCalls, 0);
    });
  });
}
