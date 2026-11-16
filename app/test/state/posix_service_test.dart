import 'dart:io';

import 'package:chatroom_app/core/platform/app_platform.dart';
import 'package:chatroom_app/state/host_actions.dart';
import 'package:chatroom_app/state/kit_installer.dart';
import 'package:chatroom_app/state/posix_service.dart';
import 'package:chatroom_app/state/runner_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// macOS／Linux 的服務控制（`service.py`）。
///
/// 跑在 Windows 上，所以平台一律用 [AppPlatform] 注入，子進程換成 fake：
/// 斷言的是「組出來的命令」與「結果怎麼判成敗」。

class _Runner implements KitProcessRunner {
  _Runner(this.reply);

  ProcessResult Function(String exe, List<String> args) reply;
  final calls = <List<String>>[];

  @override
  Future<ProcessResult> run(String executable, List<String> arguments,
      {String? workingDirectory}) async {
    calls.add([executable, ...arguments]);
    return reply(executable, arguments);
  }
}

ProcessResult _ok(String stdout, [String stderr = '']) =>
    ProcessResult(0, 0, stdout, stderr);

void main() {
  group('posixServiceCommand', () {
    test('預設用 kit 的 venv python，service.py 在 scripts/', () {
      final c = posixServiceCommand(
          kitRoot: '/Users/a/Library/Application Support/UEP/Chatroom/hub-kit',
          kind: ServiceKind.hub,
          action: 'start');
      expect(c.executable,
          '/Users/a/Library/Application Support/UEP/Chatroom/hub-kit/.venv/bin/python');
      expect(c.arguments, [
        '/Users/a/Library/Application Support/UEP/Chatroom/hub-kit/scripts/service.py',
        'hub',
        'start',
        '--json',
      ]);
      // 路徑含空白時一定是單一個參數，不能被拆開
      expect(c.arguments.first, contains('Application Support'));
    });

    test('runner 優先用註冊檔裡的 python', () {
      final c = posixServiceCommand(
          kitRoot: '/k',
          kind: ServiceKind.runner,
          action: 'status',
          python: '/k/.venv/bin/python3');
      expect(c.executable, '/k/.venv/bin/python3');
      expect(c.arguments, ['/k/scripts/service.py', 'runner', 'status', '--json']);
    });

    test('service.py 的相對位置是單一常數', () {
      expect(kServiceScriptRelPath, ['scripts', 'service.py']);
    });
  });

  group('parsePosixServiceStatus', () {
    test('契約欄位', () {
      final s = parsePosixServiceStatus(
          '{"manager":"systemd","installed":true,"enabled":true,'
          '"running":false,"detail":"inactive"}');
      expect(s!.manager, 'systemd');
      expect(s.installed, isTrue);
      expect(s.enabled, isTrue);
      expect(s.running, isFalse);
      expect(s.detail, 'inactive');
    });

    test('🔴 不是 JSON → null，不編一個「沒註冊」出來', () {
      expect(parsePosixServiceStatus(''), isNull);
      expect(parsePosixServiceStatus('Traceback (most recent call last):'),
          isNull);
    });

    test('前面有進度輸出時取最後一行 JSON', () {
      final s = parsePosixServiceStatus(
          'checking...\n{"manager":"launchd","installed":true,"enabled":true,'
          '"running":true,"detail":""}\n');
      expect(s!.manager, 'launchd');
      expect(s.running, isTrue);
    });

    test('缺欄位當 false', () {
      final s = parsePosixServiceStatus('{"manager":"none"}');
      expect(s!.installed, isFalse);
      expect(s.running, isFalse);
    });
  });

  group('normalizeServiceResult', () {
    test('ok → exit 0，說明在 stdout', () {
      final r = normalizeServiceResult(
          _ok('{"ok": true, "manager": "systemd", "detail": "已啟動"}'));
      expect(r.exitCode, 0);
      expect('${r.stdout}', '已啟動');
      expect('${r.stderr}', isEmpty);
    });

    test('🔴 ok=false → 非 0，原因在 stderr（不靠 stderr 空不空判成敗）', () {
      final r = normalizeServiceResult(ProcessResult(
          0, 1, '{"ok": false, "manager": "none", "detail": "沒有 systemd"}', ''));
      expect(r.exitCode, 1);
      expect('${r.stderr}', '沒有 systemd');
      expect('${r.stdout}', isEmpty);
    });

    test('exit 0 但 JSON 說 ok=false 也算失敗', () {
      final r = normalizeServiceResult(
          _ok('{"ok": false, "manager": "x", "detail": "壞了"}'));
      expect(r.exitCode, isNot(0));
    });

    test('不是 JSON 且失敗 → stdout 補進 stderr', () {
      final r = normalizeServiceResult(ProcessResult(0, 2, 'boom', ''));
      expect(r.exitCode, 2);
      expect('${r.stderr}', 'boom');
    });
  });

  test('openFolderCommand：Windows explorer、macOS open、Linux xdg-open', () {
    expect(openFolderCommand(AppPlatform.windows, r'C:\a').executable,
        'explorer');
    expect(openFolderCommand(AppPlatform.macos, '/a b').executable, 'open');
    expect(openFolderCommand(AppPlatform.macos, '/a b').arguments, ['/a b']);
    expect(openFolderCommand(AppPlatform.linux, '/a').executable, 'xdg-open');
  });

  group('HostActions', () {
    test('POSIX：service 走 service.py hub，不叫 powershell', () async {
      final calls = <List<String>>[];
      final actions = HostActions('/opt/hub-kit',
          platform: AppPlatform.linux, run: (exe, args) async {
        calls.add([exe, ...args]);
        return _ok('{"ok": true, "manager": "systemd", "detail": "stopped"}');
      });
      final r = await actions.stopHub();

      expect(calls.single, [
        '/opt/hub-kit/.venv/bin/python',
        '/opt/hub-kit/scripts/service.py',
        'hub',
        'stop',
        '--json',
      ]);
      expect(r.exitCode, 0);
      expect('${r.stdout}', 'stopped');
    });

    test('POSIX：stop 失敗 → stderr 有原因、exit 非 0', () async {
      final actions = HostActions('/opt/hub-kit',
          platform: AppPlatform.macos,
          run: (exe, args) async => ProcessResult(0, 1,
              '{"ok": false, "manager": "launchd", "detail": "埠仍有監聽"}', ''));
      final r = await actions.stopHub();
      expect(r.exitCode, 1);
      expect('${r.stderr}', '埠仍有監聽');
    });

    test('🔴 Windows 行為不變：powershell -File hub-service.ps1', () async {
      final calls = <List<String>>[];
      final actions = HostActions(r'C:\kit',
          platform: AppPlatform.windows, run: (exe, args) async {
        calls.add([exe, ...args]);
        return _ok('ok');
      });
      await actions.service('stop');
      expect(calls.single,
          ['powershell', '-NoProfile', '-File', r'C:\kit\scripts\hub-service.ps1', 'stop']);
    });

    test('POSIX：posixServiceStatus 解析 status --json', () async {
      final actions = HostActions('/k',
          platform: AppPlatform.linux,
          run: (exe, args) async => _ok(
              '{"manager":"systemd","installed":true,"enabled":true,'
              '"running":true,"detail":"active"}'));
      final st = await actions.posixServiceStatus();
      expect(st.installed, isTrue);
      expect(st.running, isTrue);
    });

    test('POSIX：status 印不出 JSON → 丟錯（呼叫端顯示問不到）', () async {
      final actions = HostActions('/k',
          platform: AppPlatform.linux,
          run: (exe, args) async => ProcessResult(0, 1, '', 'no python'));
      await expectLater(actions.posixServiceStatus(),
          throwsA(isA<StateError>().having((e) => e.message, 'm', 'no python')));
    });

    test('POSIX 背景啟動：/bin/sh 跑 .sh；隧道帶 CHATROOM_HIDDEN=1', () {
      final actions = HostActions('/k', platform: AppPlatform.macos);
      final hub = actions.backgroundLaunch('run-hub.sh');
      expect(hub.executable, '/bin/sh');
      expect(hub.arguments, ['/k/scripts/run-hub.sh']);
      expect(hub.environment, isEmpty);
      final tunnel = actions.backgroundLaunch('run-tunnel.sh', hidden: true);
      expect(tunnel.environment, {'CHATROOM_HIDDEN': '1'});
    });
  });

  group('執行器（POSIX）', () {
    test('runnerStateFromPosix：停用 > 在跑 > 已停止；沒註冊 unknown', () {
      PosixServiceStatus st(bool i, bool e, bool r) => PosixServiceStatus(
          manager: 'systemd', installed: i, enabled: e, running: r, detail: '');
      expect(runnerStateFromPosix(st(false, false, false)),
          RunnerServiceState.unknown);
      expect(runnerStateFromPosix(st(true, false, false)),
          RunnerServiceState.disabled);
      expect(runnerStateFromPosix(st(true, false, true)),
          RunnerServiceState.disabled,
          reason: '停用優先：下次登入不會回來這件事比現在有沒有在跑更該被看見');
      expect(runnerStateFromPosix(st(true, true, true)),
          RunnerServiceState.running);
      expect(runnerStateFromPosix(st(true, true, false)),
          RunnerServiceState.stopped);
    });

    test('start／stop 走 service.py runner，不叫 powershell', () async {
      final runner = _Runner((_, _) => _ok(
          '{"ok": true, "manager": "systemd", "detail": "done"}'));
      final c = RunnerServiceController(
        processRunner: runner,
        taskName: 'ChatroomRunner',
        posix: const RunnerPosixTarget(
            kitDir: '/home/a/.local/share/uep/chatroom/runner-kit',
            python: '/home/a/.local/share/uep/chatroom/runner-kit/.venv/bin/python'),
      );
      expect(await c.stop(), isNull);
      expect(await c.start(), isNull);

      expect(runner.calls.map((c) => c[0]).toSet(), {
        '/home/a/.local/share/uep/chatroom/runner-kit/.venv/bin/python'
      });
      expect(runner.calls[0].sublist(2), ['runner', 'stop', '--json']);
      expect(runner.calls[1].sublist(2), ['runner', 'start', '--json']);
    });

    test('🔴 失敗回原因（exit 非 0 或 ok=false）', () async {
      final runner = _Runner((_, _) => ProcessResult(0, 1,
          '{"ok": false, "manager": "none", "detail": "沒有 systemd"}', ''));
      final c = RunnerServiceController(
          processRunner: runner,
          taskName: 't',
          posix: const RunnerPosixTarget(kitDir: '/k'));
      expect(await c.start(), '沒有 systemd');
    });

    test('找不到 kit 目錄 → 回說明，不去叫任何程式', () async {
      final runner = _Runner((_, _) => _ok(''));
      final c = RunnerServiceController(
          processRunner: runner,
          taskName: 't',
          posix: const RunnerPosixTarget(kitDir: ''));
      expect(await c.stop(), isNotNull);
      expect(runner.calls, isEmpty);
    });

    test('Windows 的控制器沒帶 posix → 照舊走 PowerShell', () async {
      final runner = _Runner((_, _) => _ok(''));
      final c = RunnerServiceController(
          processRunner: runner, taskName: 'ChatroomRunner');
      await c.start();
      expect(runner.calls.every((c) => c.first == 'powershell'), isTrue);
    });

    test('狀態：macOS 上問 service.py runner status，不叫 PowerShell', () async {
      final runner = _Runner((_, _) => _ok(
          '{"manager":"launchd","installed":true,"enabled":true,'
          '"running":true,"detail":""}'));
      final container = ProviderContainer(overrides: [
        appPlatformProvider.overrideWithValue(AppPlatform.macos),
        kitInstallSupportedProvider.overrideWithValue(true),
        kitProcessRunnerProvider.overrideWithValue(runner),
        runnerTaskNameProvider.overrideWith((ref) async => 'ChatroomRunner'),
        runnerPosixTargetProvider.overrideWith(
            (ref) async => const RunnerPosixTarget(kitDir: '/r')),
      ]);
      addTearDown(container.dispose);

      final status = await container.read(runnerServiceStatusProvider.future);
      expect(status.state, RunnerServiceState.running);
      expect(runner.calls.single.first, '/r/.venv/bin/python');
      expect(runner.calls.single.contains('powershell'), isFalse);
    });

    test('狀態：service.py 沒印 JSON → unknown，帶 stderr', () async {
      final runner =
          _Runner((_, _) => ProcessResult(0, 1, '', 'no such file'));
      final container = ProviderContainer(overrides: [
        appPlatformProvider.overrideWithValue(AppPlatform.linux),
        kitInstallSupportedProvider.overrideWithValue(true),
        kitProcessRunnerProvider.overrideWithValue(runner),
        runnerTaskNameProvider.overrideWith((ref) async => 'ChatroomRunner'),
        runnerPosixTargetProvider.overrideWith(
            (ref) async => const RunnerPosixTarget(kitDir: '/r')),
      ]);
      addTearDown(container.dispose);

      final status = await container.read(runnerServiceStatusProvider.future);
      expect(status.state, RunnerServiceState.unknown);
      expect(status.detail, 'no such file');
    });
  });
}
