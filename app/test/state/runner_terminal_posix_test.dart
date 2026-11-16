import 'dart:io';

import 'package:chatroom_app/core/platform/app_platform.dart';
import 'package:chatroom_app/state/runner_kit_providers.dart';
import 'package:flutter_test/flutter_test.dart';

/// 執行器登入用的終端機（macOS／Linux）與說明頁的路徑顯示。
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('term-posix'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on Object {
      // 清不掉不影響結果
    }
  });

  test('shellQuote：單引號寫成 \'\\\'\'', () {
    expect(shellQuote('/a b/c'), "'/a b/c'");
    expect(shellQuote("it's"), "'it'\\''s'");
  });

  test('登入指令跟著平台；Windows 維持 PowerShell 寫法', () {
    expect(claudeLoginCommandFor(AppPlatform.windows, r'C:\cfg'),
        r'$env:CLAUDE_CONFIG_DIR = "C:\cfg"; claude auth login');
    expect(
        claudeLoginCommandFor(AppPlatform.macos,
            '/Users/a/Library/Application Support/UEP/Chatroom/runner/claude-config'),
        "CLAUDE_CONFIG_DIR='/Users/a/Library/Application Support/UEP/Chatroom/runner/claude-config' claude auth login");
    expect(claudeLoginCommandFor(AppPlatform.linux, '/d', ['setup-token']),
        "CLAUDE_CONFIG_DIR='/d' claude setup-token");
  });

  test('終端機腳本：先 export 設定目錄，再用登入 shell 跑 claude', () {
    final s = claudeTerminalShellScript("/x/it's", ['auth', 'login']);
    expect(s, startsWith('#!/bin/sh\n'));
    expect(s, contains("export CLAUDE_CONFIG_DIR='/x/it'\\''s'"));
    expect(s, contains(r'"${SHELL:-/bin/sh}" -l -c'));
    expect(s, contains("-c 'claude "));
    expect(s, contains('auth'));
    expect(s.contains('\r'), isFalse);
  });

  test('終端機腳本語法正確（真的 sh -n）', () {
    String? sh;
    for (final c in ['sh', 'bash']) {
      try {
        if (Process.runSync(c, ['-c', 'true']).exitCode == 0) {
          sh = c;
          break;
        }
      } on Object {
        continue;
      }
    }
    if (sh == null) return;
    final f = File('${tmp.path}/t.sh')
      ..writeAsStringSync(
          claudeTerminalShellScript("/x/it's", ['auth', 'login']));
    final r = Process.runSync(sh, ['-n', f.path.replaceAll(r'\', '/')]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
  });

  test('Linux 終端機候選依序：x-terminal-emulator、gnome-terminal、konsole、xterm', () {
    expect(linuxTerminalCommands('/s').map((c) => c.executable), [
      'x-terminal-emulator',
      'gnome-terminal',
      'konsole',
      'xterm',
    ]);
  });

  group('openClaudeTerminal（POSIX）', () {
    test('macOS：chmod 後 open -a Terminal 跑 .command', () async {
      final calls = <List<String>>[];
      await openClaudeTerminal('/cfg', ['auth', 'login'],
          platform: AppPlatform.macos,
          tempRoot: tmp,
          run: (exe, args) async {
        calls.add([exe, ...args]);
        return ProcessResult(0, 0, '', '');
      });
      expect(calls[0].sublist(0, 2), ['chmod', '755']);
      expect(calls[1].sublist(0, 3), ['open', '-a', 'Terminal']);
      expect(calls[1].last, endsWith('claude-login.command'));
      expect(File(calls[1].last).existsSync(), isTrue);
    });

    test('Linux：用第一個找得到的終端機', () async {
      final calls = <List<String>>[];
      await openClaudeTerminal('/cfg', ['auth', 'login'],
          platform: AppPlatform.linux,
          tempRoot: tmp,
          hasCommand: (n) => n == 'konsole' || n == 'xterm',
          run: (exe, args) async {
        calls.add([exe, ...args]);
        return ProcessResult(0, 0, '', '');
      });
      expect(calls.single.first, 'konsole');
      expect(calls.single.sublist(1, 3), ['-e', 'sh']);
    });

    test('Linux：第一個起不來就試下一個', () async {
      final calls = <String>[];
      await openClaudeTerminal('/cfg', ['auth', 'login'],
          platform: AppPlatform.linux,
          tempRoot: tmp,
          hasCommand: (_) => true,
          run: (exe, args) async {
        calls.add(exe);
        return ProcessResult(0, exe == 'gnome-terminal' ? 0 : 1, '', '');
      });
      expect(calls, ['x-terminal-emulator', 'gnome-terminal']);
    });

    test('🔴 Linux 一個終端機都沒有 → 可讀錯誤，帶著要自己執行的那一行', () async {
      await expectLater(
        openClaudeTerminal('/my cfg', ['auth', 'login'],
            platform: AppPlatform.linux,
            tempRoot: tmp,
            hasCommand: (_) => false,
            run: (exe, args) async => fail('不該叫任何程式')),
        throwsA(isA<ClaudeTerminalUnavailable>().having((e) => '$e', 'msg',
            contains("CLAUDE_CONFIG_DIR='/my cfg' claude auth login"))),
      );
    });

    test('macOS：open 失敗 → 同樣的可讀錯誤', () async {
      await expectLater(
        openClaudeTerminal('/cfg', ['auth', 'login'],
            platform: AppPlatform.macos,
            tempRoot: tmp,
            run: (exe, args) async =>
                ProcessResult(0, exe == 'open' ? 1 : 0, '', '')),
        throwsA(isA<ClaudeTerminalUnavailable>()),
      );
    });
  });

  test('說明頁的設定檔位置：Windows 維持環境變數寫法，其他平台顯示實際路徑', () {
    expect(runnerConfigPathDisplay(AppPlatform.windows),
        r'%LOCALAPPDATA%\UEP\Chatroom\runner\config.json');
    expect(runnerConfigPathDisplay(null),
        r'%LOCALAPPDATA%\UEP\Chatroom\runner\config.json');
    expect(runnerConfigPathDisplay(AppPlatform.macos),
        '~/Library/Application Support/UEP/Chatroom/runner/config.json');
    expect(runnerConfigPathDisplay(AppPlatform.linux),
        contains('uep/chatroom/runner/config.json'));
  });
}
