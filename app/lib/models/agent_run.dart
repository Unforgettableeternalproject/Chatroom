import 'package:flutter/foundation.dart';

import '../l10n/l10n.dart';

/// 遠端派工（Remote Ops，REMOTE-OPS-PLAN §4）的資料模型。
///
/// 形狀的權威有兩處，**不是同一份**：
/// - `agent_run` / `runner` 兩張表的鍵集合由 Hub 釘住
///   （`tests/test_remote_ops.py` 的 `test_response_shapes_are_pinned`）。
/// - `runner.dashboard` 的內容是**執行器寫的**（`runner/chatroom_runner/
///   dashboard.py`），Hub 原樣存、不解讀。所以那一層的缺欄位不是 Hub 的錯，
///   而是「那台執行器的版本還沒有這一格」。
///
/// ⚠️ 兩種缺欄位在畫面上必須分得開：**「這一格是空的」與「回報的人沒講」
/// 不是同一件事**。前者可以直接顯示 0／無，後者只能說不知道——把後者畫成 0
/// 會讓人根據一個沒有人講過的數字做決定。所以會影響動作的欄位一律用
/// `containsKey` 判存在（同 `BoardDelta.customTags` 的慣例），不用
/// `as T? ?? 預設值` 把兩者壓成一個。

/// run 的狀態。Hub 的狀態機（§4.2）只允許列出的轉移。
const List<String> kRunActiveStatuses = [
  'queued',
  'claimed',
  'running',
  'limited',
  'handoff',
];

/// 派工模板（§6.2）。人類不寫自由 prompt，只選模板 + 目標 + 一段簡述。
@immutable
class RunTemplate {
  const RunTemplate(this.kind, this.label, this.summary);

  final String kind;
  final String label;
  final String summary;
}

/// 可以從畫面上派出去的模板。
///
/// **`push` 不在這裡**：它不是人寫簡述的派工，是儀表板上按「推送」時由
/// App 組出來的固定形狀（§5.6）。讓它出現在模板清單裡，等於請人手打
/// 要推的 sha。
///
/// 文字跟著語言走，所以是 getter 而不是 `const`；`kind` 仍是固定的契約值。
List<RunTemplate> get kRunTemplates {
  final l10n = L10n.current;
  return [
    RunTemplate('investigate', l10n.opsTemplateInvestigateLabel,
        l10n.opsTemplateInvestigateSummary),
    RunTemplate('ticket', l10n.opsTemplateTicketLabel,
        l10n.opsTemplateTicketSummary),
    RunTemplate(
        'stage', l10n.opsTemplateStageLabel, l10n.opsTemplateStageSummary),
  ];
}

/// 簡述上限。Hub 的 `RunCreate.brief` 是 `max_length=2000`——這裡先擋是為了
/// 讓人在打字時就看得到剩多少，不是取代 Hub 那道。
const int kRunBriefMaxLength = 2000;

/// 一筆派工。鍵集合＝Hub 的 `RUN_KEYS`。
@immutable
class AgentRun {
  const AgentRun({
    required this.id,
    required this.roomId,
    required this.kind,
    required this.project,
    required this.ref,
    this.boardId = '',
    this.brief = '',
    this.requestedBy = '',
    this.requestedByActorKey = '',
    this.requestedByName = '',
    this.status = 'queued',
    this.priority = 0,
    this.position = 0,
    this.runnerId = '',
    this.claudeSessionId = '',
    this.attempt = 0,
    this.parentRunId = '',
    this.handoffDepth = 0,
    this.cancelRequested = false,
    this.softStopRequestedAt,
    this.usage = const {},
    this.result = '',
    this.reason = '',
    this.createdAt = '',
    this.claimedAt,
    this.startedAt,
    this.endedAt,
    this.updatedAt = '',
  });

  final String id;
  final String roomId;
  final String boardId;

  /// investigate | ticket | stage | push。
  final String kind;
  final String project;

  /// checklist_id 或 task_id；`push` 時是 repo key（§4.2）。
  final String ref;
  final String brief;
  final String requestedBy;
  final String requestedByActorKey;
  final String requestedByName;

  /// queued | claimed | running | limited | handoff | done | failed | cancelled
  final String status;
  final int priority;
  final int position;
  final String runnerId;
  final String claudeSessionId;
  final int attempt;
  final String parentRunId;
  final int handoffDepth;

  /// 已經有人按過取消。
  ///
  /// **running 的取消不改狀態**（§4.2）：進程還在跑，所以畫面要講的是
  /// 「已要求取消」而不是「已取消」——後者在機器上還在寫檔時是假的。
  final bool cancelRequested;

  /// 已經有人請它收尾（軟停止）。null ＝沒有人請過。
  ///
  /// 與取消的分別是**誰來收場**：取消是執行器殺進程，收尾是讓 agent 自己把
  /// 目前這一步做完、寫完收工摘要再結束。狀態一樣不動，所以畫面要講的是
  /// 「已要求收尾」。
  final String? softStopRequestedAt;

  /// 執行器最後一次回報的 tokens / cost / turns（`usage_json`）。
  final Map<String, dynamic> usage;
  final String result;
  final String reason;
  final String createdAt;
  final String? claimedAt;
  final String? startedAt;
  final String? endedAt;
  final String updatedAt;

  bool get isQueued => status == 'queued';
  bool get isRunning => status == 'running' || status == 'claimed';
  bool get isActive => kRunActiveStatuses.contains(status);
  bool get isFinished => !isActive;

  /// 取消這一筆會立刻生效嗎。queued 是立刻，其餘都要等執行器收到。
  bool get cancelsImmediately => isQueued;

  int get turns => _asInt(usage['num_turns']);

  /// context 的**估算**（§10）：執行器從每則 assistant 訊息的 usage 累計，
  /// 沒有任何方式從外部讀真正的百分比。
  int get contextTokens => _asInt(usage['context_peak_tokens']);

  double get costUsd => _asDouble(usage['total_cost_usd']);

  factory AgentRun.fromJson(Map<String, dynamic> json) => AgentRun(
        id: (json['id'] as String?) ?? '',
        roomId: (json['room_id'] as String?) ?? '',
        boardId: (json['board_id'] as String?) ?? '',
        kind: (json['kind'] as String?) ?? '',
        project: (json['project'] as String?) ?? '',
        ref: (json['ref'] as String?) ?? '',
        brief: (json['brief'] as String?) ?? '',
        requestedBy: (json['requested_by'] as String?) ?? '',
        requestedByActorKey: (json['requested_by_actor_key'] as String?) ?? '',
        requestedByName: (json['requested_by_name'] as String?) ?? '',
        status: (json['status'] as String?) ?? 'queued',
        priority: _asInt(json['priority']),
        position: _asInt(json['position']),
        runnerId: (json['runner_id'] as String?) ?? '',
        claudeSessionId: (json['claude_session_id'] as String?) ?? '',
        attempt: _asInt(json['attempt']),
        parentRunId: (json['parent_run_id'] as String?) ?? '',
        handoffDepth: _asInt(json['handoff_depth']),
        cancelRequested: (json['cancel_requested'] as bool?) ?? false,
        softStopRequestedAt: json['soft_stop_requested_at'] as String?,
        usage: json['usage'] is Map
            ? Map<String, dynamic>.from(json['usage'] as Map)
            : const {},
        result: (json['result'] as String?) ?? '',
        reason: (json['reason'] as String?) ?? '',
        createdAt: (json['created_at'] as String?) ?? '',
        claimedAt: json['claimed_at'] as String?,
        startedAt: json['started_at'] as String?,
        endedAt: json['ended_at'] as String?,
        updatedAt: (json['updated_at'] as String?) ?? '',
      );

  @override
  bool operator ==(Object other) => other is AgentRun && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// 稽核串的一筆（`agent_run_event`）。
@immutable
class AgentRunEvent {
  const AgentRunEvent({
    required this.id,
    required this.runId,
    this.fromStatus = '',
    this.toStatus = '',
    this.actor = '',
    this.actorName = '',
    this.reason = '',
    this.createdAt = '',
  });

  final String id;
  final String runId;
  final String fromStatus;
  final String toStatus;
  final String actor;
  final String actorName;
  final String reason;
  final String createdAt;

  factory AgentRunEvent.fromJson(Map<String, dynamic> json) => AgentRunEvent(
        id: (json['id'] as String?) ?? '',
        runId: (json['run_id'] as String?) ?? '',
        fromStatus: (json['from_status'] as String?) ?? '',
        toStatus: (json['to_status'] as String?) ?? '',
        actor: (json['actor'] as String?) ?? '',
        actorName: (json['actor_name'] as String?) ?? '',
        reason: (json['reason'] as String?) ?? '',
        createdAt: (json['created_at'] as String?) ?? '',
      );
}

/// 一筆 run 與它的稽核串（`GET /api/runs/{id}`）。
@immutable
class AgentRunDetail {
  const AgentRunDetail({required this.run, this.events = const []});

  final AgentRun run;
  final List<AgentRunEvent> events;

  factory AgentRunDetail.fromJson(Map<String, dynamic> json) => AgentRunDetail(
        run: AgentRun.fromJson(
            Map<String, dynamic>.from((json['run'] as Map?) ?? const {})),
        events: [
          for (final e in (json['events'] as List?) ?? const [])
            AgentRunEvent.fromJson(Map<String, dynamic>.from(e as Map)),
        ],
      );
}

/// 一顆還沒推上去的 commit（`dashboard.repos[].unpushed[]`）。
@immutable
class UnpushedCommit {
  const UnpushedCommit({this.sha = '', this.title = '', this.at = ''});

  final String sha;
  final String title;
  final String at;

  /// 畫面上的短碼。**送 push run 時仍然送完整的 `sha`**——縮短是給人看的。
  String get shortSha => sha.length > 8 ? sha.substring(0, 8) : sha;

  factory UnpushedCommit.fromJson(Map<String, dynamic> json) => UnpushedCommit(
        sha: (json['sha'] as String?) ?? '',
        title: (json['title'] as String?) ?? '',
        at: (json['at'] as String?) ?? '',
      );
}

/// 一個 repo 在儀表板上的樣子。
@immutable
class RepoView {
  const RepoView({
    required this.key,
    this.path = '',
    this.branch = '',
    this.dirty = false,
    this.dirtyCount = 0,
    this.unpushedCount = 0,
    this.unpushed = const [],
    this.pushable,
    this.error = '',
  });

  /// `<project>/<repo>`——儀表板的鍵。push run 的 `ref` 要的是 repo 名，
  /// 不是這整串（`runner/README.md`：「`push`：`ref` 就是 repo 名」）。
  final String key;
  final String path;
  final String branch;
  final bool dirty;
  final int dirtyCount;
  final int unpushedCount;
  final List<UnpushedCommit> unpushed;

  /// 這條分支在不在執行器的可推清單裡。
  ///
  /// **null ＝那台執行器沒有回報這一格**，不是「不可以推」。兩者壓成一個
  /// 布林的話，舊版執行器的每個 repo 都會長得像被禁止推送，而畫面不會說
  /// 那是因為它沒講。
  final bool? pushable;

  /// 執行器讀不到這個 repo 時放進來的原因（`dashboard.py` 刻意不丟例外）。
  final String error;

  String get repoName {
    final i = key.lastIndexOf('/');
    return i < 0 ? key : key.substring(i + 1);
  }

  String get projectKey {
    final i = key.indexOf('/');
    return i < 0 ? '' : key.substring(0, i);
  }

  bool get hasError => error.isNotEmpty;

  factory RepoView.fromJson(String key, Map<String, dynamic> json) => RepoView(
        key: key,
        path: (json['path'] as String?) ?? '',
        branch: (json['branch'] as String?) ?? '',
        dirty: (json['dirty'] as bool?) ?? false,
        dirtyCount: _asInt(json['dirty_count']),
        unpushedCount: _asInt(json['unpushed_count']),
        unpushed: [
          for (final c in (json['unpushed'] as List?) ?? const [])
            UnpushedCommit.fromJson(Map<String, dynamic>.from(c as Map)),
        ],
        // 缺這一把鍵與 `"pushable": false` 是兩件事，見欄位說明
        pushable:
            json.containsKey('pushable') ? json['pushable'] as bool? : null,
        error: (json['error'] as String?) ?? '',
      );
}

/// 近 5 小時的用量與軟上限（`dashboard.usage`）。
@immutable
class RunnerUsage {
  const RunnerUsage({
    this.windowHours = 0,
    this.tokens = 0,
    this.costUsd = 0,
    this.softCapTokens,
    this.softCapUsd,
    this.overSoftCap = false,
    this.remainingTokens,
    this.reported = false,
  });

  final double windowHours;
  final int tokens;
  final double costUsd;

  /// 軟上限。**null ＝沒有回報**（執行器沒講，或這一版沒有這一格）；
  /// 0 在執行器那端的語意是「不設上限」，兩者都不該畫成「剩 0」。
  final int? softCapTokens;
  final double? softCapUsd;
  final bool overSoftCap;

  /// 剩餘 tokens。執行器在沒有軟上限時**明確回 null**，所以這裡的 null
  /// 同時涵蓋「沒設上限」與「沒回報」——畫面兩種都寫「—」。
  final int? remainingTokens;

  /// 這一整格有沒有被回報過。沒有的話畫面要說「執行器尚未回報用量」，
  /// 而不是端出一排 0。
  final bool reported;

  factory RunnerUsage.fromJson(Map<String, dynamic> json) => RunnerUsage(
        windowHours: _asDouble(json['window_hours']),
        tokens: _asInt(json['tokens']),
        costUsd: _asDouble(json['cost_usd']),
        softCapTokens: json.containsKey('soft_cap_tokens')
            ? _asInt(json['soft_cap_tokens'])
            : null,
        softCapUsd: json.containsKey('soft_cap_usd')
            ? _asDouble(json['soft_cap_usd'])
            : null,
        overSoftCap: (json['over_soft_cap'] as bool?) ?? false,
        remainingTokens: json['remaining_tokens'] == null
            ? null
            : _asInt(json['remaining_tokens']),
        reported: json.isNotEmpty,
      );
}

/// 執行器面板上一筆進行中的 run（`dashboard.runs.running[]`）。
///
/// ⚠️ 這**不是** `agent_run`：它是執行器自己看到的那一份，帶著 Hub 沒有的
/// `turns` 與 context 估算，但少了 Hub 才有的 position／priority。
@immutable
class RunnerRunView {
  const RunnerRunView({
    required this.runId,
    this.kind = '',
    this.ref = '',
    this.project = '',
    this.repo = '',
    this.startedAt = '',
    this.turns = 0,
    this.contextTokens = 0,
  });

  final String runId;
  final String kind;
  final String ref;
  final String project;
  final String repo;
  final String startedAt;
  final int turns;
  final int contextTokens;

  factory RunnerRunView.fromJson(Map<String, dynamic> json) => RunnerRunView(
        runId: (json['run_id'] as String?) ?? '',
        kind: (json['kind'] as String?) ?? '',
        ref: (json['ref'] as String?) ?? '',
        project: (json['project'] as String?) ?? '',
        repo: (json['repo'] as String?) ?? '',
        startedAt: (json['started_at'] as String?) ?? '',
        turns: _asInt(json['turns']),
        contextTokens: _asInt(json['context_tokens']),
      );
}

/// 執行器 heartbeat 帶上來的儀表板（§4.4）。Hub 原樣存。
@immutable
class RunnerDashboard {
  const RunnerDashboard({
    this.generatedAt = '',
    this.repos = const [],
    this.usage = const RunnerUsage(),
    this.running = const [],
    this.queuedCount = 0,
    this.maxParallel = 0,
    this.version = '',
    this.startedAt = '',
    this.lastRestartReason = '',
    this.selfcheckProblems = const [],
    this.reported = false,
  });

  final String generatedAt;
  final List<RepoView> repos;
  final RunnerUsage usage;
  final List<RunnerRunView> running;
  final int queuedCount;
  final int maxParallel;
  final String version;
  final String startedAt;
  final String lastRestartReason;

  /// 執行器啟動自檢的問題（claude／GPG／repo）。有東西時面板要講出來——
  /// 它是「這台在線上但做不了事」的唯一線索。
  final List<String> selfcheckProblems;

  /// 有沒有收過任何一次 heartbeat 的儀表板。false ＝這台執行器還沒回報過，
  /// 畫面要說的是「尚未回報」而不是「沒有 repo」。
  final bool reported;

  factory RunnerDashboard.fromJson(Map<String, dynamic> json) {
    final repos = <RepoView>[];
    final raw = json['repos'];
    if (raw is Map) {
      final keys = raw.keys.map((k) => '$k').toList()..sort();
      for (final k in keys) {
        final v = raw[k];
        if (v is Map) {
          repos.add(RepoView.fromJson(k, Map<String, dynamic>.from(v)));
        }
      }
    }
    final runs = json['runs'] is Map
        ? Map<String, dynamic>.from(json['runs'] as Map)
        : const <String, dynamic>{};
    final runner = json['runner'] is Map
        ? Map<String, dynamic>.from(json['runner'] as Map)
        : const <String, dynamic>{};
    return RunnerDashboard(
      generatedAt: (json['generated_at'] as String?) ?? '',
      repos: repos,
      usage: RunnerUsage.fromJson(json['usage'] is Map
          ? Map<String, dynamic>.from(json['usage'] as Map)
          : const {}),
      running: [
        for (final r in (runs['running'] as List?) ?? const [])
          RunnerRunView.fromJson(Map<String, dynamic>.from(r as Map)),
      ],
      queuedCount: _asInt(runs['queued_count']),
      maxParallel: _asInt(runs['max_parallel']),
      version: (runner['version'] as String?) ?? '',
      startedAt: (runner['started_at'] as String?) ?? '',
      lastRestartReason: (runner['last_restart_reason'] as String?) ?? '',
      selfcheckProblems: [
        for (final p in (runner['selfcheck_problems'] as List?) ?? const [])
          '$p',
      ],
      reported: json.isNotEmpty,
    );
  }
}

/// 對執行器下過的一道命令（`runners[].commands[]`，最近 5 筆、新到舊）。
///
/// ⚠️ 三個時間戳是**三個不同的事實**，畫面上不能壓成一句「已送出」：
/// - `ackedAt` 空＝執行器還沒領到（heartbeat 每 30 秒才來一次）。
/// - `ackedAt` 有、`appliedAt` 空＝它收到了但還沒生效（restart 會等手上的
///   run 跑完），`note` 是它自己講的等待原因。
/// - `appliedAt` 有＝真的生效了。
///
/// 把前兩者講成「已生效」，人就會在機器還在跑時去做下一件事。
@immutable
class RunnerCommandInfo {
  const RunnerCommandInfo({
    required this.id,
    this.command = '',
    this.issuedByName = '',
    this.createdAt = '',
    this.ackedAt = '',
    this.appliedAt = '',
    this.note = '',
  });

  final String id;

  /// pause | resume | restart | drain。
  final String command;
  final String issuedByName;
  final String createdAt;

  /// 執行器領到的時間。空＝還沒領到。
  final String ackedAt;

  /// 真的生效的時間。空＝還沒生效。
  final String appliedAt;

  /// 執行器的一句話（等待原因，或生效後的結果）。
  final String note;

  bool get isAcked => ackedAt.isNotEmpty;
  bool get isApplied => appliedAt.isNotEmpty;

  DateTime? get appliedTime => DateTime.tryParse(appliedAt);

  factory RunnerCommandInfo.fromJson(Map<String, dynamic> json) =>
      RunnerCommandInfo(
        id: (json['id'] as String?) ?? '',
        command: (json['command'] as String?) ?? '',
        issuedByName: (json['issued_by_name'] as String?) ?? '',
        createdAt: (json['created_at'] as String?) ?? '',
        ackedAt: (json['acked_at'] as String?) ?? '',
        appliedAt: (json['applied_at'] as String?) ?? '',
        note: (json['note'] as String?) ?? '',
      );
}

/// 一道已生效的命令還要在畫面上留多久。
///
/// 生效的那一瞬間畫面多半還沒重新整理，所以「剛剛生效」要留一段時間讓按下
/// 按鈕的人看得到；留太久則會讓下一次按鈕的回饋與上一道混在一起。
const Duration kRunnerCommandFreshWindow = Duration(minutes: 2);

/// 一台執行器。鍵集合＝Hub 的 `RUNNER_KEYS`。
@immutable
class AgentRunner {
  const AgentRunner({
    required this.id,
    this.host = '',
    this.label = '',
    this.status = 'offline',
    this.maxParallel = 0,
    this.runningCount = 0,
    this.projects = const [],
    this.limitedUntil,
    this.limitReason = '',
    this.usageWindow = const {},
    this.dashboard = const RunnerDashboard(),
    this.commands = const [],
    this.version = '',
    this.registeredAt = '',
    this.lastSeenAt = '',
  });

  final String id;
  final String host;
  final String label;

  /// online | paused | limited | restarting | offline。
  ///
  /// `restarting` 是「它自己說它要重開了」：那段時間它既不是在線、也不是
  /// 掉線——畫成 OFFLINE 的話，人會以為那台機器出事了。
  final String status;
  final int maxParallel;

  /// ⚠️ **最近一次 heartbeat 回報的**，可能落後一個週期（§4.3）。
  final int runningCount;

  /// 這台服務的 project key。**白名單**：空的領不到任何單，所以派工對話框
  /// 的專案選項就是這一份的聯集。
  final List<String> projects;
  final String? limitedUntil;
  final String limitReason;
  final Map<String, dynamic> usageWindow;
  final RunnerDashboard dashboard;

  /// 最近下過的幾道命令，**新到舊**（Hub 回 5 筆）。
  final List<RunnerCommandInfo> commands;
  final String version;
  final String registeredAt;
  final String lastSeenAt;

  bool get isOnline => status == 'online';
  bool get isLimited => status == 'limited';
  bool get isPaused => status == 'paused';
  bool get isOffline => status == 'offline';
  bool get isRestarting => status == 'restarting';

  /// 還沒生效的命令是哪幾種。
  ///
  /// 同一種再按一次不會更快——命令要等下一次 heartbeat 才被領走，連按只會
  /// 在 Hub 那邊堆出好幾道一樣的命令。
  Set<String> get pendingCommands => {
        for (final c in commands)
          if (!c.isApplied) c.command,
      };

  /// 現在該在面板上講哪一道命令。
  ///
  /// 沒生效的最新一道優先；都生效了就挑 [kRunnerCommandFreshWindow] 內剛
  /// 生效的那道。都沒有就回 null——面板少一行，而不是留一句過期的話。
  RunnerCommandInfo? visibleCommand({DateTime? now}) {
    for (final c in commands) {
      if (!c.isApplied) return c;
    }
    final ref = now ?? DateTime.now();
    for (final c in commands) {
      final at = c.appliedTime;
      if (at == null) continue;
      final diff = ref.difference(at);
      // 負的＝兩邊的鐘差了一點，那也是「剛剛」
      if (diff.isNegative || diff <= kRunnerCommandFreshWindow) return c;
    }
    return null;
  }

  String get displayName => label.isEmpty ? host : '$host · $label';

  /// limited 還要多久退避完。
  ///
  /// 算不出來（沒有 `limited_until`、或字串解不動）時回 null——**畫面不編
  /// 一個倒數出來**：一個在跑的倒數與「不知道要等多久」看起來完全不同，
  /// 而後者才是這時候的事實。
  Duration? remainingLimit({DateTime? now}) {
    final until = limitedUntil;
    if (until == null || until.isEmpty) return null;
    final at = DateTime.tryParse(until);
    if (at == null) return null;
    final diff = at.difference(now ?? DateTime.now().toUtc());
    return diff.isNegative ? Duration.zero : diff;
  }

  factory AgentRunner.fromJson(Map<String, dynamic> json) => AgentRunner(
        id: (json['id'] as String?) ?? '',
        host: (json['host'] as String?) ?? '',
        label: (json['label'] as String?) ?? '',
        status: (json['status'] as String?) ?? 'offline',
        maxParallel: _asInt(json['max_parallel']),
        runningCount: _asInt(json['running_count']),
        projects: [
          for (final p in (json['projects'] as List?) ?? const []) '$p',
        ],
        limitedUntil: json['limited_until'] as String?,
        limitReason: (json['limit_reason'] as String?) ?? '',
        usageWindow: json['usage_window'] is Map
            ? Map<String, dynamic>.from(json['usage_window'] as Map)
            : const {},
        dashboard: RunnerDashboard.fromJson(json['dashboard'] is Map
            ? Map<String, dynamic>.from(json['dashboard'] as Map)
            : const {}),
        commands: [
          for (final c in (json['commands'] as List?) ?? const [])
            RunnerCommandInfo.fromJson(Map<String, dynamic>.from(c as Map)),
        ],
        version: (json['version'] as String?) ?? '',
        registeredAt: (json['registered_at'] as String?) ?? '',
        lastSeenAt: (json['last_seen_at'] as String?) ?? '',
      );

  @override
  bool operator ==(Object other) => other is AgentRunner && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// `GET /api/rooms/{id}/runner` 的整包。
@immutable
class RoomRunnerBoard {
  const RoomRunnerBoard({
    this.roomId = '',
    this.runners = const [],
    this.counts = const {},
    this.queued = 0,
    this.running = 0,
    this.activeRuns = const [],
  });

  final String roomId;

  /// ⚠️ Hub 第一階段**不做 project→房 的對應**：這裡是所有非 offline 的
  /// 執行器，不是「這間房的」。畫面上不要寫成後者。
  final List<AgentRunner> runners;
  final Map<String, int> counts;
  final int queued;
  final int running;

  /// queued / claimed / running / limited，按 priority DESC + position ASC。
  final List<AgentRun> activeRuns;

  /// 執行器宣告過的 project key（派工對話框的下拉）。
  ///
  /// **來源是執行器而不是 App 寫死的清單**：Hub 建單時會用同一份資料判
  /// `project_not_served`，兩邊各寫一份的話，畫面上選得到的專案會被 Hub 退。
  List<String> get servedProjects {
    final keys = <String>{};
    for (final r in runners) {
      if (r.isOffline) continue;
      keys.addAll(r.projects);
    }
    final list = keys.toList()..sort();
    return list;
  }

  /// 面板頂部那條狀態列該不該出現：有人 limited、或（在有執行器的前提下）
  /// 沒有任何一台在線。
  bool get hasAlert =>
      runners.any((r) => r.isLimited || r.isOffline) ||
      runners.every((r) => !r.isOnline);

  factory RoomRunnerBoard.fromJson(Map<String, dynamic> json) =>
      RoomRunnerBoard(
        roomId: (json['room_id'] as String?) ?? '',
        runners: [
          for (final r in (json['runners'] as List?) ?? const [])
            AgentRunner.fromJson(Map<String, dynamic>.from(r as Map)),
        ],
        counts: {
          for (final e in ((json['counts'] as Map?) ?? const {}).entries)
            '${e.key}': _asInt(e.value),
        },
        queued: _asInt(json['queued']),
        running: _asInt(json['running']),
        activeRuns: [
          for (final r in (json['active_runs'] as List?) ?? const [])
            AgentRun.fromJson(Map<String, dynamic>.from(r as Map)),
        ],
      );
}

/// 儀表板「推送」鈕要送出去的 brief（§5.6）。
///
/// 形狀由執行器那端解析（`runner/chatroom_runner/run.py` 的 `_push`）：
/// 第一行 `branch: <分支>`，其後**每行一個 sha**。執行器會把清單與它當下
/// 看到的 `origin/<branch>..<branch>` 比對，**顆數與內容都要一樣才推**；
/// 對不上就拒絕並要人重新整理面板。
///
/// ⚠️ 所以這串字一定要從**畫面上當下那份清單**組出來，不能讓人手打：
/// 手打的那份與畫面上的那份一旦不同，推上去的就不是他看到的那幾顆。
String buildPushBrief(String branch, Iterable<String> shas) {
  final lines = <String>['branch: ${branch.trim()}'];
  for (final s in shas) {
    final v = s.trim();
    if (v.isNotEmpty) lines.add(v);
  }
  return lines.join('\n');
}

int _asInt(dynamic v) {
  if (v is int) return v;
  if (v is double) return v.round();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

double _asDouble(dynamic v) {
  if (v is double) return v;
  if (v is int) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0;
  return 0;
}
