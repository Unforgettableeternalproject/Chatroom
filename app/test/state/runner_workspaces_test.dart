import 'dart:convert';
import 'dart:io';

import 'package:chatroom_app/state/runner_workspaces.dart';
import 'package:flutter_test/flutter_test.dart';

/// 工作區／專案兩層的解析與 CRUD。
///
/// 這一層的三個要害：
/// 1. **新舊鍵都要讀得進來**（`workspaces`←`projects`、
///    `projects`←`repos`、`default_project`←`default_repo`）：同一份設定會在
///    新舊版執行器之間來回，讀不到舊鍵等於把人家的設定當成空的。
/// 2. **預設值要與執行器同一組**（`public` 預設 true、
///    `allow_browser_livetest` 預設 false）。
/// 3. **寫回去不能吃掉沒碰過的欄位**，而且非 git repo 的專案要當場拒絕——
///    寫進去的話，錯誤要等到下一次 `reload` 才出現。
void main() {
  late Directory tmp;
  late String sep;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('runner_workspaces_test');
    sep = Platform.pathSeparator;
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// 造一個「是 git repo」的目錄。`asFile` ＝ worktree／submodule 那種
  /// `.git` 指標檔。
  Future<String> makeRepo(String name, {bool asFile = false}) async {
    final dir = Directory('${tmp.path}$sep$name');
    await dir.create(recursive: true);
    if (asFile) {
      await File('${dir.path}$sep.git').writeAsString('gitdir: ../x/.git\n');
    } else {
      await Directory('${dir.path}$sep.git').create();
    }
    return dir.path;
  }

  Future<String> makePlainDir(String name) async {
    final dir = Directory('${tmp.path}$sep$name');
    await dir.create(recursive: true);
    return dir.path;
  }

  group('RunnerWorkspace.fromJson', () {
    test('🔴 新鍵：projects／default_project／primary_skill', () {
      final w = RunnerWorkspace.fromJson('chatroom', {
        'public': false,
        'allow_browser_livetest': true,
        'model': 'opus',
        'max_turns': 40,
        'max_budget_usd': 3.5,
        'wall_clock_seconds': 1800,
        'context_window_tokens': 200000,
        'skill_dirs': [r'C:\repos'],
        'primary_skill': 'pm',
        'default_project': 'Chatroom',
        'extra_write_dirs': [r'C:\tmp'],
        'projects': {
          'Chatroom': {
            'path': r'C:\repos\Chatroom',
            'allowed_branches': ['develop'],
            'push_branches': ['develop'],
          },
        },
      });
      expect(w.public, isFalse);
      expect(w.allowBrowserLivetest, isTrue);
      expect(w.model, 'opus');
      expect(w.maxTurns, 40);
      expect(w.maxBudgetUsd, 3.5);
      expect(w.wallClockSeconds, 1800);
      expect(w.contextWindowTokens, 200000);
      expect(w.primarySkill, 'pm');
      expect(w.defaultProject, 'Chatroom');
      expect(w.extraWriteDirs, [r'C:\tmp']);
      expect(w.projects['Chatroom']!.path, r'C:\repos\Chatroom');
      expect(w.projects['Chatroom']!.allowedBranches, ['develop']);
      expect(w.projects['Chatroom']!.pushBranches, ['develop']);
    });

    test('🔴 舊鍵：repos／default_repo 照樣讀得出來', () {
      final w = RunnerWorkspace.fromJson('chatroom', {
        'default_repo': 'r1',
        'repos': {
          'r1': {'path': r'C:\repos\r1'},
        },
      });
      expect(w.projects['r1']!.path, r'C:\repos\r1');
      expect(w.defaultProject, 'r1');
      expect(w.public, isTrue,
          reason: '這兩個旗標是後加的，舊設定的工作區本來就在別人的派工清單裡');
      expect(w.allowBrowserLivetest, isFalse);
      expect(w.primarySkill, '');
    });

    test('新鍵優先於舊鍵', () {
      final w = RunnerWorkspace.fromJson('a', {
        'projects': {
          'new': {'path': '/new'},
        },
        'repos': {
          'old': {'path': '/old'},
        },
        'default_project': 'new',
        'default_repo': 'old',
      });
      expect(w.projects.keys, ['new']);
      expect(w.defaultProject, 'new');
    });

    test('🔴 toJson 只寫新鍵', () {
      final w = RunnerWorkspace.fromJson('a', {
        'default_repo': 'r1',
        'repos': {
          'r1': {'path': '/r1'},
        },
      });
      final json = w.toJson();
      expect(json.containsKey('repos'), isFalse);
      expect(json.containsKey('default_repo'), isFalse);
      expect(json['default_project'], 'r1');
      expect((json['projects'] as Map)['r1'], {'path': '/r1'});
    });
  });

  group('config.json 的讀寫（用真實檔案驗）', () {
    late String path;
    late String repoA;

    Future<Map<String, dynamic>> sample() async => {
          'hub_url': 'http://127.0.0.1:8787',
          'host': 'test-host',
          'state_dir': '${tmp.path}${sep}state',
          'projects': {
            'a': {
              'repos': {
                'r': {'path': repoA},
              },
              'skill_dirs': ['/skills'],
              // 這一版還不認得的鍵：存檔之後**必須還在**
              'future_field': {'x': 1},
            },
          },
        };

    setUp(() async {
      repoA = await makeRepo('repo_a');
      path = '${tmp.path}${sep}config.json';
      await File(path).writeAsString(jsonEncode(await sample()));
    });

    Future<RunnerConfigFile> read() async => (await readRunnerConfig(path))!;

    Future<Map<String, dynamic>> raw() async =>
        (jsonDecode(await File(path).readAsString()) as Map)
            .cast<String, dynamic>();

    test('🔴 頂層舊鍵 projects 也讀得出工作區', () async {
      final cfg = await read();
      expect(cfg.workspaces.single.key, 'a');
      expect(cfg.workspaces.single.projects['r']!.path, repoA);
      expect(cfg.host, 'test-host');
      expect(cfg.stateDir, endsWith('state'));
    });

    test('頂層新鍵 workspaces 讀得出來', () async {
      final data = await sample();
      data['workspaces'] = data.remove('projects');
      await File(path).writeAsString(jsonEncode(data));
      final cfg = await read();
      expect(cfg.workspaces.single.key, 'a');
    });

    test('檔案不存在＝沒有設定，不是錯誤', () async {
      expect(await readRunnerConfig('${tmp.path}/nope.json'), isNull);
    });

    test('🔴 壞掉的 JSON 降級成 null，不往上丟例外', () async {
      await File(path).writeAsString('{ 半個檔案');
      expect(await readRunnerConfig(path), isNull);
    });

    group('allowed_mcp_servers（執行器層）', () {
      test('讀得出允許清單與 claude_bin／claude_config_dir', () async {
        final data = await sample();
        data['allowed_mcp_servers'] = ['chatroom', 'claude.ai Gmail'];
        data['claude_bin'] = 'claude';
        data['claude_config_dir'] = r'C:\cfg';
        await File(path).writeAsString(jsonEncode(data));
        final cfg = await read();
        expect(cfg.allowedMcpServers, ['chatroom', 'claude.ai Gmail']);
        expect(cfg.claudeBin, ['claude']);
        expect(cfg.claudeConfigDir, r'C:\cfg');
      });

      test('🔴 沒有這一鍵＝空清單（意思是沿用執行器預設，不是全開）', () async {
        expect((await read()).allowedMcpServers, isEmpty);
        expect((await read()).claudeBin, ['claude'],
            reason: 'claude_bin 沒設時執行器叫的就是 claude');
      });

      test('🔴 chatroom 一定寫進去，重複的名字不疊', () async {
        await saveRunnerAllowedMcpServers(await read(),
            servers: ['claude.ai Gmail', 'claude.ai Gmail']);
        expect((await raw())['allowed_mcp_servers'],
            ['chatroom', 'claude.ai Gmail'],
            reason: 'run 沒有 chatroom 就進不了房，那一輪只會盲做');
      });

      test('存檔不碰其他欄位', () async {
        await saveRunnerAllowedMcpServers(await read(), servers: const []);
        expect((await raw())['allowed_mcp_servers'], ['chatroom']);
        expect((await raw())['hub_url'], 'http://127.0.0.1:8787');
        final ws = ((await raw())['projects'] as Map)['a'] as Map;
        expect(ws['future_field'], {'x': 1});
      });
    });

    test('🔴 存檔只動被碰到的鍵，沒認得的欄位留著', () async {
      await saveRunnerWorkspace(await read(),
          workspaceKey: 'a',
          public: false,
          allowBrowserLivetest: true,
          skillDirs: ['/skills', '/more']);

      final ws = (((await raw())['projects'] as Map)['a'] as Map);
      expect(ws['public'], isFalse);
      expect(ws['allow_browser_livetest'], isTrue);
      expect(ws['skill_dirs'], ['/skills', '/more']);
      expect(ws['future_field'], {'x': 1},
          reason: '整份重組的話，使用者手寫的欄位會在存檔那一刻消失');
      expect((await raw())['hub_url'], 'http://127.0.0.1:8787');

      final again = await read();
      expect(again.workspaces.single.public, isFalse);
      expect(again.workspaces.single.allowBrowserLivetest, isTrue);
    });

    test('🔴 這期間檔案被改過就不覆寫', () async {
      final cfg = await read();
      // mtime 的解析度可能是秒級，直接給一份「更早讀到」的快照來表達衝突
      final stale = RunnerConfigFile(
        path: cfg.path,
        raw: cfg.raw,
        workspaces: cfg.workspaces,
        modified: cfg.modified.subtract(const Duration(minutes: 5)),
      );
      await expectLater(
        saveRunnerWorkspace(stale, workspaceKey: 'a', public: false),
        throwsA(isA<RunnerConfigConflict>()),
      );
      expect((((await raw())['projects'] as Map)['a'] as Map)['public'], isNull,
          reason: '衝突時一個位元組都不該寫進去');
    });

    test('🔴 mtime 衝突擋得住新增專案', () async {
      final cfg = await read();
      final stale = RunnerConfigFile(
        path: cfg.path,
        raw: cfg.raw,
        workspaces: cfg.workspaces,
        modified: cfg.modified.subtract(const Duration(minutes: 5)),
      );
      final repoB = await makeRepo('repo_b');
      await expectLater(
        addRunnerProject(stale, workspaceKey: 'a', name: 'b', path: repoB),
        throwsA(isA<RunnerConfigConflict>()),
      );
    });

    test('🔴 沒有暫存檔留在原地', () async {
      await saveRunnerWorkspace(await read(), workspaceKey: 'a', public: false);
      expect(await File('$path.tmp').exists(), isFalse);
    });

    group('專案 CRUD', () {
      test('新增專案寫進既有的 repos 鍵，不順手改名', () async {
        final repoB = await makeRepo('repo_b');
        await addRunnerProject(await read(),
            workspaceKey: 'a',
            name: 'b',
            path: repoB,
            pushBranches: ['develop']);

        final ws = ((await raw())['projects'] as Map)['a'] as Map;
        expect(ws.containsKey('projects'), isFalse,
            reason: '原本是 repos，加一個專案不該多出一個平行的容器');
        expect((ws['repos'] as Map)['b'],
            {'path': repoB, 'push_branches': ['develop']});
      });

      test('🔴 不是 git repo 的路徑被拒絕', () async {
        final plain = await makePlainDir('not_a_repo');
        await expectLater(
          addRunnerProject(await read(),
              workspaceKey: 'a', name: 'b', path: plain),
          throwsA(isA<RunnerConfigInvalid>()),
        );
        final ws = ((await raw())['projects'] as Map)['a'] as Map;
        expect((ws['repos'] as Map).containsKey('b'), isFalse);
      });

      test('🔴 worktree 的 .git 是檔案，照樣算 git repo', () async {
        final wt = await makeRepo('worktree', asFile: true);
        await addRunnerProject(await read(),
            workspaceKey: 'a', name: 'wt', path: wt);
        final ws = ((await raw())['projects'] as Map)['a'] as Map;
        expect(((ws['repos'] as Map)['wt'] as Map)['path'], wt);
      });

      test('路徑不存在被拒絕', () async {
        await expectLater(
          addRunnerProject(await read(),
              workspaceKey: 'a', name: 'b', path: '${tmp.path}${sep}nope'),
          throwsA(isA<RunnerConfigInvalid>()),
        );
      });

      test('同名專案被拒絕', () async {
        await expectLater(
          addRunnerProject(await read(),
              workspaceKey: 'a', name: 'r', path: repoA),
          throwsA(isA<RunnerConfigInvalid>()),
        );
      });

      test('🔴 最後一個專案不給移除', () async {
        await expectLater(
          removeRunnerProject(await read(), workspaceKey: 'a', name: 'r'),
          throwsA(isA<RunnerConfigInvalid>()),
        );
      });

      test('移除專案時清掉指著它的 default_repo', () async {
        final repoB = await makeRepo('repo_b');
        await addRunnerProject(await read(),
            workspaceKey: 'a', name: 'b', path: repoB);
        await saveRunnerWorkspace(await read(),
            workspaceKey: 'a', defaultProject: 'b');
        await removeRunnerProject(await read(), workspaceKey: 'a', name: 'b');

        final ws = ((await raw())['projects'] as Map)['a'] as Map;
        expect((ws['repos'] as Map).containsKey('b'), isFalse);
        expect(ws['default_repo'], isNull);
        expect(ws['default_project'], isNull);
      });

      test('預設專案不在工作區裡就拒絕', () async {
        await expectLater(
          saveRunnerWorkspace(await read(),
              workspaceKey: 'a', defaultProject: 'nope'),
          throwsA(isA<RunnerConfigInvalid>()),
        );
      });
    });

    group('工作區 CRUD', () {
      test('登記既有資料夾：資料夾本身是 git repo 就當第一個專案', () async {
        final repoB = await makeRepo('repo_b');
        await addRunnerWorkspace(await read(), key: 'b', folder: repoB);

        final ws = ((await raw())['projects'] as Map)['b'] as Map;
        expect(((ws['projects'] as Map)['repo_b'] as Map)['path'], repoB);
        expect(ws['default_project'], 'repo_b',
            reason: '新的工作區一律寫新鍵');
      });

      test('🔴 資料夾不是 git repo 時要指定專案路徑', () async {
        final plain = await makePlainDir('workspace_root');
        await expectLater(
          addRunnerWorkspace(await read(), key: 'b', folder: plain),
          throwsA(isA<RunnerConfigInvalid>()),
        );

        final repoB = await makeRepo('workspace_root${sep}inner');
        await addRunnerWorkspace(await read(),
            key: 'b', folder: plain, projectName: 'inner', projectPath: repoB);
        final ws = ((await raw())['projects'] as Map)['b'] as Map;
        expect(((ws['projects'] as Map)['inner'] as Map)['path'], repoB);
      });

      test('🔴 folder 存得進去、讀得回來、改得動', () async {
        final root = await makePlainDir('ws_root');
        final repoB = await makeRepo('ws_root${sep}inner');
        await addRunnerWorkspace(await read(),
            key: 'b', folder: root, projectName: 'inner', projectPath: repoB);
        expect((((await raw())['projects'] as Map)['b'] as Map)['folder'],
            root);

        final w = (await read()).workspaces.firstWhere((e) => e.key == 'b');
        expect(w.folder, root);
        expect(w.toJson()['folder'], root);

        final moved = await makePlainDir('ws_root2');
        await saveRunnerWorkspace(await read(),
            workspaceKey: 'b', folder: moved);
        expect((((await raw())['projects'] as Map)['b'] as Map)['folder'],
            moved);

        // 不存在的資料夾要當場擋下
        await expectLater(
          saveRunnerWorkspace(await read(),
              workspaceKey: 'b', folder: '${tmp.path}${sep}nope'),
          throwsA(isA<RunnerConfigInvalid>()),
        );

        // 空字串＝清掉
        await saveRunnerWorkspace(await read(), workspaceKey: 'b', folder: '');
        expect(
            (((await raw())['projects'] as Map)['b'] as Map)
                .containsKey('folder'),
            isFalse);
      });

      test('資料夾不存在被拒絕', () async {
        await expectLater(
          addRunnerWorkspace(await read(),
              key: 'b', folder: '${tmp.path}${sep}nope'),
          throwsA(isA<RunnerConfigInvalid>()),
        );
      });

      test('同名工作區被拒絕', () async {
        final repoB = await makeRepo('repo_b');
        await expectLater(
          addRunnerWorkspace(await read(), key: 'a', folder: repoB),
          throwsA(isA<RunnerConfigInvalid>()),
        );
      });

      test('移除工作區', () async {
        final repoB = await makeRepo('repo_b');
        await addRunnerWorkspace(await read(), key: 'b', folder: repoB);
        await removeRunnerWorkspace(await read(), key: 'b');
        expect(((await raw())['projects'] as Map).containsKey('b'), isFalse);
        expect(((await raw())['projects'] as Map).containsKey('a'), isTrue);
      });

      test('移除不存在的工作區要說清楚', () async {
        await expectLater(
          removeRunnerWorkspace(await read(), key: 'nope'),
          throwsA(isA<RunnerConfigInvalid>()),
        );
      });
    });

    group('primary_skill', () {
      /// skill 的位置與執行器 `skill_manifest()` 同一條規則。
      Future<String> makeSkillDir(String name, List<String> skills) async {
        final dir = Directory('${tmp.path}$sep$name');
        for (final s in skills) {
          final d = Directory(
              [dir.path, '.claude', 'skills', s].join(sep));
          await d.create(recursive: true);
          await File('${d.path}${sep}SKILL.md').writeAsString('# $s\n');
        }
        await dir.create(recursive: true);
        return dir.path;
      }

      test('掃得出 skill_dirs 底下的 skill，去重且排序', () async {
        final d1 = await makeSkillDir('skills1', ['pm', 'story']);
        final d2 = await makeSkillDir('skills2', ['pm', 'chatroom']);
        expect(await listRunnerSkills([d1, d2]),
            ['chatroom', 'pm', 'story']);
      });

      test('沒有 SKILL.md 的目錄不算 skill', () async {
        final dir = Directory(
            [tmp.path, 'skills3', '.claude', 'skills', 'empty'].join(sep));
        await dir.create(recursive: true);
        expect(await listRunnerSkills(['${tmp.path}${sep}skills3']), isEmpty);
      });

      test('讀不到的目錄不會擋掉其他目錄', () async {
        final d1 = await makeSkillDir('skills4', ['pm']);
        expect(await listRunnerSkills(['${tmp.path}${sep}nope', d1]), ['pm']);
      });

      test('🔴 設定的 skill 要在這個工作區的 skill_dirs 裡找得到', () async {
        final skills = await makeSkillDir('skills5', ['pm']);
        await saveRunnerWorkspace(await read(),
            workspaceKey: 'a', skillDirs: [skills]);

        await expectLater(
          setRunnerPrimarySkill(await read(),
              workspaceKey: 'a', skill: 'nosuch'),
          throwsA(isA<RunnerConfigInvalid>()),
        );

        await setRunnerPrimarySkill(await read(),
            workspaceKey: 'a', skill: 'pm');
        final ws = ((await raw())['projects'] as Map)['a'] as Map;
        expect(ws['primary_skill'], 'pm');

        await setRunnerPrimarySkill(await read(), workspaceKey: 'a', skill: '');
        expect((((await raw())['projects'] as Map)['a'] as Map)
            .containsKey('primary_skill'), isFalse);
      });
    });
  });
}
