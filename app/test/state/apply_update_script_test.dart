@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:chatroom_app/state/app_updater.dart';
import 'package:chatroom_app/state/kit_installer.dart';
import 'package:flutter_test/flutter_test.dart';

/// `apply-update.ps1` 本體：對臨時目錄**真的跑一次** PowerShell。
///
/// 一律帶 `-NoRelaunch`——測試不該起任何 App。只在 Windows 上跑。
void main() {
  final skip = Platform.isWindows ? null : 'apply-update.ps1 只在 Windows 上跑';

  late Directory temp;
  late String appDir;
  late String stagedDir;
  late String backupDir;
  late String script;
  late String exePath;

  String join(String base, List<String> parts) =>
      [base, ...parts].join(Platform.pathSeparator);

  void write(String base, List<String> parts, String content) =>
      File(join(base, parts))
        ..createSync(recursive: true)
        ..writeAsStringSync(content);

  Map<String, String> snapshot(String dir) {
    final root = Directory(dir);
    return {
      for (final f in root.listSync(recursive: true).whereType<File>())
        f.path.substring(root.path.length + 1): f.readAsStringSync(),
    };
  }

  String log() => File(join(temp.path, ['upd', 'apply-update.log']))
      .readAsStringSync();

  /// 一個已經結束的 PID。
  Future<int> deadPid() async {
    final p = await Process.start('cmd', ['/c', 'exit']);
    await p.exitCode;
    return p.pid;
  }

  List<String> args(int waitPid, {int? timeoutSec}) => [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script,
        '-AppDir',
        appDir,
        '-StagedDir',
        stagedDir,
        '-BackupDir',
        backupDir,
        '-ExePath',
        exePath,
        '-WaitPid',
        '$waitPid',
        if (timeoutSec != null) ...['-TimeoutSec', '$timeoutSec'],
        '-NoRelaunch',
      ];

  const oldFiles = {
    'Chatroom.exe': 'old exe',
    r'data\app.so': 'old so',
    'old-only.txt': 'old',
  };

  setUp(() {
    temp = Directory.systemTemp.createTempSync('apply-update-test-');
    appDir = join(temp.path, ['app dir']);
    stagedDir = join(temp.path, ['upd', 'staged']);
    backupDir = join(temp.path, ['upd', 'backup']);
    script = join(temp.path, ['upd', 'apply-update.ps1']);
    exePath = join(appDir, ['Chatroom.exe']);
    write(appDir, ['Chatroom.exe'], 'old exe');
    write(appDir, ['data', 'app.so'], 'old so');
    write(appDir, ['old-only.txt'], 'old');
    write(stagedDir, ['Chatroom.exe'], 'new exe');
    write(stagedDir, ['data', 'app.so'], 'new so');
    write(stagedDir, ['new-only.txt'], 'new');
    File(script).writeAsStringSync(kApplyUpdateScript);
  });

  tearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } on Object {
      // 清不掉不影響測試結果
    }
  });

  test('成功：這一包帶來的項目換成新的，舊的在 BackupDir', () async {
    final r = await Process.run('powershell', args(await deadPid()));

    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    expect(snapshot(appDir), {
      'Chatroom.exe': 'new exe',
      r'data\app.so': 'new so',
      'new-only.txt': 'new',
      'old-only.txt': 'old',
    });
    expect(snapshot(backupDir), {
      'Chatroom.exe': 'old exe',
      r'data\app.so': 'old so',
    });
    expect(log(), contains('update applied'));
    expect(log(), contains('relaunch skipped'));
  }, skip: skip);

  test('🔴 exe 旁邊不相干的檔案與資料夾：不備份、不刪、不搬', () async {
    // 整包解到下載資料夾的人，安裝目錄裡就是一堆別的東西
    write(appDir, ['my notes.txt'], 'mine');
    write(appDir, ['photos', 'a.jpg'], 'jpg');

    final r = await Process.run('powershell', args(await deadPid()));

    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    final after = snapshot(appDir);
    expect(after['my notes.txt'], 'mine');
    expect(after[r'photos\a.jpg'], 'jpg');
    expect(after['Chatroom.exe'], 'new exe');
    final backup = snapshot(backupDir);
    expect(backup.containsKey('my notes.txt'), isFalse);
    expect(backup.containsKey(r'photos\a.jpg'), isFalse);
  }, skip: skip);

  test('StagedDir 不存在：什麼都不動', () async {
    Directory(stagedDir).deleteSync(recursive: true);

    final r = await Process.run('powershell', args(await deadPid()));

    expect(r.exitCode, 4, reason: '${r.stdout}${r.stderr}');
    expect(snapshot(appDir), oldFiles);
    expect(Directory(backupDir).existsSync(), isFalse);
    expect(log(), contains('nothing replaced'));
  }, skip: skip);

  test('複製到一半失敗：已複製的清掉，AppDir 還原成原樣', () async {
    // 鎖住 staged 裡排在後面的那個檔案，讓複製走到它才失敗
    write(stagedDir, ['zz-locked.bin'], 'locked');
    final raf = File(join(stagedDir, ['zz-locked.bin']))
        .openSync(mode: FileMode.append);
    raf.lockSync(FileLock.exclusive);
    final ProcessResult r;
    try {
      r = await Process.run('powershell', args(await deadPid()));
    } finally {
      raf.unlockSync();
      raf.closeSync();
    }

    expect(r.exitCode, 4, reason: '${r.stdout}${r.stderr}');
    expect(snapshot(appDir), oldFiles);
    expect(log(), isNot(contains('staged copied')));
    expect(log(), contains('restored'));
  }, skip: skip);

  test('等不到 App 結束：不替換', () async {
    // 這個測試進程自己還活著，腳本等不到它
    final r = await Process.run('powershell', args(pid, timeoutSec: 2));

    expect(r.exitCode, 2, reason: '${r.stdout}${r.stderr}');
    expect(snapshot(appDir), oldFiles);
    expect(Directory(backupDir).existsSync(), isFalse);
    expect(log(), contains('timeout'));
    // App 還活著：再起一次就是第二個實例
    expect(log(), isNot(contains('relaunch')));
  }, skip: skip);

  test('用正式的啟動器（detached、隱藏視窗）起得來並跑完', () async {
    final package = AppUpdatePackage(
      tag: 'v9.9.9',
      dir: join(temp.path, ['upd']),
      stagedDir: stagedDir,
      backupDir: backupDir,
      scriptPath: script,
    );
    await const DetachedAppUpdateLauncher().start(
      'powershell',
      [
        ...applyUpdateArguments(
          package: package,
          installDir: appDir,
          exePath: exePath,
          waitPid: await deadPid(),
        ),
        '-NoRelaunch',
      ],
      workingDirectory: package.dir,
    );

    // detached 拿不到結束碼，看 log 的最後一步
    final logFile = File(join(temp.path, ['upd', 'apply-update.log']));
    for (var i = 0; i < 240; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (logFile.existsSync() &&
          logFile.readAsStringSync().contains('relaunch skipped')) {
        break;
      }
    }
    expect(log(), contains('update applied'));
    expect(snapshot(appDir)['Chatroom.exe'], 'new exe');
    expect(snapshot(backupDir), {
      'Chatroom.exe': 'old exe',
      r'data\app.so': 'old so',
    });
  }, skip: skip);

  group('下載後的驗證與解壓用真的 PowerShell', () {
    late String zip;
    late String sha256;

    /// 把 staged 壓成一份與 Release 同形狀的 zip（根目錄直接是檔案），
    /// 雜湊另外用 certutil 算——不拿被測的那條指令替自己作證。
    setUp(() async {
      zip = join(temp.path, ['asset.zip']);
      final packed = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        'Compress-Archive -Path "$stagedDir\\*" -DestinationPath "$zip"',
      ]);
      expect(packed.exitCode, 0, reason: '${packed.stderr}');
      final hashed =
          await Process.run('certutil', ['-hashfile', zip, 'SHA256']);
      sha256 = RegExp(r'^[0-9a-fA-F ]{64,}$', multiLine: true)
          .firstMatch('${hashed.stdout}')!
          .group(0)!
          .replaceAll(' ', '')
          .toLowerCase();
    });

    AppUpdater updater() => AppUpdater(
          http: _CopyHttp(zip),
          processRunner: const SystemKitProcessRunner(),
          updateRoot: join(temp.path, ['root dir']),
          installDir: appDir,
        );

    AppRelease release(String digest) => AppRelease(
          tag: 'v9.9.9',
          assetName: 'chatroom-app-v9.9.9-windows-x64.zip',
          downloadUrl: 'https://example.invalid/app.zip',
          size: File(zip).lengthSync(),
          sha256: digest,
        );

    test('雜湊相符：解出來的就是 zip 裡的東西', () async {
      final package = await updater().download(release(sha256));

      expect(snapshot(package.stagedDir), {
        'Chatroom.exe': 'new exe',
        r'data\app.so': 'new so',
        'new-only.txt': 'new',
      });
      expect(snapshot(appDir), oldFiles);
    }, skip: skip);

    test('雜湊不符：failed，安裝目錄沒動', () async {
      await expectLater(
        updater().download(release('0' * 64)),
        throwsA(isA<AppUpdateError>().having(
            (e) => e.reason, 'reason', AppUpdateFailure.digestMismatch)),
      );
      expect(snapshot(appDir), oldFiles);
    }, skip: skip);
  });
}

/// 「下載」＝把本機的那份 zip 複製過去。
class _CopyHttp implements KitHttpClient {
  _CopyHttp(this.source);

  final String source;

  @override
  Future<(int, Object?)> getJson(String url) async => (404, null);

  @override
  Future<void> download(String url, String savePath,
      {void Function(int received, int total)? onProgress}) async {
    await File(source).copy(savePath);
  }
}
