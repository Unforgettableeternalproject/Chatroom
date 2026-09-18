import 'dart:convert';
import 'dart:io';

import 'package:chatroom_app/state/runner_kit_providers.dart';
import 'package:flutter_test/flutter_test.dart';

/// runner-kit 註冊檔與 `config.json` 的讀寫。
///
/// 這一層的兩個要害：
/// 1. **預設值要與執行器同一組**（`public` 預設 true、
///    `allow_browser_livetest` 預設 false）——兩邊不一樣的話，同一份設定在
///    畫面與執行器眼裡會是兩種意思，而沒有任何地方會報錯。
/// 2. **寫回去不能吃掉沒碰過的欄位**：使用者手寫的、或這一版還不認得的鍵，
///    在存檔那一刻消失是最難查的一種壞法。
void main() {
  group('RunnerKit.fromJson', () {
    test('讀得出註冊檔（安裝器實際寫的四個欄位）', () {
      final kit = RunnerKit.fromJson({
        'kit_dir': r'E:\ProgramFiles\Chatroom\Runner',
        'python': r'E:\ProgramFiles\Chatroom\Runner\.venv\Scripts\python.exe',
        'config': r'C:\Users\me\AppData\Local\UEP\Chatroom\runner\config.json',
        'installed_at': '2026-09-18T06:00:00+00:00',
      });
      expect(kit.kitDir, r'E:\ProgramFiles\Chatroom\Runner');
      expect(kit.configPath, endsWith('config.json'));
      expect(kit.installedAt, '2026-09-18T06:00:00+00:00');
    });

    test('🔴 缺欄位不炸，補空字串', () {
      final kit = RunnerKit.fromJson({'kit_dir': '/x'});
      expect(kit.configPath, '');
      expect(kit.python, '');
    });
  });

  group('RunnerProject.fromJson', () {
    test('🔴 沒有旗標的舊設定：public 預設 true、實機測試預設 false', () {
      final p = RunnerProject.fromJson('chatroom', {
        'repos': {
          'Chatroom': {'path': r'C:\repos\Chatroom'},
        },
      });
      expect(p.public, isTrue,
          reason: '這兩個欄位是後加的，舊設定的專案本來就在別人的派工清單裡');
      expect(p.allowBrowserLivetest, isFalse);
      expect(p.repos['Chatroom'], r'C:\repos\Chatroom');
    });

    test('讀得出旗標、default_repo 與 skill_dirs', () {
      final p = RunnerProject.fromJson('a', {
        'public': false,
        'allow_browser_livetest': true,
        'default_repo': 'r1',
        'skill_dirs': [r'C:\repos'],
        'repos': {
          'r1': {'path': r'C:\repos\r1'},
        },
      });
      expect(p.public, isFalse);
      expect(p.allowBrowserLivetest, isTrue);
      expect(p.defaultRepo, 'r1');
      expect(p.skillDirs, [r'C:\repos']);
    });
  });

  group('config.json 的讀寫（用真實檔案驗）', () {
    late Directory tmp;
    late String path;

    Map<String, dynamic> sample() => {
          'hub_url': 'http://127.0.0.1:8787',
          'host': 'test-host',
          'state_dir': '${tmp.path}${Platform.pathSeparator}state',
          'projects': {
            'a': {
              'repos': {
                'r': {'path': '/repo'},
              },
              'skill_dirs': ['/skills'],
              // 這一版還不認得的鍵：存檔之後**必須還在**
              'future_field': {'x': 1},
            },
          },
        };

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('runnerkit_test');
      path = '${tmp.path}${Platform.pathSeparator}config.json';
      await File(path).writeAsString(jsonEncode(sample()));
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('讀得出專案與 host/state_dir', () async {
      final cfg = await readRunnerConfig(path);
      expect(cfg, isNotNull);
      expect(cfg!.projects.single.key, 'a');
      expect(cfg.host, 'test-host');
      expect(cfg.stateDir, endsWith('state'));
    });

    test('檔案不存在＝沒有設定，不是錯誤', () async {
      expect(await readRunnerConfig('${tmp.path}/nope.json'), isNull);
    });

    test('🔴 壞掉的 JSON 降級成 null，不往上丟例外', () async {
      await File(path).writeAsString('{ 半個檔案');
      expect(await readRunnerConfig(path), isNull);
    });

    test('🔴 存檔只動被碰到的鍵，沒認得的欄位留著', () async {
      final cfg = (await readRunnerConfig(path))!;
      await saveRunnerProject(cfg,
          projectKey: 'a',
          public: false,
          allowBrowserLivetest: true,
          skillDirs: ['/skills', '/more']);

      final raw = jsonDecode(await File(path).readAsString()) as Map;
      final project = (raw['projects'] as Map)['a'] as Map;
      expect(project['public'], isFalse);
      expect(project['allow_browser_livetest'], isTrue);
      expect(project['skill_dirs'], ['/skills', '/more']);
      expect(project['future_field'], {'x': 1},
          reason: '整份重組的話，使用者手寫的欄位會在存檔那一刻消失');
      expect(raw['hub_url'], 'http://127.0.0.1:8787');

      // 存完再讀，旗標要回得來（App 與執行器讀的是同一份）
      final again = (await readRunnerConfig(path))!;
      expect(again.projects.single.public, isFalse);
      expect(again.projects.single.allowBrowserLivetest, isTrue);
    });

    test('🔴 這期間檔案被改過就不覆寫', () async {
      final cfg = (await readRunnerConfig(path))!;
      // mtime 的解析度可能是秒級，直接給一份「更早讀到」的快照來表達衝突
      final stale = RunnerConfigFile(
        path: cfg.path,
        raw: cfg.raw,
        projects: cfg.projects,
        modified: cfg.modified.subtract(const Duration(minutes: 5)),
      );
      expect(
        () => saveRunnerProject(stale, projectKey: 'a', public: false),
        throwsA(isA<RunnerConfigConflict>()),
      );
      final raw = jsonDecode(await File(path).readAsString()) as Map;
      expect(((raw['projects'] as Map)['a'] as Map)['public'], isNull,
          reason: '衝突時一個位元組都不該寫進去');
    });

    test('🔴 沒有暫存檔留在原地', () async {
      final cfg = (await readRunnerConfig(path))!;
      await saveRunnerProject(cfg, projectKey: 'a', public: false);
      expect(await File('$path.tmp').exists(), isFalse);
    });
  });
}
