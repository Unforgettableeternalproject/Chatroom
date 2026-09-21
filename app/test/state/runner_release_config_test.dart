import 'dart:convert';
import 'dart:io';

import 'package:chatroom_app/state/runner_workspaces.dart';
import 'package:flutter_test/flutter_test.dart';

/// 上板設定的讀寫：專案的 `stable_branch` 與工作區的 `release`。
///
/// 三個要害：
/// 1. **空的 `stable_branch` 是「這個 repo 不上板」**，所以清掉它要把鍵移掉，
///    不是寫一個空字串進去——執行器那側兩者意思一樣，但檔案裡留著空鍵會讓
///    人以為設過了。
/// 2. **不合法的 `merge_method` 退回預設**（與執行器同一條規則）：兩邊不一樣
///    的話，畫面顯示的合併方式與實際跑的會是兩件事，而沒有地方會報錯。
/// 3. **只動被碰到的鍵**：`release` 底下這一版還不認得的欄位要原樣留著。
void main() {
  late Directory tmp;
  late String sep;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('runner_release_test');
    sep = Platform.pathSeparator;
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<RunnerConfigFile> writeConfig(Map<String, dynamic> raw) async {
    final path = '${tmp.path}${sep}config.json';
    await File(path).writeAsString(jsonEncode(raw));
    final cfg = await readRunnerConfig(path);
    return cfg!;
  }

  Map<String, dynamic> configWith(Map<String, dynamic> workspace) => {
        'workspaces': {
          'chatroom': {
            'folder': tmp.path,
            'projects': {
              'Chatroom': {'path': r'C:\repos\Chatroom'},
            },
            ...workspace,
          },
        },
      };

  Future<Map<String, dynamic>> readBack(RunnerConfigFile cfg) async =>
      (jsonDecode(await File(cfg.path).readAsString()) as Map)
          .cast<String, dynamic>();

  Map<String, dynamic> projectRaw(Map<String, dynamic> raw) =>
      ((raw['workspaces'] as Map)['chatroom'] as Map)['projects']['Chatroom']
          as Map<String, dynamic>;

  Map<String, dynamic> releaseRaw(Map<String, dynamic> raw) =>
      ((raw['workspaces'] as Map)['chatroom'] as Map)['release']
          as Map<String, dynamic>;

  group('讀', () {
    test('專案讀得到 stable_branch，沒寫就是空字串（＝不參與上板）', () {
      final w = RunnerWorkspace.fromJson('chatroom', {
        'projects': {
          'A': {'path': r'C:\a', 'stable_branch': 'main'},
          'B': {'path': r'C:\b'},
        },
      });
      expect(w.projects['A']!.stableBranch, 'main');
      expect(w.projects['A']!.eligibleForRelease, isTrue);
      expect(w.projects['B']!.stableBranch, '');
      expect(w.projects['B']!.eligibleForRelease, isFalse);
    });

    test('工作區讀得到 release 三個欄位', () {
      final w = RunnerWorkspace.fromJson('chatroom', {
        'release': {
          'merge_method': 'squash',
          'merge_message': 'release: {source}',
          'tag_message': '{objective}',
        },
      });
      expect(w.release.mergeMethod, 'squash');
      expect(w.release.mergeMessage, 'release: {source}');
      expect(w.release.tagMessage, '{objective}');
    });

    test('🔴 不合法的 merge_method 退回預設，而不是原樣留著', () {
      final w = RunnerWorkspace.fromJson('chatroom', {
        'release': {'merge_method': 'rebase'},
      });
      expect(w.release.mergeMethod, 'merge');
    });

    test('沒有 release 這一鍵就是一組預設值', () {
      final w = RunnerWorkspace.fromJson('chatroom', const {});
      expect(w.release.mergeMethod, 'merge');
      expect(w.release.mergeMessage, '');
      expect(w.release.tagMessage, '');
    });
  });

  group('寫', () {
    test('設 stable_branch：寫進那個專案，其他欄位不動', () async {
      final cfg = await writeConfig(configWith(const {
        'projects': {
          'Chatroom': {
            'path': r'C:\repos\Chatroom',
            'allowed_branches': ['develop'],
          },
        },
      }));
      await saveRunnerProject(cfg,
          workspaceKey: 'chatroom', name: 'Chatroom', stableBranch: ' main ');

      final project = projectRaw(await readBack(cfg));
      expect(project['stable_branch'], 'main');
      expect(project['allowed_branches'], ['develop']);
      expect(project['path'], r'C:\repos\Chatroom');
    });

    test('🔴 清空 stable_branch＝把鍵移掉，不是寫空字串', () async {
      final cfg = await writeConfig(configWith(const {
        'projects': {
          'Chatroom': {'path': r'C:\repos\Chatroom', 'stable_branch': 'main'},
        },
      }));
      await saveRunnerProject(cfg,
          workspaceKey: 'chatroom', name: 'Chatroom', stableBranch: '');

      expect(projectRaw(await readBack(cfg)).containsKey('stable_branch'),
          isFalse);
    });

    test('null＝不碰 stable_branch（只改分支規則時不該把它清掉）', () async {
      final cfg = await writeConfig(configWith(const {
        'projects': {
          'Chatroom': {'path': r'C:\repos\Chatroom', 'stable_branch': 'main'},
        },
      }));
      await saveRunnerProject(cfg,
          workspaceKey: 'chatroom',
          name: 'Chatroom',
          allowedBranches: ['develop']);

      expect(projectRaw(await readBack(cfg))['stable_branch'], 'main');
    });

    test('寫 release：空的訊息模板不寫出去（留給執行器的預設）', () async {
      final cfg = await writeConfig(configWith(const {}));
      await saveRunnerWorkspace(cfg,
          workspaceKey: 'chatroom',
          release: const RunnerRelease(
              mergeMethod: 'ff_only', mergeMessage: '', tagMessage: '{objective}'));

      final release = releaseRaw(await readBack(cfg));
      expect(release['merge_method'], 'ff_only');
      expect(release.containsKey('merge_message'), isFalse);
      expect(release['tag_message'], '{objective}');
    });

    test('🔴 release 底下不認得的欄位原樣留著', () async {
      final cfg = await writeConfig(configWith(const {
        'release': {'merge_method': 'merge', 'future_flag': true},
      }));
      await saveRunnerWorkspace(cfg,
          workspaceKey: 'chatroom',
          release: const RunnerRelease(mergeMethod: 'squash'));

      final release = releaseRaw(await readBack(cfg));
      expect(release['merge_method'], 'squash');
      expect(release['future_flag'], isTrue);
    });

    test('沒給 release 就不碰它', () async {
      final cfg = await writeConfig(configWith(const {
        'release': {'merge_method': 'squash'},
      }));
      await saveRunnerWorkspace(cfg, workspaceKey: 'chatroom', public: false);

      expect(releaseRaw(await readBack(cfg))['merge_method'], 'squash');
    });
  });
}
