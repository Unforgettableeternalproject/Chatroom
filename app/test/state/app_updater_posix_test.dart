import 'dart:io';

import 'package:chatroom_app/core/platform/app_platform.dart';
import 'package:chatroom_app/state/app_update_posix.dart';
import 'package:chatroom_app/state/app_updater.dart';
import 'package:chatroom_app/state/kit_installer.dart';
import 'package:flutter_test/flutter_test.dart';

/// macOS／Linux 的自我更新。跑在 Windows 上：平台注入、子進程換 fake；
/// 腳本本身則用真的 `sh`（Git Bash）跑，找不到 sh 就略過那幾條。

class _Http implements KitHttpClient {
  @override
  Future<(int, Object?)> getJson(String url) async => (404, null);

  @override
  Future<void> download(String url, String savePath,
      {void Function(int received, int total)? onProgress}) async {
    await File(savePath).create(recursive: true);
    await File(savePath).writeAsString('zip');
  }
}

class _Runner implements KitProcessRunner {
  _Runner({this.nested = false, this.createFiles = true});

  final bool nested;
  final bool createFiles;
  final calls = <List<String>>[];

  @override
  Future<ProcessResult> run(String executable, List<String> arguments,
      {String? workingDirectory}) async {
    calls.add([executable, ...arguments]);
    if (executable == 'shasum' || executable == 'sha256sum') {
      return ProcessResult(0, 0, 'ab' * 32 + '  file\n', '');
    }
    if (createFiles && (executable == 'ditto' || executable == 'tar')) {
      var target = executable == 'ditto' ? arguments.last : arguments.last;
      if (nested) target = '$target/bundle';
      final files = executable == 'ditto'
          ? ['Chatroom.app/Contents/MacOS/Chatroom']
          : ['chatroom', 'lib/libapp.so'];
      for (final f in files) {
        final file = File('$target/$f');
        await file.create(recursive: true);
        await file.writeAsString('x');
      }
    }
    return ProcessResult(0, 0, '', '');
  }
}

String? _findSh() {
  for (final c in ['sh', 'bash']) {
    try {
      final r = Process.runSync(c, ['-c', 'echo ok']);
      if (r.exitCode == 0 && '${r.stdout}'.trim() == 'ok') return c;
    } on Object {
      continue;
    }
  }
  return null;
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('upd-posix'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on Object {
      // 清不掉不影響結果
    }
  });

  test('資產名：三平台各認自己那個，不認別人的', () {
    expect(appAssetSuffixFor(AppPlatform.windows), '-windows-x64.zip');
    expect(appAssetSuffixFor(AppPlatform.macos), '-macos-universal.zip');
    expect(appAssetSuffixFor(AppPlatform.linux), '-linux-x64.tar.gz');

    Map<String, Object?> release(List<String> names) => {
          'tag_name': 'v1.2.9',
          'assets': [
            for (final n in names)
              {'name': n, 'browser_download_url': 'https://x.invalid/$n'}
          ],
        };
    final all = release([
      'chatroom-app-v1.2.9-windows-x64.zip',
      'chatroom-app-v1.2.9-macos-universal.zip',
      'chatroom-app-v1.2.9-linux-x64.tar.gz',
    ]);
    expect(AppRelease.fromJson(all)!.assetName,
        'chatroom-app-v1.2.9-windows-x64.zip',
        reason: '預設仍是 Windows');
    expect(AppRelease.fromJson(all, platform: AppPlatform.macos)!.assetName,
        'chatroom-app-v1.2.9-macos-universal.zip');
    expect(AppRelease.fromJson(all, platform: AppPlatform.linux)!.assetName,
        'chatroom-app-v1.2.9-linux-x64.tar.gz');
    expect(
        AppRelease.fromJson(release(['chatroom-app-v1.2.9-windows-x64.zip']),
            platform: AppPlatform.macos),
        isNull);
  });

  test('macBundlePath 與 selfUpdateBlocker', () {
    expect(macBundlePath('/Applications/Chatroom.app/Contents/MacOS/Chatroom'),
        '/Applications/Chatroom.app');
    expect(macBundlePath('/opt/chatroom/chatroom'), isNull);

    AppUpdateBlocker? blocker(AppPlatform p, String exe,
            [Map<String, String> env = const {}]) =>
        selfUpdateBlocker(platform: p, exePath: exe, environment: env);
    expect(blocker(AppPlatform.macos, '/Applications/Chatroom.app/Contents/MacOS/Chatroom'),
        isNull);
    expect(
        blocker(AppPlatform.macos,
            '/private/var/folders/x/AppTranslocation/ABC/d/Chatroom.app/Contents/MacOS/Chatroom'),
        AppUpdateBlocker.translocated);
    expect(blocker(AppPlatform.macos, '/opt/x/chatroom'),
        AppUpdateBlocker.notInBundle);
    expect(blocker(AppPlatform.linux, '/opt/c/chatroom'), isNull);
    expect(blocker(AppPlatform.linux, '/tmp/.mount_x/chatroom', {'APPIMAGE': '/home/a/C.AppImage'}),
        AppUpdateBlocker.appImage);
    expect(blocker(AppPlatform.windows, r'C:\a\Chatroom.exe', {'APPIMAGE': 'x'}),
        isNull);
  });

  test('命令組裝：路徑含空白也是單一個位置參數', () {
    final mac = posixApplyUpdateCommand(
      platform: AppPlatform.macos,
      scriptPath: '/u/Library/Application Support/UEP/Chatroom/.downloads/app-update/v1/apply-update.sh',
      stagedDir: '/u/Library/Application Support/UEP/Chatroom/.downloads/app-update/v1/staged',
      backupDir: '/u/Library/Application Support/UEP/Chatroom/.downloads/app-update/v1/backup',
      installDir: '/Applications',
      exePath: '/Applications/Chatroom.app/Contents/MacOS/Chatroom',
      waitPid: 42,
    );
    expect(mac.executable, '/bin/sh');
    expect(mac.arguments[1], '/Applications/Chatroom.app');
    expect(mac.arguments[2], endsWith('/staged/Chatroom.app'));
    expect(mac.arguments.last, '42');
    expect(mac.arguments.length, 5);

    final linux = posixApplyUpdateCommand(
      platform: AppPlatform.linux,
      scriptPath: '/s/apply-update.sh',
      stagedDir: '/s/staged',
      backupDir: '/s/backup',
      installDir: '/opt/chatroom',
      exePath: '/opt/chatroom/chatroom',
      waitPid: 7,
    );
    expect(linux.arguments,
        ['/s/apply-update.sh', '/opt/chatroom', '/s/staged', '/s/backup', '/opt/chatroom/chatroom', '7']);
  });

  group('AppUpdater.download', () {
    AppRelease release(String name) => AppRelease(
          tag: 'v1.2.9',
          assetName: name,
          downloadUrl: 'https://x.invalid/$name',
          sha256: 'ab' * 32,
        );

    test('macOS：ditto 解壓、shasum 驗證、寫出 LF 的 .sh', () async {
      final runner = _Runner();
      final updater = AppUpdater(
          http: _Http(),
          processRunner: runner,
          updateRoot: tmp.path,
          installDir: tmp.path,
          platform: AppPlatform.macos);
      final pkg = await updater
          .download(release('chatroom-app-v1.2.9-macos-universal.zip'));

      expect(runner.calls.map((c) => c.first), containsAll(['shasum', 'ditto']));
      expect(runner.calls.any((c) => c.first == 'powershell'), isFalse);
      final ditto = runner.calls.firstWhere((c) => c.first == 'ditto');
      expect(ditto.sublist(1, 3), ['-x', '-k']);
      expect(pkg.scriptPath, endsWith('apply-update.sh'));
      final text = File(pkg.scriptPath).readAsStringSync();
      expect(text, startsWith('#!/bin/sh'));
      expect(text.contains('\r'), isFalse);
    });

    test('Linux：tar 解壓；多包一層 bundle/ 也找得到', () async {
      final runner = _Runner(nested: true);
      final updater = AppUpdater(
          http: _Http(),
          processRunner: runner,
          updateRoot: tmp.path,
          installDir: tmp.path,
          platform: AppPlatform.linux);
      final pkg = await updater
          .download(release('chatroom-app-v1.2.9-linux-x64.tar.gz'));

      final tar = runner.calls.firstWhere((c) => c.first == 'tar');
      expect(tar.sublist(1, 2), ['-xzf']);
      expect(tar.contains('-C'), isTrue);
      expect(pkg.stagedDir.replaceAll(r'\', '/'), endsWith('/staged/bundle'));
      expect(runner.calls.first.first, 'sha256sum');
    });

    test('🔴 缺執行檔 → incomplete，不寫腳本', () async {
      final updater = AppUpdater(
          http: _Http(),
          processRunner: _Runner(createFiles: false),
          updateRoot: tmp.path,
          installDir: tmp.path,
          platform: AppPlatform.macos);
      await expectLater(
        updater.download(release('chatroom-app-v1.2.9-macos-universal.zip')),
        throwsA(isA<AppUpdateError>()
            .having((e) => e.reason, 'reason', AppUpdateFailure.incomplete)),
      );
    });
  });

  group('腳本（真的 sh）', () {
    final sh = _findSh();
    final skip = sh == null ? '這台機器沒有 sh' : null;

    String p(String path) => path.replaceAll(r'\', '/');

    Future<ProcessResult> runScript(String script, List<String> args,
        {Map<String, String> env = const {}}) async {
      final file = File('${tmp.path}/apply-update.sh');
      await file.writeAsString(script);
      return Process.run(sh!, [p(file.path), ...args],
          environment: {'CHATROOM_UPDATE_NO_RELAUNCH': '1', ...env});
    }

    String log() => File('${tmp.path}/apply-update.log').readAsStringSync();

    test('macOS：整包換掉、舊的進 backup', () async {
      final bundle = Directory('${tmp.path}/apps/Chatroom.app')
        ..createSync(recursive: true);
      File('${bundle.path}/old.txt').writeAsStringSync('old');
      final staged = Directory('${tmp.path}/staged/Chatroom.app')
        ..createSync(recursive: true);
      File('${staged.path}/new.txt').writeAsStringSync('new');

      // 假的 ditto／xattr：在 PATH 前面
      final bin = Directory('${tmp.path}/bin')..createSync();
      File('${bin.path}/ditto').writeAsStringSync('#!/bin/sh\ncp -R "\$1" "\$2"\n');
      File('${bin.path}/xattr').writeAsStringSync('#!/bin/sh\nexit 0\n');
      final r = await runScript(kApplyUpdateScriptMac, [
        p(bundle.path),
        p(staged.path),
        p('${tmp.path}/backup'),
        '0',
      ], env: {
        'PATH': '${p(bin.path)}:${Platform.environment['PATH']}'
      });

      expect(r.exitCode, 0, reason: '${r.stderr}\n${log()}');
      expect(File('${bundle.path}/new.txt').existsSync(), isTrue);
      expect(File('${bundle.path}/old.txt').existsSync(), isFalse);
      expect(File('${tmp.path}/backup/Chatroom.app/old.txt').existsSync(), isTrue);
    }, skip: skip);

    test('🔴 macOS：ditto 失敗 → 還原舊 bundle、結束碼 4', () async {
      final bundle = Directory('${tmp.path}/apps/Chatroom.app')
        ..createSync(recursive: true);
      File('${bundle.path}/old.txt').writeAsStringSync('old');
      Directory('${tmp.path}/staged/Chatroom.app').createSync(recursive: true);
      final bin = Directory('${tmp.path}/bin')..createSync();
      File('${bin.path}/ditto').writeAsStringSync('#!/bin/sh\nexit 1\n');
      final r = await runScript(kApplyUpdateScriptMac, [
        p(bundle.path),
        p('${tmp.path}/staged/Chatroom.app'),
        p('${tmp.path}/backup'),
        '0',
      ], env: {
        'PATH': '${p(bin.path)}:${Platform.environment['PATH']}'
      });

      expect(r.exitCode, 4, reason: log());
      expect(File('${bundle.path}/old.txt').existsSync(), isTrue);
    }, skip: skip);

    test('macOS：拒絕不是 .app 的路徑（不會 rm 到別的東西）', () async {
      final r = await runScript(kApplyUpdateScriptMac,
          [p(tmp.path), p(tmp.path), p('${tmp.path}/b'), '0']);
      expect(r.exitCode, 64);
      expect(Directory(tmp.path).existsSync(), isTrue);
    }, skip: skip);

    test('Linux：只換這一包帶來的頂層項目，別的檔案原封不動；舊的進 backup', () async {
      final app = Directory('${tmp.path}/app')..createSync();
      File('${app.path}/chatroom').writeAsStringSync('old-exe');
      Directory('${app.path}/lib').createSync();
      File('${app.path}/lib/libapp.so').writeAsStringSync('old-so');
      File('${app.path}/notes.txt').writeAsStringSync('mine');
      final staged = Directory('${tmp.path}/staged')..createSync();
      File('${staged.path}/chatroom').writeAsStringSync('new-exe');
      Directory('${staged.path}/lib').createSync();
      File('${staged.path}/lib/libapp.so').writeAsStringSync('new-so');

      final r = await runScript(kApplyUpdateScriptLinux, [
        p(app.path),
        p(staged.path),
        p('${tmp.path}/backup'),
        p('${app.path}/chatroom'),
        '0',
      ]);

      expect(r.exitCode, 0, reason: '${r.stderr}\n${log()}');
      expect(File('${app.path}/chatroom').readAsStringSync(), 'new-exe');
      expect(File('${app.path}/lib/libapp.so').readAsStringSync(), 'new-so');
      expect(File('${app.path}/notes.txt').readAsStringSync(), 'mine');
      expect(File('${tmp.path}/backup/chatroom').readAsStringSync(), 'old-exe');
    }, skip: skip);

    test('Linux：staged 是空的 → 沒替換、結束碼 4', () async {
      final app = Directory('${tmp.path}/app')..createSync();
      File('${app.path}/chatroom').writeAsStringSync('old-exe');
      Directory('${tmp.path}/staged').createSync();
      final r = await runScript(kApplyUpdateScriptLinux, [
        p(app.path),
        p('${tmp.path}/staged'),
        p('${tmp.path}/backup'),
        p('${app.path}/chatroom'),
        '0',
      ]);
      expect(r.exitCode, 4);
      expect(File('${app.path}/chatroom').readAsStringSync(), 'old-exe');
    }, skip: skip);

    test('🔴 App 還在跑（等到逾時）→ 結束碼 2、不替換', () async {
      final app = Directory('${tmp.path}/app')..createSync();
      File('${app.path}/chatroom').writeAsStringSync('old-exe');
      final staged = Directory('${tmp.path}/staged')..createSync();
      File('${staged.path}/chatroom').writeAsStringSync('new-exe');
      // 用 sh 自己起一個睡著的進程，拿它在 sh 這個世界裡的 pid
      final spawn = await Process.run(
          sh!, ['-c', 'sleep 30 >/dev/null 2>&1 & echo \$!']);
      final pid = '${spawn.stdout}'.trim();

      final r = await runScript(kApplyUpdateScriptLinux, [
        p(app.path),
        p(staged.path),
        p('${tmp.path}/backup'),
        p('${app.path}/chatroom'),
        pid,
        '1',
      ]);
      await Process.run(sh, ['-c', 'kill $pid']);

      expect(r.exitCode, 2, reason: log());
      expect(File('${app.path}/chatroom').readAsStringSync(), 'old-exe');
    }, skip: skip);
  });
}
