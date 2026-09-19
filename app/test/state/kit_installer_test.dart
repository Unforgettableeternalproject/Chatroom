import 'dart:io';

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

  @override
  Future<(int, Object?)> getJson(String url) async => (status, body);

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

    test('python 在但版本不是 3.12 → 也算沒有', () async {
      final http = _FakeHttp(body: releaseJson);
      final runner = _FakeRunner(pythonVersion: 'Python 3.11.9');

      expect(await make(http, runner).findPython(), isNull);
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
}
