import 'dart:io';

import 'package:chatroom_app/core/config/build_info.dart';
import 'package:chatroom_app/state/app_updater.dart';
import 'package:chatroom_app/state/kit_installer.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// App 的檢查更新與自我更新。
///
/// **不打真網路、不起真進程、不碰真的安裝目錄**：HTTP、子進程、啟動器、
/// 結束 App 全部換成 fake，下載根目錄與安裝目錄都是臨時資料夾。
class _FakeHttp implements KitHttpClient {
  int status = 200;
  Object? body;

  /// 查詢時丟的例外（＝連不上）。
  Object? getError;

  /// 下載時寫進檔案的內容。
  List<int> bytes = const [1, 2, 3, 4];
  Object? downloadError;

  final requested = <String>[];
  final downloaded = <String>[];

  @override
  Future<(int, Object?)> getJson(String url) async {
    requested.add(url);
    if (getError != null) throw getError!;
    return (status, body);
  }

  @override
  Future<void> download(String url, String savePath,
      {void Function(int received, int total)? onProgress}) async {
    downloaded.add(url);
    if (downloadError != null) throw downloadError!;
    await File(savePath).writeAsBytes(bytes);
    onProgress?.call(bytes.length, -1);
  }
}

/// 假的 PowerShell：算雜湊的那條指令回 [hash]，`Expand-Archive` 真的在磁碟上
/// 生出檔案——「解出來的東西完不完整」要驗的是真的檔案。
class _FakeRunner implements KitProcessRunner {
  String hash = _goodHash;
  bool writeExe = true;
  bool writeSo = true;
  int extractExitCode = 0;

  final commands = <String>[];

  @override
  Future<ProcessResult> run(String executable, List<String> arguments,
      {String? workingDirectory}) async {
    final command = arguments.last;
    commands.add(command);
    if (command.contains('SHA256')) {
      // 真的 BitConverter 印的是大寫、每個位元組之間一個 `-`
      final bytes = RegExp('..').allMatches(hash.toUpperCase());
      return ProcessResult(
          0, 0, '${bytes.map((m) => m.group(0)).join('-')}\r\n', '');
    }
    if (command.contains('Expand-Archive')) {
      if (extractExitCode != 0) {
        return ProcessResult(0, extractExitCode, '', 'bad zip');
      }
      final target =
          RegExp(r'-DestinationPath "([^"]+)"').firstMatch(command)!.group(1)!;
      if (writeExe) await File(_join(target, ['Chatroom.exe'])).writeAsString('new');
      if (writeSo) {
        final so = File(_join(target, ['data', 'app.so']));
        await so.parent.create(recursive: true);
        await so.writeAsString('new');
      }
      return ProcessResult(0, 0, '', '');
    }
    return ProcessResult(0, 0, '', '');
  }
}

class _FakeLauncher implements AppUpdateLauncher {
  _FakeLauncher(this.events);

  final List<String> events;
  Object? error;
  String? executable;
  List<String> arguments = const [];
  String? workingDirectory;

  @override
  Future<void> start(String executable, List<String> arguments,
      {String? workingDirectory}) async {
    if (error != null) throw error!;
    this.executable = executable;
    this.arguments = arguments;
    this.workingDirectory = workingDirectory;
    events.add('launch');
  }
}

final _goodHash = 'ab' * 32;

String _join(String base, List<String> parts) =>
    [base, ...parts].join(Platform.pathSeparator);

const _release = BuildInfo(version: '1.2.5', commit: 'abc123def456', builtAt: '');

Map<String, dynamic> _latest(
  String tag, {
  String? assetName,
  int? size,
  String? digest,
  bool withAsset = true,
}) =>
    {
      'tag_name': tag,
      'html_url': 'https://example.invalid/releases/$tag',
      'assets': [
        {
          'name': 'chatroom-hub-kit.zip',
          'browser_download_url': 'https://example.invalid/hub.zip',
        },
        if (withAsset)
          {
            'name': assetName ?? 'chatroom-app-$tag-windows-x64.zip',
            'browser_download_url': 'https://example.invalid/app.zip',
            'size': ?size,
            'digest': ?digest,
          },
      ],
    };

/// 目錄底下每個檔案的相對路徑與內容。
Map<String, String> _snapshot(String dir) {
  final root = Directory(dir);
  return {
    for (final f in root.listSync(recursive: true).whereType<File>())
      f.path.substring(root.path.length): f.readAsStringSync(),
  };
}

void main() {
  group('版本比較', () {
    test('解析 v 前綴、缺後綴與 hotfix', () {
      expect(AppVersion.tryParse('v1.2.5'), const AppVersion(1, 2, 5));
      expect(AppVersion.tryParse('1.2.5'), const AppVersion(1, 2, 5));
      expect(
          AppVersion.tryParse('v1.2.5-hotfix2'), const AppVersion(1, 2, 5, 2));
      expect(AppVersion.tryParse('v1.2.5')!.hotfix, 0);
    });

    test('解析不了回 null', () {
      for (final bad in [
        '',
        'latest',
        'v1.2',
        'v1.2.5-rc1',
        'v1.2.5-hotfix',
        'v1.2.5-hotfix2-x',
        '1.2.5+1',
      ]) {
        expect(AppVersion.tryParse(bad), isNull, reason: bad);
      }
    });

    test('三態：較新／相同／較舊', () {
      expect(compareAppVersions('v1.2.6', '1.2.5'), AppVersionOrder.newer);
      expect(compareAppVersions('v1.2.5', '1.2.5'), AppVersionOrder.same);
      expect(compareAppVersions('v1.2.4', '1.2.5'), AppVersionOrder.older);
      // 數字比，不是字串比
      expect(compareAppVersions('v1.10.0', 'v1.9.9'), AppVersionOrder.newer);
      expect(compareAppVersions('v2.0.0', 'v1.99.99'), AppVersionOrder.newer);
    });

    test('hotfix 排在同版號之後、下一版之前', () {
      expect(compareAppVersions('v1.2.5-hotfix1', 'v1.2.5'),
          AppVersionOrder.newer);
      expect(compareAppVersions('v1.2.5-hotfix2', 'v1.2.5-hotfix1'),
          AppVersionOrder.newer);
      expect(compareAppVersions('v1.2.5-hotfix10', 'v1.2.5-hotfix9'),
          AppVersionOrder.newer);
      expect(compareAppVersions('v1.2.5', 'v1.2.5-hotfix1'),
          AppVersionOrder.older);
      expect(compareAppVersions('v1.2.6', 'v1.2.5-hotfix3'),
          AppVersionOrder.newer);
    });

    test('任一邊解析不了＝null，不是相同', () {
      expect(compareAppVersions('nightly', '1.2.5'), isNull);
      expect(compareAppVersions('v1.2.5', ''), isNull);
    });

    test('App 自己的版本帶 BuildInfo 的 hotfix', () {
      const info = BuildInfo(
          version: '1.2.5', commit: 'abc', builtAt: '', hotfix: 2);
      expect(AppVersion.ofBuild(info), const AppVersion(1, 2, 5, 2));
      expect(AppVersion.ofBuild(_release), const AppVersion(1, 2, 5));
    });
  });

  group('Release 資產', () {
    test('只認 chatroom-app-*-windows-x64.zip，digest 去掉前綴轉小寫', () {
      final r = AppRelease.fromJson(_latest('v1.2.6',
          size: 4, digest: 'sha256:${_goodHash.toUpperCase()}'))!;
      expect(r.tag, 'v1.2.6');
      expect(r.assetName, 'chatroom-app-v1.2.6-windows-x64.zip');
      expect(r.downloadUrl, 'https://example.invalid/app.zip');
      expect(r.htmlUrl, 'https://example.invalid/releases/v1.2.6');
      expect(r.size, 4);
      expect(r.sha256, _goodHash);
    });

    test('沒有 size／digest 就是 null', () {
      final r = AppRelease.fromJson(_latest('v1.2.6'))!;
      expect(r.size, isNull);
      expect(r.sha256, isNull);
    });

    test('沒有對應資產、資產名帶路徑分隔字元都回 null', () {
      expect(AppRelease.fromJson(_latest('v1.2.6', withAsset: false)), isNull);
      expect(
          AppRelease.fromJson(_latest('v1.2.6',
              assetName: r'chatroom-app-..\..\x-windows-x64.zip')),
          isNull);
      expect(AppRelease.fromJson(const {'tag_name': 'v1.2.6'}), isNull);
      expect(AppRelease.fromJson('nope'), isNull);
    });
  });

  group('Notifier', () {
    late Directory temp;
    late String updateRoot;
    late String installDir;
    late String exePath;
    late _FakeHttp http;
    late _FakeRunner runner;
    late _FakeLauncher launcher;
    late List<String> events;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('app-updater-test-');
      updateRoot = _join(temp.path, ['root']);
      installDir = _join(temp.path, ['install']);
      exePath = _join(installDir, ['Chatroom.exe']);
      File(exePath)
        ..createSync(recursive: true)
        ..writeAsStringSync('old');
      File(_join(installDir, ['data', 'app.so']))
        ..createSync(recursive: true)
        ..writeAsStringSync('old');
      http = _FakeHttp();
      runner = _FakeRunner();
      events = [];
      launcher = _FakeLauncher(events);
    });

    tearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } on Object {
        // 清不掉不影響測試結果
      }
    });

    ProviderContainer make({
      BuildInfo info = _release,
      bool windows = true,
      String? install,
    }) {
      final container = ProviderContainer(overrides: [
        appUpdatePlatformProvider.overrideWithValue(windows),
        appBuildInfoProvider.overrideWithValue(info),
        kitHttpClientProvider.overrideWithValue(http),
        kitProcessRunnerProvider.overrideWithValue(runner),
        appUpdateRootProvider.overrideWithValue(updateRoot),
        appExePathProvider.overrideWithValue(exePath),
        if (install != null) appInstallDirProvider.overrideWithValue(install),
        appPidProvider.overrideWithValue(4242),
        appUpdateLauncherProvider.overrideWithValue(launcher),
        appQuitProvider.overrideWithValue(() async => events.add('quit')),
      ]);
      addTearDown(container.dispose);
      return container;
    }

    String tagDir(String tag) =>
        _join(updateRoot, ['.downloads', 'app-update', tag]);

    group('停用條件', () {
      test('Release 版在 Windows 上啟用', () {
        expect(make().read(appUpdateEnabledProvider), isTrue);
      });

      test('dev build（沒有 commit）停用', () {
        const dev = BuildInfo(version: '1.0.0', commit: '', builtAt: '');
        expect(make(info: dev).read(appUpdateEnabledProvider), isFalse);
      });

      test('dirty build 停用', () {
        const dirty =
            BuildInfo(version: '1.2.5', commit: 'abc123-dirty', builtAt: '');
        expect(make(info: dirty).read(appUpdateEnabledProvider), isFalse);
      });

      test('非 Windows 停用', () {
        expect(make(windows: false).read(appUpdateEnabledProvider), isFalse);
      });

      test('停用時 check 不發請求、狀態不動', () async {
        http.body = _latest('v9.9.9');
        final c = make(windows: false);
        await c.read(appUpdateProvider.notifier).check();
        expect(http.requested, isEmpty);
        expect(c.read(appUpdateProvider).phase, AppUpdatePhase.idle);
      });
    });

    group('查詢', () {
      Future<AppUpdateState> check({BuildInfo info = _release}) async {
        final c = make(info: info);
        await c.read(appUpdateProvider.notifier).check();
        return c.read(appUpdateProvider);
      }

      test('問的是 latest', () async {
        http.body = _latest('v1.2.6');
        await check();
        expect(http.requested, [
          'https://api.github.com/repos/$kKitReleaseRepo/releases/latest',
        ]);
      });

      test('200 有新版 → available，帶 tag', () async {
        http.body = _latest('v1.2.6');
        final s = await check();
        expect(s.phase, AppUpdatePhase.available);
        expect(s.tag, 'v1.2.6');
      });

      test('200 同版 → upToDate', () async {
        http.body = _latest('v1.2.5');
        expect((await check()).phase, AppUpdatePhase.upToDate);
      });

      test('200 較舊 → upToDate', () async {
        http.body = _latest('v1.2.4');
        expect((await check()).phase, AppUpdatePhase.upToDate);
      });

      test('同版號的熱修算新版；自己已是那個熱修就不算', () async {
        http.body = _latest('v1.2.5-hotfix2');
        expect((await check()).phase, AppUpdatePhase.available);

        const hotfix2 = BuildInfo(
            version: '1.2.5', commit: 'abc123', builtAt: '', hotfix: 2);
        expect((await check(info: hotfix2)).phase, AppUpdatePhase.upToDate);
      });

      // 以下每一種都是「查不到」。它們若被呈現成「已是最新」，使用者會
      // 以為自己不用更新——所以兩個斷言都要：是 checkFailed，且不是 upToDate。
      void expectCheckFailed(AppUpdateState s) {
        expect(s.phase, isNot(AppUpdatePhase.upToDate));
        expect(s.phase, AppUpdatePhase.checkFailed);
      }

      test('404 → checkFailed', () async {
        http
          ..status = 404
          ..body = {'message': 'Not Found'};
        expectCheckFailed(await check());
      });

      test('403（rate limit）即使 body 像一份 Release 也 → checkFailed', () async {
        http
          ..status = 403
          ..body = _latest('v1.2.5');
        expectCheckFailed(await check());
      });

      test('例外（沒網路）→ checkFailed', () async {
        http.getError = const SocketException('offline');
        expectCheckFailed(await check());
      });

      test('沒有對應資產 → checkFailed', () async {
        http.body = _latest('v1.2.5', withAsset: false);
        expectCheckFailed(await check());
      });

      test('tag 解析不了 → checkFailed', () async {
        http.body = _latest('nightly-2026');
        expectCheckFailed(await check());
      });

      test('body 不是物件 → checkFailed', () async {
        http.body = 'oops';
        expectCheckFailed(await check());
      });

      test('自己的版本解析不了 → checkFailed', () async {
        http.body = _latest('v1.2.5');
        const odd =
            BuildInfo(version: 'custom', commit: 'abc123', builtAt: '');
        expectCheckFailed(await check(info: odd));
      });
    });

    group('下載與驗證', () {
      Future<ProviderContainer> available(Map<String, dynamic> latest,
          {String? install}) async {
        http.body = latest;
        final c = make(install: install);
        await c.read(appUpdateProvider.notifier).check();
        expect(c.read(appUpdateProvider).phase, AppUpdatePhase.available);
        return c;
      }

      test('成功 → ready：staged 與腳本都在、zip 已刪、安裝目錄沒動', () async {
        final before = _snapshot(installDir);
        final c = await available(
            _latest('v1.2.6', size: 4, digest: 'sha256:$_goodHash'));
        final phases = <AppUpdatePhase>[];
        c.listen(appUpdateProvider, (_, next) => phases.add(next.phase));

        await c.read(appUpdateProvider.notifier).download();

        final s = c.read(appUpdateProvider);
        expect(s.phase, AppUpdatePhase.ready, reason: s.detail);
        expect(s.tag, 'v1.2.6');
        expect(phases.first, AppUpdatePhase.downloading);
        expect(http.downloaded, ['https://example.invalid/app.zip']);
        final dir = tagDir('v1.2.6');
        expect(File(_join(dir, ['staged', 'Chatroom.exe'])).existsSync(), isTrue);
        expect(
            File(_join(dir, ['staged', 'data', 'app.so'])).existsSync(), isTrue);
        expect(File(_join(dir, ['apply-update.ps1'])).readAsStringSync(),
            kApplyUpdateScript);
        expect(
            File(_join(dir, ['chatroom-app-v1.2.6-windows-x64.zip']))
                .existsSync(),
            isFalse);
        expect(_snapshot(installDir), before);
      });

      test('沒有 size 與 digest 就不比對，也不去算雜湊', () async {
        final c = await available(_latest('v1.2.6'));
        await c.read(appUpdateProvider.notifier).download();
        expect(c.read(appUpdateProvider).phase, AppUpdatePhase.ready);
        expect(runner.commands.where((x) => x.contains('SHA256')),
            isEmpty);
      });

      /// 失敗的共同後果：狀態是 failed、這次下載的東西清掉、安裝目錄原樣。
      Future<void> expectFailed(
        Map<String, dynamic> latest,
        AppUpdateFailure reason,
      ) async {
        final before = _snapshot(installDir);
        final c = await available(latest);
        await c.read(appUpdateProvider.notifier).download();
        final s = c.read(appUpdateProvider);
        expect(s.phase, AppUpdatePhase.failed);
        expect(s.failure, reason);
        expect(Directory(tagDir('v1.2.6')).existsSync(), isFalse);
        expect(_snapshot(installDir), before);
        // 失敗後不能直接重啟
        await c.read(appUpdateProvider.notifier).restart();
        expect(events, isEmpty);
      }

      test('size 不符 → failed', () async {
        await expectFailed(
            _latest('v1.2.6', size: 999), AppUpdateFailure.sizeMismatch);
      });

      test('digest 不符 → failed', () async {
        runner.hash = 'cd' * 32;
        await expectFailed(_latest('v1.2.6', digest: 'sha256:$_goodHash'),
            AppUpdateFailure.digestMismatch);
      });

      test('缺 Chatroom.exe → failed', () async {
        runner.writeExe = false;
        await expectFailed(_latest('v1.2.6'), AppUpdateFailure.incomplete);
      });

      test(r'缺 data\app.so → failed', () async {
        runner.writeSo = false;
        await expectFailed(_latest('v1.2.6'), AppUpdateFailure.incomplete);
      });

      test('解壓失敗 → failed', () async {
        runner.extractExitCode = 1;
        await expectFailed(_latest('v1.2.6'), AppUpdateFailure.extract);
      });

      test('下載丟例外 → failed', () async {
        http.downloadError = const SocketException('reset');
        await expectFailed(_latest('v1.2.6'), AppUpdateFailure.download);
      });

      test('安裝目錄寫不進去 → failed，而且根本不下載', () async {
        // 相對路徑過不了寫入探針，各平台都一樣
        final c = await available(_latest('v1.2.6'), install: 'not-absolute');
        await c.read(appUpdateProvider.notifier).download();
        final s = c.read(appUpdateProvider);
        expect(s.phase, AppUpdatePhase.failed);
        expect(s.failure, AppUpdateFailure.notWritable);
        expect(http.downloaded, isEmpty);
      });

      test('開始下載時清掉上一份更新留下的東西', () async {
        final old = File(_join(tagDir('v1.2.5'), ['backup', 'Chatroom.exe']))
          ..createSync(recursive: true);
        final c = await available(_latest('v1.2.6'));
        await c.read(appUpdateProvider.notifier).download();
        expect(old.existsSync(), isFalse);
        expect(Directory(tagDir('v1.2.5')).existsSync(), isFalse);
      });
    });

    group('重新啟動', () {
      Future<ProviderContainer> ready() async {
        http.body = _latest('v1.2.6');
        final c = make();
        await c.read(appUpdateProvider.notifier).check();
        await c.read(appUpdateProvider.notifier).download();
        expect(c.read(appUpdateProvider).phase, AppUpdatePhase.ready);
        return c;
      }

      test('先起腳本、之後才結束 App', () async {
        final c = await ready();
        await c.read(appUpdateProvider.notifier).restart();
        expect(events, ['launch', 'quit']);
        expect(c.read(appUpdateProvider).phase, AppUpdatePhase.applying);
      });

      test('腳本收到的參數', () async {
        final c = await ready();
        await c.read(appUpdateProvider.notifier).restart();
        final dir = tagDir('v1.2.6');
        expect(launcher.executable, 'powershell');
        expect(launcher.workingDirectory, dir);
        expect(launcher.arguments, [
          '-NoProfile',
          '-NonInteractive',
          '-WindowStyle',
          'Hidden',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          _join(dir, ['apply-update.ps1']),
          '-AppDir',
          installDir,
          '-StagedDir',
          _join(dir, ['staged']),
          '-BackupDir',
          _join(dir, ['backup']),
          '-ExePath',
          exePath,
          '-WaitPid',
          '4242',
        ]);
        // 測試用的開關不可以出現在正式路徑上
        expect(launcher.arguments, isNot(contains('-NoRelaunch')));
      });

      test('腳本起不來 → failed，App 不結束', () async {
        final c = await ready();
        launcher.error = const ProcessException('powershell', []);
        await c.read(appUpdateProvider.notifier).restart();
        final s = c.read(appUpdateProvider);
        expect(s.phase, AppUpdatePhase.failed);
        expect(s.failure, AppUpdateFailure.launch);
        expect(events, isEmpty);
      });

      test('還沒 ready 時 restart 什麼都不做', () async {
        http.body = _latest('v1.2.6');
        final c = make();
        await c.read(appUpdateProvider.notifier).check();
        await c.read(appUpdateProvider.notifier).restart();
        expect(events, isEmpty);
        expect(c.read(appUpdateProvider).phase, AppUpdatePhase.available);
      });
    });
  });

  test('更新腳本本體是純 ASCII', () {
    expect(kApplyUpdateScript.codeUnits.every((c) => c < 128), isTrue);
  });
}
