import 'package:flutter/material.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../core/util/relative_time.dart';
import '../../models/agent_run.dart';
import '../../widgets/kind_badge.dart';

/// 執行儀表板的畫面本體（REMOTE-OPS-PLAN §4.4）。
///
/// **與取資料的那一層分開**是為了讓它測得起來：三種執行器狀態、有沒有未推送
/// 的 commit，這些分支只有在能把一份 [RoomRunnerBoard] 直接餵進來時才驗得了。
/// 走 provider 的那一版在 `ops_dashboard_screen.dart`。
class OpsDashboardView extends StatelessWidget {
  const OpsDashboardView({
    super.key,
    required this.board,
    this.finished = const [],
    this.onCommand,
    this.onPush,
    this.onCancel,
    this.busyRunnerId,
    this.now,
  });

  final RoomRunnerBoard board;

  /// 最近結束的幾筆。空的就整段不畫——「最近沒有」與「這一區壞了」不必
  /// 佔一個標題去說。
  final List<AgentRun> finished;

  /// 對執行器下命令（pause / resume / restart / drain）。
  ///
  /// null ＝這個畫面不給下命令（例如唯讀的預覽）。**不是變灰**：
  /// 整顆不畫，因為那時連「為什麼不能按」都沒有答案可講。
  final void Function(AgentRunner runner, String command)? onCommand;

  /// 推送一個 repo。帶著**畫面上當下那份 sha 清單**——執行器會拿它跟自己
  /// 看到的比對，對不上就不推（§5.6）。
  final void Function(AgentRunner runner, RepoView repo)? onPush;

  final void Function(AgentRun run)? onCancel;

  /// 正在等這台執行器的命令送完。按鈕暫時停用，避免連按五次。
  final String? busyRunnerId;

  /// 測試用的「現在」。命令進度那一行會隨時間變，而驗一個會自己走的時鐘
  /// 驗不出東西。
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    if (board.runners.isEmpty) {
      return const _Empty(
        title: '沒有執行器在線',
        subtitle: '派工會排在佇列裡等一台不會來的執行器，所以 Hub 會直接擋下建單。\n'
            '請確認那台機器上的執行器已經啟動。',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 32),
      children: [
        OpsStatusBar(board: board, now: now),
        for (final runner in board.runners) ...[
          _RunnerSection(
            runner: runner,
            onCommand: onCommand,
            onPush: onPush,
            busy: busyRunnerId == runner.id,
            now: now,
          ),
          const SizedBox(height: 22),
        ],
        _QueueSection(board: board, onCancel: onCancel),
        if (finished.isNotEmpty) ...[
          const SizedBox(height: 22),
          _FinishedSection(runs: finished),
        ],
      ],
    );
  }
}

/// ops 房頂部那一條。
///
/// §7 說 run 的狀態變化以 system 訊息進訊息流，**這條不是第二套通知**：
/// 它只講「現在」——limited 還在退避、某台執行器離線。訊息流講的是那件事
/// 發生過，兩者回答的是不同的問題。
class OpsStatusBar extends StatelessWidget {
  const OpsStatusBar({super.key, required this.board, this.now});

  final RoomRunnerBoard board;

  /// 測試用的「現在」。倒數要能驗，而驗一個會自己走的時鐘驗不出東西。
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final lines = <String>[];
    for (final r in board.runners) {
      if (r.isLimited) {
        final left = r.remainingLimit(now: now);
        final reason = r.limitReason.isEmpty ? '額度' : _limitReason(r.limitReason);
        lines.add(left == null
            ? '${r.displayName}：因$reason暫停收單，退避時間未知'
            : '${r.displayName}：因$reason暫停收單，約 ${_short(left)}後重試');
      } else if (r.isOffline) {
        lines.add('${r.displayName}：離線，最後回報 ${relativeTime(r.lastSeenAt)}');
      } else if (r.isPaused) {
        lines.add('${r.displayName}：已暫停，跑完手上的就不再領新單');
      }
      for (final p in r.dashboard.selfcheckProblems) {
        lines.add('${r.displayName}：自檢未過 — $p');
      }
    }
    if (lines.isEmpty) return const SizedBox.shrink();
    final s = context.uep;
    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: s.bgSunken,
        border: Border.all(color: UepColors.gold),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(line,
                  style: UepText.serif(size: 12.5, color: s.ink, height: 1.5)),
            ),
        ],
      ),
    );
  }
}

class _RunnerSection extends StatelessWidget {
  const _RunnerSection({
    required this.runner,
    required this.busy,
    this.onCommand,
    this.onPush,
    this.now,
  });

  final AgentRunner runner;
  final bool busy;
  final DateTime? now;
  final void Function(AgentRunner runner, String command)? onCommand;
  final void Function(AgentRunner runner, RepoView repo)? onPush;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final dash = runner.dashboard;
    final pending = runner.pendingCommands;
    final progress = runnerCommandProgress(runner, now: now);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: s.bgCard,
        border: Border.all(color: s.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(runner.displayName,
                  style: UepText.sans(
                      size: 14, weight: FontWeight.w600, color: s.inkTitle)),
            ),
            _StatusPill(runner: runner),
          ]),
          const SizedBox(height: 4),
          Text(
            [
              '併行 ${runner.runningCount} / ${runner.maxParallel}',
              if (runner.version.isNotEmpty) 'v${runner.version}',
              '最後回報 ${relativeTime(runner.lastSeenAt, now: now)}',
              // 啟動時間是判斷「它重開過了沒有」的那一格：restart 生效後這
              // 個值會變新，而 status 只會在離線與在線之間跳
              if (dash.startedAt.isNotEmpty)
                '啟動 ${relativeTime(dash.startedAt, now: now)}',
              if (dash.lastRestartReason.isNotEmpty)
                '上次重啟：${_restartReason(dash.lastRestartReason)}',
            ].join(' · '),
            style: UepText.mono(size: 9.5, color: s.inkMute),
          ),
          if (onCommand != null) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              // 命令是**存下來等 heartbeat 取的**，不是即時推送——按鈕的
              // 回饋要說「已送出」，說「已暫停」會讓人以為機器已經停了。
              // 同一種命令還沒生效就停用那一顆：再按一次不會更快，只會在
              // Hub 那邊堆出好幾道一模一樣的命令
              _SmallButton(
                  label: '暫停',
                  enabled:
                      !busy && !runner.isPaused && !pending.contains('pause'),
                  onTap: () => onCommand!(runner, 'pause')),
              _SmallButton(
                  label: '恢復',
                  enabled:
                      !busy && runner.isPaused && !pending.contains('resume'),
                  onTap: () => onCommand!(runner, 'resume')),
              _SmallButton(
                  label: '重啟',
                  enabled: !busy && !pending.contains('restart'),
                  onTap: () => onCommand!(runner, 'restart')),
              _SmallButton(
                  label: '清空佇列',
                  enabled: !busy && !pending.contains('drain'),
                  onTap: () => onCommand!(runner, 'drain')),
            ]),
          ],
          if (progress != null) ...[
            const SizedBox(height: 10),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              MonoLabel('命令進度', letterSpacing: 1.6),
              const SizedBox(width: 10),
              Expanded(
                child: Text(progress,
                    style:
                        UepText.serif(size: 11.5, color: s.ink, height: 1.5)),
              ),
            ]),
          ],
          const SizedBox(height: 16),
          _UsageRow(usage: dash.usage),
          const SizedBox(height: 16),
          MonoLabel('REPOS', letterSpacing: 1.6),
          const SizedBox(height: 8),
          if (!dash.reported)
            Text('這台執行器還沒有回報過儀表板。',
                style: UepText.mono(size: 10, color: s.inkMute))
          else if (dash.repos.isEmpty)
            Text('這台執行器沒有宣告任何 repo。',
                style: UepText.mono(size: 10, color: s.inkMute))
          else
            for (final repo in dash.repos)
              _RepoTile(
                repo: repo,
                onPush: onPush == null ? null : () => onPush!(runner, repo),
              ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.runner});

  final AgentRunner runner;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final (label, color) = switch (runner.status) {
      'online' => ('ONLINE', UepColors.gold),
      'paused' => ('PAUSED', s.inkSoft),
      'limited' => ('LIMITED', UepColors.error),
      // 重啟中既不是在線也不是掉線：用 info 這一色，免得與「它掛了」同貌
      'restarting' => ('RESTARTING', UepColors.info),
      _ => ('OFFLINE', s.inkMute),
    };
    final left = runner.isLimited ? runner.remainingLimit() : null;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(border: Border.all(color: color)),
        child: MonoLabel(label, size: 9, color: color, letterSpacing: 1.4),
      ),
      if (runner.isLimited) ...[
        const SizedBox(width: 8),
        // 算不出來時說「退避時間未知」，**不編一個倒數**
        Text(left == null ? '退避時間未知' : '約 ${_short(left)}後重試',
            style: UepText.mono(size: 9.5, color: s.inkSoft)),
      ],
      if (runner.isOffline) ...[
        const SizedBox(width: 8),
        Text('離線 ${relativeTime(runner.lastSeenAt)}',
            style: UepText.mono(size: 9.5, color: s.inkMute)),
      ],
    ]);
  }
}

class _UsageRow extends StatelessWidget {
  const _UsageRow({required this.usage});

  final RunnerUsage usage;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    if (!usage.reported) {
      return Text('執行器尚未回報用量。',
          style: UepText.mono(size: 10, color: s.inkMute));
    }
    final hours = usage.windowHours == 0
        ? ''
        : '近 ${_num(usage.windowHours)} 小時';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MonoLabel('USAGE', letterSpacing: 1.6),
        const SizedBox(height: 6),
        Text(
          '$hours ${usage.tokens} tokens · '
          '\$${usage.costUsd.toStringAsFixed(2)}',
          style: UepText.sans(size: 12.5, color: s.ink),
        ),
        const SizedBox(height: 3),
        Text(
          // 沒回報軟上限就說沒回報。0 在執行器那端是「不設上限」，
          // 兩者都不能畫成「剩 0」——那會讓人以為額度用完了
          usage.softCapTokens == null
              ? '軟上限：執行器未回報'
              : usage.softCapTokens == 0
                  ? '軟上限：未設定'
                  : '軟上限 ${usage.softCapTokens} tokens'
                      '${usage.remainingTokens == null ? '' : '，剩 ${usage.remainingTokens}'}',
          style: UepText.mono(
              size: 9.5,
              color: usage.overSoftCap ? UepColors.error : s.inkMute),
        ),
        if (usage.overSoftCap)
          Text('已達軟上限，這台暫時不再領新單。',
              style: UepText.mono(size: 9.5, color: UepColors.error)),
      ],
    );
  }
}

class _RepoTile extends StatelessWidget {
  const _RepoTile({required this.repo, this.onPush});

  final RepoView repo;
  final VoidCallback? onPush;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    // 推送鈕要不要能按，三個條件缺一不可：有東西可推、分支在可推清單裡、
    // 而且**執行器真的回報過那一格**（null ≠ false，見 RepoView.pushable）
    final hasCommits = repo.unpushedCount > 0;
    final pushable = repo.pushable;
    final canPush = onPush != null && hasCommits && pushable == true;
    final String? blocked = !hasCommits
        ? null
        : pushable == null
            ? '執行器沒有回報這條分支能不能推，先確認它的版本'
            : pushable == false
                ? '分支「${repo.branch}」不在執行器的可推清單裡'
                : null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(repo.key,
                  style: UepText.sans(
                      size: 12.5, weight: FontWeight.w600, color: s.ink)),
            ),
            if (canPush)
              _SmallButton(
                  label: '推送 ${repo.unpushedCount} 顆',
                  enabled: true,
                  onTap: onPush!),
          ]),
          const SizedBox(height: 3),
          if (repo.hasError)
            Text(repo.error,
                style: UepText.mono(size: 9.5, color: UepColors.error))
          else ...[
            Row(children: [
              Text(repo.branch.isEmpty ? '（無分支）' : repo.branch,
                  style: UepText.mono(size: 9.5, color: s.inkSoft)),
              const SizedBox(width: 10),
              Text(
                hasCommits ? '未推送 ${repo.unpushedCount} 顆' : '沒有未推送的 commit',
                style: UepText.mono(
                    size: 9.5,
                    color: hasCommits ? UepColors.gold : s.inkMute),
              ),
              if (repo.dirty) ...[
                const SizedBox(width: 10),
                Text('工作樹有未提交的變更',
                    style: UepText.mono(size: 9.5, color: UepColors.error)),
              ],
            ]),
            for (final c in repo.unpushed)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 2),
                child: Row(children: [
                  Text(c.shortSha,
                      style: UepText.mono(size: 9.5, color: UepColors.gold)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(c.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: UepText.serif(size: 11.5, color: s.inkSoft)),
                  ),
                  const SizedBox(width: 8),
                  Text(relativeTime(c.at),
                      style: UepText.mono(size: 9, color: s.inkMute)),
                ]),
              ),
            if (blocked != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(blocked,
                    style: UepText.mono(size: 9.5, color: s.inkMute)),
              ),
          ],
        ],
      ),
    );
  }
}

class _QueueSection extends StatelessWidget {
  const _QueueSection({required this.board, this.onCancel});

  final RoomRunnerBoard board;
  final void Function(AgentRun run)? onCancel;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final running = board.activeRuns.where((r) => !r.isQueued).toList();
    final queued = board.activeRuns.where((r) => r.isQueued).toList();
    // 執行器那份 running view 帶著 Hub 沒有的 turns 與 context 估算
    final views = <String, RunnerRunView>{
      for (final r in board.runners)
        for (final v in r.dashboard.running) v.runId: v,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MonoLabel('QUEUE', letterSpacing: 1.6),
        const SizedBox(height: 8),
        if (running.isEmpty && queued.isEmpty)
          Text('目前沒有進行中或排隊中的派工。',
              style: UepText.mono(size: 10, color: s.inkMute)),
        for (final run in running)
          _RunTile(run: run, view: views[run.id], onCancel: onCancel),
        for (var i = 0; i < queued.length; i++)
          _RunTile(
              run: queued[i],
              position: i + 1,
              onCancel: onCancel),
      ],
    );
  }
}

class _RunTile extends StatelessWidget {
  const _RunTile({
    required this.run,
    this.view,
    this.position,
    this.onCancel,
  });

  final AgentRun run;
  final RunnerRunView? view;

  /// 排隊中的第幾位。**畫面算的，不是 Hub 的 `position`**——後者是
  /// 建單流水號，中間取消掉幾筆之後它就不是「你排第幾」了。
  final int? position;
  final void Function(AgentRun run)? onCancel;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final meta = <String>[
      run.kind,
      if (run.ref.isNotEmpty) run.ref,
      if (position != null) '排隊第 $position 位',
      if (run.priority > 0) '優先 ${run.priority}',
      if (run.startedAt != null) '開始 ${relativeTime(run.startedAt)}',
      if (view != null) '${view!.turns} turns',
      if (view != null && view!.contextTokens > 0)
        'context 約 ${view!.contextTokens}',
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: s.bgCard,
        border: Border.all(color: s.line),
      ),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text(run.status,
                    style: UepText.mono(
                        size: 9.5,
                        letterSpacing: 1.4,
                        color: run.isQueued ? s.inkMute : UepColors.gold)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(run.id,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: UepText.mono(size: 9.5, color: s.inkSoft)),
                ),
              ]),
              const SizedBox(height: 3),
              Text(meta.join(' · '),
                  style: UepText.mono(size: 9, color: s.inkMute)),
              // 🔴 running 的取消**不改狀態**（§4.2）：進程還在跑，這裡說
              // 「已取消」的話，畫面會與機器上正在寫檔的那個 agent 對不上
              if (run.cancelRequested && !run.isQueued)
                Text('已要求取消，等執行器收到後停止',
                    style: UepText.mono(size: 9, color: UepColors.error)),
            ],
          ),
        ),
        if (onCancel != null && !run.cancelRequested)
          _SmallButton(
              label: '取消', enabled: true, onTap: () => onCancel!(run)),
      ]),
    );
  }
}

class _FinishedSection extends StatelessWidget {
  const _FinishedSection({required this.runs});

  final List<AgentRun> runs;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MonoLabel('最近結束', letterSpacing: 1.6),
        const SizedBox(height: 8),
        for (final run in runs)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${run.status} · ${run.kind}'
                  '${run.ref.isEmpty ? '' : ' · ${run.ref}'}'
                  ' · ${relativeTime(run.endedAt ?? run.updatedAt)}',
                  style: UepText.mono(size: 9.5, color: s.inkSoft),
                ),
                if (run.result.isNotEmpty)
                  Text(run.result,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: UepText.serif(
                          size: 11.5, color: s.inkMute, height: 1.5)),
              ],
            ),
          ),
      ],
    );
  }
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: enabled ? s.lineStrong : s.line),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(label,
            style: UepText.mono(
                size: 10,
                letterSpacing: 1.2,
                color: enabled ? s.ink : s.inkMute)),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(title, style: UepText.sans(size: 14, color: s.inkTitle)),
          const SizedBox(height: 8),
          Text(subtitle,
              textAlign: TextAlign.center,
              style:
                  UepText.serif(size: 12.5, color: s.inkMute, height: 1.6)),
        ]),
      ),
    );
  }
}

/// 命令進度那一行。沒有東西要講時回 null——面板少一行，而不是留一句過期的話。
///
/// 三個時間戳要講成三句不同的話（見 [RunnerCommandInfo]）：還沒領到、領到了
/// 還沒生效、已經生效。restart 另有第四種狀態——**生效之後那台機器會消失
/// 1～2 分鐘**，那段離線是預期中的，畫成故障會讓人跑去看一台正在正常重開的
/// 機器。
String? runnerCommandProgress(AgentRunner runner, {DateTime? now}) {
  final c = runner.visibleCommand(now: now);
  if (c == null) return null;
  final label = runnerCommandLabel(c.command);
  if (!c.isAcked) {
    return '$label：已送出 ${relativeTime(c.createdAt, now: now)}，'
        '等執行器領取（最多 30 秒）';
  }
  if (!c.isApplied) {
    // note 是執行器講的等待原因（「等 N 筆 run 結束後重啟」）。它沒講就不要
    // 替它編一個
    return c.note.isEmpty
        ? '$label：執行器已收到，還沒生效'
        : '$label：執行器已收到，${c.note}';
  }
  if (c.command == 'restart') {
    final applied = c.appliedTime;
    final started = DateTime.tryParse(runner.dashboard.startedAt);
    // started_at 比 applied_at 新＝它已經重開完回來了
    if (applied != null && started != null && started.isAfter(applied)) {
      return '已重啟完成，啟動 '
          '${relativeTime(runner.dashboard.startedAt, now: now)}';
    }
    if (runner.isRestarting || runner.isOffline) {
      return '重啟中，等它回來（通常 1～2 分鐘）';
    }
  }
  final at = relativeTime(c.appliedAt, now: now);
  return c.note.isEmpty ? '$label：已生效 $at' : '$label：已生效 $at，${c.note}';
}

/// 命令的中文名。**與 `ops_actions` 的提示是同一份**——同一道命令在按鈕、
/// 提示與進度上叫三個名字的話，人會以為那是三件事。
String runnerCommandLabel(String command) => switch (command) {
      'pause' => '暫停',
      'resume' => '恢復',
      'restart' => '重啟',
      'drain' => '清空佇列',
      _ => command,
    };

/// 執行器回報的重啟原因。認不得的原樣顯示——編一個對照不到的中文，等於把
/// 「它講了一個我不認識的原因」蓋掉。
String _restartReason(String reason) => switch (reason) {
      'restart_command' => '人類下令',
      'maintenance' => '維護窗',
      _ => reason,
    };

String _limitReason(String reason) => switch (reason) {
      'rate_limit' => '速率限制',
      'weekly_limit' => '週上限',
      'manual' => '人工暫停',
      _ => reason,
    };

String _short(Duration d) {
  if (d.inMinutes < 1) return '${d.inSeconds} 秒';
  if (d.inHours < 1) return '${d.inMinutes} 分';
  return '${d.inHours} 小時 ${d.inMinutes % 60} 分';
}

String _num(double v) =>
    v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);
