import 'dart:io';

import 'package:chatroom_app/core/platform/app_platform.dart';
import 'package:chatroom_app/state/kit_installer.dart';
import 'package:flutter_test/flutter_test.dart';

/// 從 Release 裝 kit 的那一層。
///
/// **不打真網路、不起真進程**：HTTP 與子進程都換成 fake，斷言的是
/// 「這一層自己做的判斷」——查不到 Release、下載炸掉、安裝器沒印 RESULT、
/// 沒有 Python 3.12 時，各自變成哪一種結果。
class _FakeHttp implements KitHttpClient {
  _FakeHttp({this.status = 200, this.body, this.onDownload});

  int status;
  Object? body;

  /// 下載時做什麼（丟例外＝下載失敗）。預設寫一個空檔案。
  Future<void> Function(String url, String savePath)? onDownload;

  final downloaded = <String>[];
  String? lastUrl;

  @override
  Future<(int, Object?)> getJson(String url) async {
    lastUrl = url;
    return (status, body);
  }

  @override
  Future<void> download(String url, String savePath,
      {void Function(int received, int total)? onProgress}) async {
    downloaded.add(url);
    onProgress?.call(50, 100);
    if (onDownload != null) return onDownload!(url, savePath);
    await File(savePath).create(recursive: true);
  }
}

/// 假的子進程。`python` 的回答由 [installerStdout] 決定，`powershell`
/// 的解壓則真的在磁碟上生出 `install.py`——後面那一步要驗的是
/// 「找不找得到那支腳本」，那必須是真的檔案。
class _FakeRunner implements KitProcessRunner {
  _FakeRunner({
    this.pythonVersion = 'Python 3.12.7',
    this.installerStdout = 'RESULT {"ok": true, "version": "1.2.3"}',
    this.installerExitCode = 0,
    this.installerStderr = '',
    this.nested = true,
  });

  String? pythonVersion;
  String installerStdout;
  int installerExitCode;
  String installerStderr;

  /// zip 裡帶不帶一層 `chatroom-*-kit/`。
  final bool nested;

  final calls = <List<String>>[];

  @override
  Future<ProcessResult> run(String executable, List<String> arguments,
      {String? workingDirectory}) async {
    calls.add([executable, ...arguments]);
    if (arguments.contains('--version')) {
      if (pythonVersion == null || executable != 'py') {
        return ProcessResult(0, 1, '', 'not found');
      }
      return ProcessResult(0, 0, pythonVersion, '');
    }
    if (executable == 'powershell') {
      final match =
          RegExp(r'-DestinationPath "([^"]+)"').firstMatch(arguments.last);
      final target = match!.group(1)!;
      final dir = nested ? '$target${Platform.pathSeparator}chatroom-kit' : target;
      await Directory(dir).create(recursive: true);
      await File('$dir${Platform.pathSeparator}install.py').writeAsString('#');
      return ProcessResult(0, 0, '', '');
    }
    return ProcessResult(0, installerExitCode, installerStdout, installerStderr);
  }
}

/// POSIX 版的假子進程：只認 [versions] 裡列的執行檔；`-c` 的解壓程式
/// 在磁碟上生出 `install.py`，其餘（跑安裝器）回成功。
class _PosixRunner implements KitProcessRunner {
  _PosixRunner({this.versions = const {}, this.extractFails});

  final Map<String, String> versions;
  final String? extractFails;
  final calls = <List<String>>[];

  @override
  Future<ProcessResult> run(String executable, List<String> arguments,
      {String? workingDirectory}) async {
    calls.add([executable, ...arguments]);
    if (arguments.contains('--version')) {
      final v = versions[executable];
      return v == null ? ProcessResult(0, 1, '', 'nf') : ProcessResult(0, 0, v, '');
    }
    if (arguments.contains('-c')) {
      if (extractFails != null) return ProcessResult(0, 1, '', extractFails);
      final target = arguments.last;
      await Directory(target).create(recursive: true);
      await File('$target${Platform.pathSeparator}install.py')
          .writeAsString('#');
      return ProcessResult(0, 0, '', '');
    }
    return ProcessResult(0, 0, 'RESULT {"ok": true, "version": "1.2.3"}', '');
  }
}

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('kit-install-test'));
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on Object {
      // 測試機上偶爾鎖著；清不掉不該讓測試變紅
    }
  });

  KitInstaller make(_FakeHttp http, _FakeRunner runner) => KitInstaller(
        http: http,
        processRunner: runner,
        installRoot: root.path,
        clock: () => DateTime(2026, 9, 19, 10, 30, 5),
        // 這份測試的 fake 是 Windows 形狀（py、powershell）；POSIX 的分支另有
        // 一組在檔案最後
        platform: AppPlatform.windows,
      );

  const releaseJson = {
    'tag_name': 'v1.2.3',
    'assets': [
      {
        'name': 'chatroom-hub-kit.zip',
        'browser_download_url': 'https://example.invalid/hub.zip',
      },
      {
        'name': 'chatroom-runner-kit.zip',
        'browser_download_url': 'https://example.invalid/runner.zip',
      },
    ],
  };

  group('查 Release', () {
    test('查得到 → 帶著三個資產回來', () async {
      final installer = make(_FakeHttp(body: releaseJson), _FakeRunner());
      final release = await installer.fetchRelease('1.2.3');

      expect(release, isNotNull);
      expect(release!.version, '1.2.3');
      expect(release.assetFor(KitId.hub), 'https://example.invalid/hub.zip');
      expect(release.assetFor(KitId.mcp), isNull,
          reason: '這個 Release 裡沒有 mcp 資產，不能生一個出來');
    });

    test('🔴 查不到（dev build）→ null，不退到 latest', () async {
      final http = _FakeHttp(status: 404, body: {'message': 'Not Found'});
      final installer = make(http, _FakeRunner());

      expect(await installer.fetchRelease('9.9.9'), isNull);
    });

    test('hotfix>0 查 v<版本>-hotfix<n>，hotfix=0 查 v<版本>', () {
      const base = 'https://api.github.com/repos/'
          'Unforgettableeternalproject/Chatroom/releases/tags/';
      expect(kitReleaseApiUrl('1.2.5'), '${base}v1.2.5');
      expect(kitReleaseApiUrl('1.2.5', hotfix: 0), '${base}v1.2.5');
      expect(kitReleaseApiUrl('1.2.5', hotfix: 1), '${base}v1.2.5-hotfix1');
    });

    test('rc>0 查 v<版本>-rc<n>', () {
      const base = 'https://api.github.com/repos/'
          'Unforgettableeternalproject/Chatroom/releases/tags/';
      expect(kitReleaseApiUrl('1.2.9', rc: 1), '${base}v1.2.9-rc1');
      expect(kitReleaseTag('1.2.9', rc: 2), 'v1.2.9-rc2');
      expect(kitReleaseTag('1.2.9'), 'v1.2.9');
    });

    test('fetchRelease 帶 rc 時實際請求 RC tag', () async {
      final http = _FakeHttp(status: 404, body: {'message': 'Not Found'});
      await make(http, _FakeRunner()).fetchRelease('1.2.9', rc: 1);
      expect(http.lastUrl, endsWith('/releases/tags/v1.2.9-rc1'));
    });

    test('fetchRelease 帶 hotfix 時實際請求熱修 tag', () async {
      final http = _FakeHttp(status: 404, body: {'message': 'Not Found'});
      await make(http, _FakeRunner()).fetchRelease('1.2.5', hotfix: 1);
      expect(http.lastUrl, endsWith('/releases/tags/v1.2.5-hotfix1'));
    });

    test('查的是自己那一版的 tag', () {
      expect(
        kitReleaseApiUrl('1.2.3'),
        'https://api.github.com/repos/'
        'Unforgettableeternalproject/Chatroom/releases/tags/v1.2.3',
      );
    });
  });

  group('RESULT 解析', () {
    test('撈最後一行 RESULT', () {
      final result = parseInstallResult(
        '安裝中…\n'
        'RESULT {"ok": false, "error": "舊的"}\n'
        'RESULT {"ok": true, "version": "1.2.3", "commit": "abc123", '
        '"kit_root": "C:/kit"}\n',
      );

      expect(result, isNotNull);
      expect(result!.ok, isTrue);
      expect(result.version, '1.2.3');
      expect(result.commit, 'abc123');
      expect(result.kitRoot, 'C:/kit');
    });

    test('🔴 沒有 RESULT → null（不是「成功但沒細節」）', () {
      expect(parseInstallResult('裝好了！'), isNull);
      expect(parseInstallResult(''), isNull);
    });

    test('RESULT 後面不是 JSON → 當作沒有', () {
      expect(parseInstallResult('RESULT 好了'), isNull);
    });

    test('config_written=false 要看得出來', () {
      final result =
          parseInstallResult('RESULT {"ok": true, "config_written": false}');
      expect(result!.configKept, isTrue);
    });
  });

  group('安裝', () {
    test('走完一輪：下載 → 解壓 → 跑 install.py --yes', () async {
      final http = _FakeHttp(body: releaseJson);
      final runner = _FakeRunner();
      final release = await make(http, runner).fetchRelease('1.2.3');

      final phases = <KitInstallPhase>[];
      final result = await make(http, runner).install(
        KitId.hub,
        release: release!,
        extraArgs: const ['--no-tunnel'],
        onProgress: (phase, _) => phases.add(phase),
      );

      expect(result.ok, isTrue);
      expect(result.version, '1.2.3');
      expect(phases, contains(KitInstallPhase.downloading));
      expect(phases, contains(KitInstallPhase.installing));

      final install = runner.calls.last;
      expect(install.first, 'py');
      expect(install, contains('--yes'));
      expect(install, contains('--no-tunnel'));
      expect(install.indexOf('--yes') < install.indexOf('--no-tunnel'), isTrue);
      expect(
        Directory('${root.path}${Platform.pathSeparator}hub-kit').existsSync(),
        isTrue,
      );
    });

    test('🔴 已經有一份 → 先備份成 .bak-<時間>，不直接覆蓋', () async {
      final sep = Platform.pathSeparator;
      final existing = Directory('${root.path}${sep}hub-kit')
        ..createSync(recursive: true);
      File('${existing.path}${sep}keep.txt').writeAsStringSync('舊的');

      final http = _FakeHttp(body: releaseJson);
      final release = await make(http, _FakeRunner()).fetchRelease('1.2.3');
      await make(http, _FakeRunner()).install(KitId.hub, release: release!);

      expect(
        File('${root.path}${sep}hub-kit.bak-20260919-103005${sep}keep.txt')
            .existsSync(),
        isTrue,
        reason: '舊的那一份是使用者的資料，不能無聲蓋掉',
      );
    });

    test('Release 裡沒有這包 → assetMissing', () async {
      final http = _FakeHttp(body: releaseJson);
      final release = await make(http, _FakeRunner()).fetchRelease('1.2.3');

      expect(
        () => make(http, _FakeRunner()).install(KitId.mcp, release: release!),
        throwsA(isA<KitInstallError>().having(
            (e) => e.reason, 'reason', KitInstallFailure.assetMissing)),
      );
    });

    test('🔴 沒有 Python 3.12 → pythonMissing，不往下走', () async {
      final http = _FakeHttp(body: releaseJson);
      final runner = _FakeRunner(pythonVersion: null);
      final release = await make(http, _FakeRunner()).fetchRelease('1.2.3');

      await expectLater(
        make(http, runner).install(KitId.hub, release: release!),
        throwsA(isA<KitInstallError>().having(
            (e) => e.reason, 'reason', KitInstallFailure.pythonMissing)),
      );
      expect(http.downloaded, isEmpty, reason: '裝不了就不要先下載 40MB');
    });

    test('python 在但版本低於 3.12 → 也算沒有', () async {
      final http = _FakeHttp(body: releaseJson);
      final runner = _FakeRunner(pythonVersion: 'Python 3.11.9');

      expect(await make(http, runner).findPython(), isNull);
    });

    test('3.13／3.14 也算有：判的是下限，跟安裝器的 check_python 一致', () async {
      for (final v in ['Python 3.13.2', 'Python 3.14.7']) {
        final runner = _FakeRunner(pythonVersion: v);
        expect(await make(_FakeHttp(body: releaseJson), runner).findPython(),
            isNotNull, reason: v);
      }
    });

    test('下載失敗 → download，而且不留半份 zip', () async {
      final http = _FakeHttp(
        body: releaseJson,
        onDownload: (_, _) => throw const SocketException('斷線'),
      );
      final release = await make(_FakeHttp(body: releaseJson), _FakeRunner())
          .fetchRelease('1.2.3');

      await expectLater(
        make(http, _FakeRunner()).install(KitId.hub, release: release!),
        throwsA(isA<KitInstallError>()
            .having((e) => e.reason, 'reason', KitInstallFailure.download)),
      );
      expect(
        File('${root.path}${Platform.pathSeparator}.downloads'
                '${Platform.pathSeparator}chatroom-hub-kit.zip')
            .existsSync(),
        isFalse,
      );
    });

    test('🔴 安裝器沒印 RESULT → 失敗，不當成功', () async {
      final http = _FakeHttp(body: releaseJson);
      final runner = _FakeRunner(
          installerStdout: '裝好了！', installerStderr: 'Traceback…');
      final release = await make(http, _FakeRunner()).fetchRelease('1.2.3');

      await expectLater(
        make(http, runner).install(KitId.hub, release: release!),
        throwsA(isA<KitInstallError>()
            .having((e) => e.reason, 'reason', KitInstallFailure.installer)
            .having((e) => e.detail, 'detail', contains('Traceback'))),
      );
    });

    test('RESULT ok=false → 把它的 error 帶出來', () async {
      final http = _FakeHttp(body: releaseJson);
      final runner = _FakeRunner(
        installerStdout: 'RESULT {"ok": false, "error": "埠被佔用"}',
        installerExitCode: 1,
      );
      final release = await make(http, _FakeRunner()).fetchRelease('1.2.3');

      await expectLater(
        make(http, runner).install(KitId.hub, release: release!),
        throwsA(isA<KitInstallError>()
            .having((e) => e.detail, 'detail', '埠被佔用')),
      );
    });

    test('zip 沒有多包一層也找得到 install.py', () async {
      final http = _FakeHttp(body: releaseJson);
      final runner = _FakeRunner(nested: false);
      final release = await make(http, _FakeRunner()).fetchRelease('1.2.3');

      final result = await make(http, runner).install(KitId.hub, release: release!);
      expect(result.ok, isTrue);
    });
  });
  group('POSIX 平台', () {
    KitInstaller makePosix(AppPlatform platform, _FakeHttp http,
            _PosixRunner runner) =>
        KitInstaller(
          http: http,
          processRunner: runner,
          installRoot: root.path,
          clock: () => DateTime(2026, 9, 19, 10, 30, 5),
          platform: platform,
        );

    test('候選：Windows 順序不動；POSIX 有 python3.12 與 python3', () {
      expect(pythonCandidatesFor(AppPlatform.windows).first.executable, 'py');
      expect(pythonCandidatesFor(AppPlatform.windows).first.prefixArgs, ['-3']);
      for (final p in [AppPlatform.macos, AppPlatform.linux]) {
        final names = pythonCandidatesFor(p).map((c) => c.executable).toList();
        expect(names, containsAllInOrder(['python3.12', 'python3']));
        expect(names, isNot(contains('py')));
      }
    });

    test('🔴 macOS 候選含 Homebrew／python.org 絕對路徑，排在裸名前面；'
        '不碰 /usr/bin/python3 轉接殼', () {
      final names = pythonCandidatesFor(AppPlatform.macos)
          .map((c) => c.executable)
          .toList();
      expect(names, contains('/opt/homebrew/bin/python3.12'));
      expect(names, contains('/usr/local/bin/python3'));
      expect(
          names.any((n) => n.startsWith('/Library/Frameworks/Python.framework')),
          isTrue);
      expect(names, isNot(contains('/usr/bin/python3')));
      expect(names.indexOf('/opt/homebrew/bin/python3.12') <
          names.indexOf('python3.12'), isTrue);
    });

    test('Linux：python3.12 不在就退到 python3', () async {
      final runner = _PosixRunner(versions: {'python3': 'Python 3.13.1'});
      final python = await makePosix(
              AppPlatform.linux, _FakeHttp(body: releaseJson), runner)
          .findPython();
      expect(python!.executable, 'python3');
    });

    test('macOS：PATH 裡什麼都沒有，仍找得到 Homebrew 的 Python', () async {
      final runner = _PosixRunner(
          versions: {'/opt/homebrew/bin/python3.12': 'Python 3.12.7'});
      final python = await makePosix(
              AppPlatform.macos, _FakeHttp(body: releaseJson), runner)
          .findPython();
      expect(python!.executable, '/opt/homebrew/bin/python3.12');
    });

    test('🔴 POSIX 解壓走 Python 的 zipfile 程式、不叫 powershell；'
        'install.py 也用同一支 Python 跑', () async {
      final http = _FakeHttp(body: releaseJson);
      final runner = _PosixRunner(versions: {'python3.12': 'Python 3.12.7'});
      final installer = makePosix(AppPlatform.linux, http, runner);
      final release = await installer.fetchRelease('1.2.3');

      final result = await installer.install(KitId.hub,
          release: release!, extraArgs: const ['--no-tunnel']);
      expect(result.ok, isTrue);

      expect(runner.calls.any((c) => c.first == 'powershell'), isFalse);
      final extract = runner.calls.firstWhere((c) => c.contains('-c'));
      expect(extract.first, 'python3.12');
      expect(extract[extract.indexOf('-c') + 1], kZipExtractScript);
      expect(extract.last, endsWith('hub-kit'));

      final install = runner.calls.last;
      expect(install.first, 'python3.12');
      expect(install, containsAllInOrder(['--yes', '--no-tunnel']));
      expect(install.any((a) => a.endsWith('install.py')), isTrue);
    });

    test('解壓程式：保留執行位元、擋 zip-slip', () {
      expect(kZipExtractScript, contains('external_attr >> 16'));
      expect(kZipExtractScript, contains('os.chmod'));
      expect(kZipExtractScript, contains('unsafe path in zip'));
    });

    test('POSIX 解壓失敗 → extract，帶 stderr', () async {
      final http = _FakeHttp(body: releaseJson);
      final runner = _PosixRunner(
          versions: {'python3.12': 'Python 3.12.7'},
          extractFails: 'unsafe path in zip: ../x');
      final installer = makePosix(AppPlatform.macos, http, runner);
      final release = await installer.fetchRelease('1.2.3');

      await expectLater(
        installer.install(KitId.hub, release: release!),
        throwsA(isA<KitInstallError>()
            .having((e) => e.reason, 'reason', KitInstallFailure.extract)
            .having((e) => e.detail, 'detail', contains('unsafe path'))),
      );
    });
  });
}
