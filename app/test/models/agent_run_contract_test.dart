import 'package:chatroom_app/models/agent_run.dart';
import 'package:flutter_test/flutter_test.dart';

/// 遠端派工的 `fromJson` 契約。
///
/// JSON **寫死**，而且鍵集合抄自 Hub 釘住的那一份
/// （`tests/test_remote_ops.py` 的 `RUN_KEYS` / `RUNNER_KEYS`）。從 model
/// 反推一份 JSON 來測等於拿自己的假設驗自己的實作——Hub 哪天少回一把鍵，
/// 那種測試照樣全綠。
const Map<String, dynamic> _runJson = {
  'id': 'run-1',
  'room_id': 'room-1',
  'board_id': 'board-1',
  'kind': 'ticket',
  'project': 'ai-website',
  'ref': 'task-9',
  'brief': '修掉登入頁的 500',
  'requested_by': 'p-1',
  'requested_by_actor_key': 'actor-1',
  'requested_by_name': '艾斯維爾',
  // 誰動的手（Supervisor 自派工 2026-09-19）。與上面那組「配額算誰的」
  // 是兩個人
  'requester_kind': 'human',
  'requester_name': '艾斯維爾',
  // 這一輪是誰做的（participant.run_id 反查）；還沒進房時 Hub 給 null
  'agent_name': 'Amber-Badger',
  'status': 'running',
  'priority': 2,
  'position': 3,
  'runner_id': 'runner-1',
  'claude_session_id': 'sess-1',
  'attempt': 1,
  'parent_run_id': '',
  'handoff_depth': 0,
  'cancel_requested': false,
  'usage': {'num_turns': 12, 'total_cost_usd': 1.25, 'context_peak_tokens': 90000},
  'result': '',
  'reason': '',
  'created_at': '2026-09-16T01:00:00+00:00',
  'claimed_at': '2026-09-16T01:00:05+00:00',
  'started_at': '2026-09-16T01:00:09+00:00',
  'ended_at': null,
  'updated_at': '2026-09-16T01:05:00+00:00',
};

const Map<String, dynamic> _runnerJson = {
  'id': 'runner-1',
  'host': 'ASVEL-PC',
  'label': 'main',
  'status': 'online',
  'max_parallel': 3,
  'running_count': 1,
  'projects': ['ai-website'],
  'limited_until': null,
  'limit_reason': '',
  'usage_window': {'tokens': 1000},
  'dashboard': {
    'generated_at': '2026-09-16T01:05:00+00:00',
    'repos': {
      'ai-website/JSAI-Web': {
        'path': 'C:/x/JSAI-Web',
        'branch': 'jsai_dev',
        'dirty': false,
        'dirty_count': 0,
        'unpushed_count': 2,
        'unpushed': [
          {'sha': 'abc1234567', 'title': 'fix: 登入頁', 'at': '2026-09-16T00:00:00+00:00'},
          {'sha': 'def7654321', 'title': 'test: 補一條', 'at': '2026-09-16T00:30:00+00:00'},
        ],
        'pushable': true,
      },
    },
    'usage': {
      'window_hours': 5.0,
      'tokens': 120000,
      'cost_usd': 3.5,
      'soft_cap_tokens': 500000,
      'soft_cap_usd': 20.0,
      'over_soft_cap': false,
      'remaining_tokens': 380000,
    },
    'limits': {'status': 'online', 'limited_until': null, 'limit_reason': ''},
    'runs': {
      'running': [
        {
          'run_id': 'run-1',
          'kind': 'ticket',
          'ref': 'task-9',
          'project': 'ai-website',
          'repo': 'JSAI-Web',
          'started_at': '2026-09-16T01:00:09+00:00',
          'turns': 12,
          'context_tokens': 90000,
        },
      ],
      'queued_count': 1,
      'max_parallel': 3,
    },
    'runner': {
      'version': '0.1.0',
      'started_at': '2026-09-16T00:00:00+00:00',
      'last_restart_reason': '',
      'selfcheck_problems': [],
    },
  },
  'version': '0.1.0',
  'registered_at': '2026-09-15T00:00:00+00:00',
  'last_seen_at': '2026-09-16T01:05:00+00:00',
};

void main() {
  group('AgentRun', () {
    test('Hub 釘住的每一把鍵都讀得到', () {
      final run = AgentRun.fromJson(_runJson);
      expect(run.id, 'run-1');
      expect(run.roomId, 'room-1');
      expect(run.boardId, 'board-1');
      expect(run.kind, 'ticket');
      expect(run.project, 'ai-website');
      expect(run.ref, 'task-9');
      expect(run.brief, '修掉登入頁的 500');
      expect(run.requestedByName, '艾斯維爾');
      expect(run.requestedByActorKey, 'actor-1');
      expect(run.requesterKind, 'human');
      expect(run.requesterName, '艾斯維爾');
      expect(run.isAgentRequested, isFalse);
      expect(run.status, 'running');
      expect(run.priority, 2);
      expect(run.position, 3);
      expect(run.runnerId, 'runner-1');
      expect(run.claudeSessionId, 'sess-1');
      expect(run.attempt, 1);
      expect(run.handoffDepth, 0);
      expect(run.cancelRequested, isFalse);
      expect(run.turns, 12);
      expect(run.costUsd, 1.25);
      expect(run.contextTokens, 90000);
      expect(run.startedAt, isNotNull);
      expect(run.endedAt, isNull);
    });

    test('Supervisor 代派：動手的與配額歸屬是兩個人', () {
      final run = AgentRun.fromJson({
        ..._runJson,
        'requester_kind': 'agent',
        'requester_name': '米絲媞',
      });
      expect(run.isAgentRequested, isTrue);
      expect(run.requesterName, '米絲媞');
      // 配額仍然算在指定 Supervisor 的那個人類身上
      expect(run.requestedByName, '艾斯維爾');
    });

    test('🔴 舊 Hub 沒有這兩把鍵 → human ＋空字串，不是 agent', () {
      final old = Map<String, dynamic>.from(_runJson)
        ..remove('requester_kind')
        ..remove('requester_name');
      final run = AgentRun.fromJson(old);
      expect(run.requesterKind, 'human');
      expect(run.requesterName, '');
      expect(run.isAgentRequested, isFalse);
    });

    test('agent 的名字：null 與空字串都是「還沒有人」，不是名字', () {
      expect(AgentRun.fromJson(_runJson).agentName, 'Amber-Badger');
      // 排隊中的 run（Hub 給 null）、舊 Hub（沒這把鍵）、空字串都一樣
      expect(AgentRun.fromJson({..._runJson, 'agent_name': null}).agentName,
          isNull);
      expect(AgentRun.fromJson({..._runJson, 'agent_name': ''}).agentName,
          isNull);
      final old = Map<String, dynamic>.from(_runJson)..remove('agent_name');
      expect(AgentRun.fromJson(old).agentName, isNull);
    });

    test('queued 的取消是立刻的，running 的不是', () {
      expect(AgentRun.fromJson({..._runJson, 'status': 'queued'})
          .cancelsImmediately, isTrue);
      expect(AgentRun.fromJson(_runJson).cancelsImmediately, isFalse);
    });

    test('handoff 還佔著那張卡——它不算結束', () {
      // Hub 的 `_RUN_ACTIVE` 含 handoff：交接鏈還在跑，那個 ref 沒有空出來。
      // 這裡少算一個狀態，面板就會在交接的空檔給出一個重複派工的入口
      for (final s in ['queued', 'claimed', 'running', 'limited', 'handoff']) {
        expect(AgentRun.fromJson({..._runJson, 'status': s}).isActive, isTrue,
            reason: '$s 應該算還活著');
      }
      for (final s in ['done', 'failed', 'cancelled']) {
        expect(AgentRun.fromJson({..._runJson, 'status': s}).isFinished, isTrue,
            reason: '$s 應該算結束了');
      }
    });
  });

  group('AgentRunner', () {
    test('Hub 釘住的每一把鍵都讀得到', () {
      final r = AgentRunner.fromJson(_runnerJson);
      expect(r.id, 'runner-1');
      expect(r.host, 'ASVEL-PC');
      expect(r.label, 'main');
      expect(r.status, 'online');
      expect(r.maxParallel, 3);
      expect(r.runningCount, 1);
      expect(r.projects, ['ai-website']);
      expect(r.limitedUntil, isNull);
      expect(r.limitReason, '');
      expect(r.usageWindow['tokens'], 1000);
      expect(r.version, '0.1.0');
      expect(r.registeredAt, isNotEmpty);
      expect(r.lastSeenAt, isNotEmpty);
    });

    test('token_sha256 不在回應裡，model 也不該長出那一欄', () {
      // Hub 的 `_runner_public` 明確把它 pop 掉。這條在這裡是為了讓「App
      // 需要它」這種想法在下一次被寫下來之前先撞牆
      expect(_runnerJson.containsKey('token_sha256'), isFalse);
    });

    test('limited 的倒數：算得出來就給，算不出來回 null 而不是 0', () {
      final now = DateTime.utc(2026, 9, 16, 1, 0);
      final limited = AgentRunner.fromJson({
        ..._runnerJson,
        'status': 'limited',
        'limited_until': '2026-09-16T01:30:00+00:00',
      });
      expect(limited.remainingLimit(now: now), const Duration(minutes: 30));
      // 🔴 沒有 `limited_until` 時**不編一個倒數出來**：一個在跑的倒數與
      // 「不知道要等多久」在畫面上是兩件完全不同的事
      final unknown = AgentRunner.fromJson(
          {..._runnerJson, 'status': 'limited', 'limited_until': null});
      expect(unknown.remainingLimit(now: now), isNull);
      // 已經過期的回 0，不是負數
      final past = AgentRunner.fromJson({
        ..._runnerJson,
        'status': 'limited',
        'limited_until': '2026-09-16T00:30:00+00:00',
      });
      expect(past.remainingLimit(now: now), Duration.zero);
    });
  });

  group('執行器命令（commands）', () {
    Map<String, dynamic> cmd({
      String id = 'c1',
      String command = 'restart',
      String? acked,
      String? applied,
      String note = '',
      String created = '2026-09-16T01:00:00+00:00',
    }) =>
        {
          'id': id,
          'command': command,
          'issued_by_name': '艾斯維爾',
          'created_at': created,
          'acked_at': acked,
          'applied_at': applied,
          'note': note,
        };

    test('每一把鍵都讀得到，null 的時間戳讀成空字串', () {
      final r = AgentRunner.fromJson({
        ..._runnerJson,
        'commands': [cmd(note: '等 2 筆 run 結束後重啟')],
      });
      expect(r.commands, hasLength(1));
      final c = r.commands.first;
      expect(c.id, 'c1');
      expect(c.command, 'restart');
      expect(c.issuedByName, '艾斯維爾');
      expect(c.createdAt, '2026-09-16T01:00:00+00:00');
      expect(c.ackedAt, '');
      expect(c.appliedAt, '');
      expect(c.note, '等 2 筆 run 結束後重啟');
      expect(c.isAcked, isFalse);
      expect(c.isApplied, isFalse);
    });

    test('沒有 commands 這一把鍵時是空清單，不是 null', () {
      // 舊版 Hub 不會回這一格。面板那一行少一條，而不是整個炸掉
      expect(AgentRunner.fromJson(_runnerJson).commands, isEmpty);
    });

    test('restarting 是自己一種狀態，不是離線', () {
      final r = AgentRunner.fromJson({..._runnerJson, 'status': 'restarting'});
      expect(r.isRestarting, isTrue);
      expect(r.isOffline, isFalse);
      expect(r.isOnline, isFalse);
    });

    test('未生效的命令進 pendingCommands（同一顆按鈕要停用）', () {
      final r = AgentRunner.fromJson({
        ..._runnerJson,
        'commands': [
          cmd(id: 'c2', command: 'pause', acked: '2026-09-16T01:00:20+00:00'),
          cmd(
              id: 'c1',
              command: 'drain',
              acked: '2026-09-16T00:50:20+00:00',
              applied: '2026-09-16T00:50:30+00:00'),
        ],
      });
      expect(r.pendingCommands, {'pause'});
    });

    test('該顯示哪一道：沒生效的優先，其次是剛生效的', () {
      final now = DateTime.utc(2026, 9, 16, 1, 1);
      final pending = AgentRunner.fromJson({
        ..._runnerJson,
        'commands': [
          cmd(id: 'c2', command: 'pause'),
          cmd(
              id: 'c1',
              command: 'drain',
              acked: '2026-09-16T01:00:20+00:00',
              applied: '2026-09-16T01:00:30+00:00'),
        ],
      });
      expect(pending.visibleCommand(now: now)?.id, 'c2');

      final justApplied = AgentRunner.fromJson({
        ..._runnerJson,
        'commands': [
          cmd(
              id: 'c1',
              command: 'drain',
              acked: '2026-09-16T01:00:20+00:00',
              applied: '2026-09-16T01:00:30+00:00'),
        ],
      });
      expect(justApplied.visibleCommand(now: now)?.id, 'c1');
    });

    test('生效超過 2 分鐘就不再顯示——過期的話比沒有話更糟', () {
      final now = DateTime.utc(2026, 9, 16, 1, 10);
      final r = AgentRunner.fromJson({
        ..._runnerJson,
        'commands': [
          cmd(
              id: 'c1',
              command: 'drain',
              acked: '2026-09-16T01:00:20+00:00',
              applied: '2026-09-16T01:00:30+00:00'),
        ],
      });
      expect(r.visibleCommand(now: now), isNull);
    });
  });

  group('儀表板：「沒有」與「沒回報」要分得開', () {
    test('執行器沒回報 dashboard 時，reported 是 false', () {
      final r = AgentRunner.fromJson({..._runnerJson, 'dashboard': {}});
      expect(r.dashboard.reported, isFalse);
      expect(r.dashboard.repos, isEmpty);
      expect(r.dashboard.usage.reported, isFalse);
    });

    test('缺 pushable 是 null（未回報），不是 false（不准推）', () {
      final repo = RepoView.fromJson('ai-website/JSAI-Web', const {
        'path': 'C:/x',
        'branch': 'jsai_dev',
        'unpushed_count': 1,
        'unpushed': [],
      });
      expect(repo.pushable, isNull);
      final blocked = RepoView.fromJson('ai-website/JSAI-Web', const {
        'branch': 'jsai_prod',
        'pushable': false,
      });
      expect(blocked.pushable, isFalse);
    });

    test('缺軟上限是 null（未回報），0 是「不設上限」', () {
      final none = RunnerUsage.fromJson(const {'tokens': 5});
      expect(none.softCapTokens, isNull);
      expect(none.reported, isTrue);
      final unlimited =
          RunnerUsage.fromJson(const {'tokens': 5, 'soft_cap_tokens': 0});
      expect(unlimited.softCapTokens, 0);
      // 執行器在沒有軟上限時**明確回 null**
      final reported = RunnerUsage.fromJson(const {
        'tokens': 5,
        'soft_cap_tokens': 0,
        'remaining_tokens': null,
      });
      expect(reported.remainingTokens, isNull);
    });

    test('repo 讀不到時，錯誤進欄位而不是讓整包炸掉', () {
      final broken = RepoView.fromJson('ai-website/JSAI-Web',
          const {'path': 'C:/x', 'branch': '', 'error': '無法讀取分支'});
      expect(broken.hasError, isTrue);
      expect(broken.error, '無法讀取分支');
    });

    test('dashboard 的 repos 是 map，排序後才進畫面', () {
      final dash = RunnerDashboard.fromJson(const {
        'repos': {
          'p/b': {'branch': 'x'},
          'p/a': {'branch': 'y'},
        },
      });
      expect(dash.repos.map((r) => r.key), ['p/a', 'p/b']);
      expect(dash.repos.first.repoName, 'a');
      expect(dash.repos.first.projectKey, 'p');
    });
  });

  group('RoomRunnerBoard', () {
    const json = {
      'room_id': 'room-1',
      'runners': [_runnerJson],
      'counts': {'queued': 1, 'running': 1},
      'queued': 1,
      'running': 1,
      'active_runs': [_runJson],
    };

    test('整包讀得回來', () {
      final board = RoomRunnerBoard.fromJson(json);
      expect(board.roomId, 'room-1');
      expect(board.runners, hasLength(1));
      expect(board.counts['queued'], 1);
      expect(board.activeRuns, hasLength(1));
    });

    test('專案下拉來自執行器宣告的 projects，offline 的不算', () {
      final board = RoomRunnerBoard.fromJson({
        ...json,
        'runners': [
          {..._runnerJson, 'projects': ['ai-website']},
          {
            ..._runnerJson,
            'id': 'runner-2',
            'status': 'offline',
            'projects': ['ghost-project'],
          },
        ],
      });
      // offline 的執行器領不到單，Hub 也不拿它算 `project_not_served`
      expect(board.servedProjects, ['ai-website']);
    });
  });

  group('push 的 brief', () {
    test('第一行是分支，其後每行一個 sha', () {
      expect(buildPushBrief('jsai_dev', ['abc123', 'def456']),
          'branch: jsai_dev\nabc123\ndef456');
    });

    test('空 sha 不佔一行——空行會被執行器讀成沒有清單', () {
      expect(buildPushBrief('jsai_dev', ['abc123', '', '  ']),
          'branch: jsai_dev\nabc123');
    });

    test('沒有 commit 時只剩分支那一行', () {
      // 執行器會以 `push_sha_list_missing` 拒絕。**那是對的**：沒有清單就
      // 無法確認要推的是不是畫面上那幾顆。App 這一端則是把按鈕收起來
      expect(buildPushBrief('jsai_dev', const []), 'branch: jsai_dev');
    });

    test('sha 原樣帶上，不縮短', () {
      // 短碼是給人看的。執行器比對時允許前綴，但**顆數要一樣**——
      // 送畫面上那一份完整的，是唯一能保證「推的就是你看到的」的做法
      final full = 'a' * 40;
      expect(buildPushBrief('jsai_dev', [full]), contains(full));
    });
  });
}
