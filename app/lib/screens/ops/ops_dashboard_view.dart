import 'package:flutter/material.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../core/util/relative_time.dart';
import '../../l10n/l10n.dart';
import '../../models/agent_run.dart';
import '../../widgets/kind_badge.dart';
import '../../widgets/markdown_body.dart';
import '../../widgets/run_report_panel.dart';

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
    this.onSoftStop,
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

  /// 請執行中的 run 收尾（軟停止）。
  final void Function(AgentRun run)? onSoftStop;

  /// 正在等這台執行器的命令送完。按鈕暫時停用，避免連按五次。
  final String? busyRunnerId;

  /// 測試用的「現在」。命令進度那一行會隨時間變，而驗一個會自己走的時鐘
  /// 驗不出東西。
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    if (board.runners.isEmpty) {
      final l10n = AppLocalizations.of(context);
      return _Empty(
        title: l10n.opsNoRunnersTitle,
        subtitle: l10n.opsNoRunnersSubtitle,
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
        _QueueSection(
            board: board,
            onCancel: onCancel,
            onSoftStop: onSoftStop,
            now: now),
        if (finished.isNotEmpty) ...[
          const SizedBox(height: 22),
          _FinishedSection(runs: finished, now: now),
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
    final l10n = AppLocalizations.of(context);
    final lines = <String>[];
    for (final r in board.runners) {
      if (r.isLimited) {
        final left = r.remainingLimit(now: now);
        final reason = r.limitReason.isEmpty
            ? l10n.opsLimitReasonFallback
            : _limitReason(r.limitReason);
        lines.add(left == null
            ? l10n.opsStatusLimitedUnknown(r.displayName, reason)
            : l10n.opsStatusLimitedRetry(r.displayName, reason, _short(left)));
      } else if (r.isOffline) {
        lines.add(
            l10n.opsStatusOffline(r.displayName, relativeTime(r.lastSeenAt)));
      } else if (r.isPaused) {
        lines.add(l10n.opsStatusPaused(r.displayName));
      }
      for (final p in r.dashboard.selfcheckProblems) {
        lines.add(l10n.opsStatusSelfcheck(r.displayName, p));
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
                  style: UepText.serif(size: 13.5, color: s.ink, height: 1.5)),
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
    final l10n = AppLocalizations.of(context);
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
                      size: 15, weight: FontWeight.w600, color: s.inkTitle)),
            ),
            _StatusPill(runner: runner),
          ]),
          const SizedBox(height: 4),
          Text(
            [
              l10n.opsMetaParallel(runner.runningCount, runner.maxParallel),
              if (runner.version.isNotEmpty) 'v${runner.version}',
              l10n.opsMetaLastSeen(relativeTime(runner.lastSeenAt, now: now)),
              // 啟動時間是判斷「它重開過了沒有」的那一格：restart 生效後這
              // 個值會變新，而 status 只會在離線與在線之間跳
              if (dash.startedAt.isNotEmpty)
                l10n.opsMetaStarted(relativeTime(dash.startedAt, now: now)),
              if (dash.lastRestartReason.isNotEmpty)
                l10n.opsMetaLastRestart(
                    _restartReason(dash.lastRestartReason)),
            ].join(' · '),
            style: UepText.mono(size: 10.5, color: s.inkMute),
          ),
          if (onCommand != null) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              // 命令是**存下來等 heartbeat 取的**，不是即時推送——按鈕的
              // 回饋要說「已送出」，說「已暫停」會讓人以為機器已經停了。
              // 同一種命令還沒生效就停用那一顆：再按一次不會更快，只會在
              // Hub 那邊堆出好幾道一模一樣的命令
              _SmallButton(
                  label: l10n.opsCommandPause,
                  enabled:
                      !busy && !runner.isPaused && !pending.contains('pause'),
                  onTap: () => onCommand!(runner, 'pause')),
              _SmallButton(
                  label: l10n.opsCommandResume,
                  enabled:
                      !busy && runner.isPaused && !pending.contains('resume'),
                  onTap: () => onCommand!(runner, 'resume')),
              _SmallButton(
                  label: l10n.opsCommandRestart,
                  enabled: !busy && !pending.contains('restart'),
                  onTap: () => onCommand!(runner, 'restart')),
              _SmallButton(
                  label: l10n.opsCommandDrain,
                  enabled: !busy && !pending.contains('drain'),
                  onTap: () => onCommand!(runner, 'drain')),
            ]),
          ],
          if (progress != null) ...[
            const SizedBox(height: 10),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              MonoLabel(l10n.opsCommandProgressLabel,
                  size: 11.5, letterSpacing: 1.6),
              const SizedBox(width: 10),
              Expanded(
                child: Text(progress,
                    style:
                        UepText.serif(size: 12.5, color: s.ink, height: 1.5)),
              ),
            ]),
          ],
          const SizedBox(height: 16),
          _UsageRow(usage: dash.usage),
          const SizedBox(height: 16),
          MonoLabel(l10n.opsSectionProjects, size: 11.5, letterSpacing: 1.6),
          const SizedBox(height: 8),
          if (!dash.reported)
            Text(l10n.opsNoDashboardReport,
                style: UepText.mono(size: 10.5, color: s.inkMute))
          else if (dash.repos.isEmpty)
            Text(l10n.opsNoRepos,
                style: UepText.mono(size: 10.5, color: s.inkMute))
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
    final l10n = AppLocalizations.of(context);
    final (label, color) = switch (runner.status) {
      'online' => (l10n.opsRunnerOnline, UepColors.gold),
      'paused' => (l10n.opsRunnerPaused, s.inkSoft),
      'limited' => (l10n.opsRunnerLimited, UepColors.error),
      // 重啟中既不是在線也不是掉線：用 info 這一色，免得與「它掛了」同貌
      'restarting' => (l10n.opsRunnerRestarting, UepColors.info),
      _ => (l10n.opsRunnerOffline, s.inkMute),
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
        Text(
            left == null
                ? l10n.opsBackoffUnknown
                : l10n.opsRetryIn(_short(left)),
            style: UepText.mono(size: 10.5, color: s.inkSoft)),
      ],
      if (runner.isOffline) ...[
        const SizedBox(width: 8),
        Text(l10n.opsOfflineSince(relativeTime(runner.lastSeenAt)),
            style: UepText.mono(size: 10.5, color: s.inkMute)),
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
    final l10n = AppLocalizations.of(context);
    if (!usage.reported) {
      return Text(l10n.opsUsageNotReported,
          style: UepText.mono(size: 10.5, color: s.inkMute));
    }
    final hours = usage.windowHours == 0
        ? ''
        : l10n.opsUsageWindow(_num(usage.windowHours));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MonoLabel(l10n.opsSectionUsage, size: 11.5, letterSpacing: 1.6),
        const SizedBox(height: 6),
        Text(
          '$hours ${usage.tokens} tokens · '
          '\$${usage.costUsd.toStringAsFixed(2)}',
          style: UepText.sans(size: 13.5, color: s.ink),
        ),
        const SizedBox(height: 3),
        Text(
          // 沒回報軟上限就說沒回報。0 在執行器那端是「不設上限」，
          // 兩者都不能畫成「剩 0」——那會讓人以為額度用完了
          usage.softCapTokens == null
              ? l10n.opsSoftCapNotReported
              : usage.softCapTokens == 0
                  ? l10n.opsSoftCapUnset
                  : usage.remainingTokens == null
                      ? l10n.opsSoftCapTokens('${usage.softCapTokens}')
                      : l10n.opsSoftCapTokensRemaining(
                          '${usage.softCapTokens}',
                          '${usage.remainingTokens}'),
          style: UepText.mono(
              size: 10.5,
              color: usage.overSoftCap ? UepColors.error : s.inkMute),
        ),
        if (usage.overSoftCap)
          Text(l10n.opsOverSoftCap,
              style: UepText.mono(size: 10.5, color: UepColors.error)),
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
    final l10n = AppLocalizations.of(context);
    // 推送鈕要不要能按，三個條件缺一不可：有東西可推、分支在可推清單裡、
    // 而且**執行器真的回報過那一格**（null ≠ false，見 RepoView.pushable）
    final hasCommits = repo.unpushedCount > 0;
    final pushable = repo.pushable;
    final canPush = onPush != null && hasCommits && pushable == true;
    final String? blocked = !hasCommits
        ? null
        : pushable == null
            ? l10n.opsPushBlockedUnknown
            : pushable == false
                ? l10n.opsPushBlockedNotAllowed(repo.branch)
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
                      size: 13.5, weight: FontWeight.w600, color: s.ink)),
            ),
            if (canPush)
              _SmallButton(
                  label: l10n.opsPushCommits(repo.unpushedCount),
                  enabled: true,
                  onTap: onPush!),
          ]),
          const SizedBox(height: 3),
          if (repo.hasError)
            Text(repo.error,
                style: UepText.mono(size: 10.5, color: UepColors.error))
          else ...[
            Row(children: [
              Text(repo.branch.isEmpty ? l10n.opsNoBranch : repo.branch,
                  style: UepText.mono(size: 10.5, color: s.inkSoft)),
              const SizedBox(width: 10),
              Text(
                hasCommits
                    ? l10n.opsUnpushedCount(repo.unpushedCount)
                    : l10n.opsNoUnpushed,
                style: UepText.mono(
                    size: 10.5,
                    color: hasCommits ? UepColors.gold : s.inkMute),
              ),
              if (repo.dirty) ...[
                const SizedBox(width: 10),
                Text(l10n.opsDirtyWorktree,
                    style: UepText.mono(size: 10.5, color: UepColors.error)),
              ],
            ]),
            for (final c in repo.unpushed)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 2),
                child: Row(children: [
                  Text(c.shortSha,
                      style: UepText.mono(size: 10.5, color: UepColors.gold)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(c.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: UepText.serif(size: 12.5, color: s.inkSoft)),
                  ),
                  const SizedBox(width: 8),
                  Text(relativeTime(c.at),
                      style: UepText.mono(size: 10, color: s.inkMute)),
                ]),
              ),
            if (blocked != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(blocked,
                    style: UepText.mono(size: 10.5, color: s.inkMute)),
              ),
          ],
        ],
      ),
    );
  }
}

class _QueueSection extends StatelessWidget {
  const _QueueSection({
    required this.board,
    this.onCancel,
    this.onSoftStop,
    this.now,
  });

  final RoomRunnerBoard board;
  final void Function(AgentRun run)? onCancel;
  final void Function(AgentRun run)? onSoftStop;
  final DateTime? now;

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
    // run 上只有 runner_id，而畫面上要講的是那台機器的名字
    final runnerNames = <String, String>{
      for (final r in board.runners) r.id: r.displayName,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MonoLabel(AppLocalizations.of(context).opsSectionQueue,
            size: 11.5, letterSpacing: 1.6),
        const SizedBox(height: 8),
        if (running.isEmpty && queued.isEmpty)
          Text(AppLocalizations.of(context).opsQueueEmpty,
              style: UepText.mono(size: 10.5, color: s.inkMute)),
        for (final run in running)
          _RunTile(
              run: run,
              view: views[run.id],
              runnerName: runnerNames[run.runnerId] ?? '',
              onCancel: onCancel,
              onSoftStop: onSoftStop,
              now: now),
        for (var i = 0; i < queued.length; i++)
          _RunTile(
              run: queued[i],
              position: i + 1,
              runnerName: runnerNames[queued[i].runnerId] ?? '',
              onCancel: onCancel,
              now: now),
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
    this.onSoftStop,
    this.runnerName = '',
    this.now,
  });

  final AgentRun run;
  final RunnerRunView? view;

  /// 排隊中的第幾位。**畫面算的，不是 Hub 的 `position`**——後者是
  /// 建單流水號，中間取消掉幾筆之後它就不是「你排第幾」了。
  final int? position;
  final void Function(AgentRun run)? onCancel;

  /// 請它收尾。**只有執行中的 run 有**：排隊中的還沒開始，該按的是取消。
  final void Function(AgentRun run)? onSoftStop;

  final String runnerName;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final turns = view?.turns ?? run.turns;
    final meta = <String>[
      if (position != null) l10n.opsQueuePosition(position!),
      if (runnerName.isNotEmpty) runnerName,
      if (run.isQueued)
        l10n.opsWaited(_waited(run.createdAt, now))
      else if (run.startedAt != null)
        l10n.opsStartedAt(relativeTime(run.startedAt, now: now)),
      if (run.priority > 0) l10n.opsPriorityValue(run.priority),
      // 執行中才講 turns／成本：排隊中的那兩格一定是 0，而那個 0 不是量測值
      if (!run.isQueued && turns > 0) '$turns turns',
      if (!run.isQueued && run.usage.isNotEmpty)
        '\$${run.costUsd.toStringAsFixed(2)}',
      if (view != null && view!.contextTokens > 0)
        l10n.opsContextTokens(view!.contextTokens),
    ];
    final actions = <Widget>[
      if (onSoftStop != null &&
          !run.isQueued &&
          !run.cancelRequested &&
          run.softStopRequestedAt == null)
        _SmallButton(
            label: l10n.opsActionSoftStop,
            enabled: true,
            onTap: () => onSoftStop!(run)),
      if (onCancel != null && !run.cancelRequested)
        _SmallButton(
            label: l10n.commonCancel,
            enabled: true,
            onTap: () => onCancel!(run)),
    ];
    return _RunCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _RunCardHeader(
            run: run,
            timeIso: run.startedAt ?? run.createdAt,
            now: now,
          ),
          const SizedBox(height: 6),
          Text(meta.join(' · '),
              style: UepText.mono(size: 10, color: s.inkMute)),
          // 🔴 running 的取消**不改狀態**（§4.2）：進程還在跑，這裡說
          // 「已取消」的話，畫面會與機器上正在寫檔的那個 agent 對不上
          if (run.cancelRequested && !run.isQueued)
            Text(l10n.opsCancelRequested,
                style: UepText.mono(size: 10, color: UepColors.error)),
          if (run.softStopRequestedAt != null && !run.cancelRequested)
            Text(l10n.opsSoftStopRequested,
                style: UepText.mono(size: 10, color: s.inkSoft)),
          _RequesterLine(run: run),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: WrapAlignment.end,
              children: actions,
            ),
          ],
        ],
      ),
    );
  }
}

class _FinishedSection extends StatelessWidget {
  const _FinishedSection({required this.runs, this.now});

  final List<AgentRun> runs;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MonoLabel(AppLocalizations.of(context).opsSectionFinished,
            size: 11.5, letterSpacing: 1.6),
        const SizedBox(height: 8),
        for (final run in runs) _FinishedCard(run: run, now: now),
      ],
    );
  }
}

/// 一筆結束的 run 在儀表板上的那張卡。
///
/// **摘要只留節錄**：`result` 是整段 Markdown（收工摘要動輒幾十行），原樣
/// 印在清單裡會把這一區變成 log。全文在既有的回報面板裡，點卡片打開。
class _FinishedCard extends StatelessWidget {
  const _FinishedCard({required this.run, this.now});

  final AgentRun run;
  final DateTime? now;

  void _open(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.uep.bgSoft,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: .85,
        child: RunReportDetailPanel(
          run: run,
          onClose: () => Navigator.of(sheetContext).pop(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final excerpt = opsResultExcerpt(run.result);
    return _RunCard(
      onTap: () => _open(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _RunCardHeader(
            run: run,
            timeIso: run.endedAt ?? run.updatedAt,
            now: now,
          ),
          _RequesterLine(run: run),
          if (excerpt.isNotEmpty) ...[
            const SizedBox(height: 6),
            UepMarkdownBody(data: excerpt, baseColor: s.inkMute),
          ] else if (run.reason.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(run.reason,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    UepText.serif(size: 12.5, color: s.inkMute, height: 1.5)),
          ],
        ],
      ),
    );
  }
}

/// 這一筆是誰動的手。
///
/// **只在 Supervisor 代派時出現**：人類自己按的那筆，動手的人就是畫面前
/// 的那個人，多一行等於每張卡都貼一句廢話。
///
/// 兩個名字分開講：`requester_name` 是**按下去的那一位**，
/// `requested_by_name` 是**配額算誰的**（Supervisor 代派時是指定它的那個
/// 人類）。壓成一句「某人派的」的話，那個人會在自己沒按過任何按鈕的情況下
/// 被寫成派工者。
class _RequesterLine extends StatelessWidget {
  const _RequesterLine({required this.run});

  final AgentRun run;

  @override
  Widget build(BuildContext context) {
    if (!run.isAgentRequested) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final parts = <String>[
      l10n.opsRequesterSupervisor(
          run.requesterName.isEmpty ? l10n.commonUnknown : run.requesterName),
      if (run.requestedByName.isNotEmpty)
        l10n.opsRequesterQuota(run.requestedByName),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(parts.join(' · '),
          style: UepText.mono(size: 10, color: UepColors.info)),
    );
  }
}

/// 佇列與最近結束共用的卡片外框。與回報面板的卡片同一個做法。
class _RunCard extends StatelessWidget {
  const _RunCard({required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    const radius = BorderRadius.all(Radius.circular(10));
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: s.bgSoft,
        border: Border.all(color: s.line),
        borderRadius: radius,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Padding(padding: const EdgeInsets.all(12), child: child),
        ),
      ),
    );
  }
}

/// 卡片第一行：狀態 chip ＋ kind ＋ ref 短碼 ＋ 相對時間。
class _RunCardHeader extends StatelessWidget {
  const _RunCardHeader({required this.run, required this.timeIso, this.now});

  final AgentRun run;
  final String? timeIso;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final (label, color) = opsRunStatusLabel(context, run);
    final short = run.ref.length <= 8 ? run.ref : run.ref.substring(0, 8);
    return Row(children: [
      _RunStatusChip(label: label, color: color),
      const SizedBox(width: 8),
      Flexible(
        child: Text(runKindLabel(run.kind),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: UepText.mono(size: 10.5, color: s.inkSoft)),
      ),
      if (short.isNotEmpty) ...[
        const SizedBox(width: 8),
        // 短碼夠認人，全碼留在 tooltip——它長到會把這一行擠掉
        Tooltip(
          message: run.ref,
          child: Text(short,
              style: UepText.mono(size: 10.5, color: UepColors.gold)),
        ),
      ],
      const Spacer(),
      const SizedBox(width: 8),
      Text(relativeTime(timeIso, now: now),
          style: UepText.mono(size: 10, color: s.inkMute)),
    ]);
  }
}

class _RunStatusChip extends StatelessWidget {
  const _RunStatusChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          border: Border.all(color: color.withValues(alpha: .5)),
          borderRadius: BorderRadius.circular(3),
        ),
        child:
            Text(label, style: UepText.mono(size: 10, color: color, letterSpacing: 1.2)),
      );
}

/// 狀態 → (標籤, 顏色)。結束的那幾種沿用回報面板那一份，另外補上佇列才有的
/// 兩種——同一個狀態在兩個畫面上長不一樣的話，人會以為那是兩件事。
(String, Color) opsRunStatusLabel(BuildContext context, AgentRun run) =>
    switch (run.status) {
      'running' || 'claimed' => (
          AppLocalizations.of(context).opsRunStatusRunning,
          UepColors.gold
        ),
      'queued' => (
          AppLocalizations.of(context).opsRunStatusQueued,
          context.uep.inkMute
        ),
      _ => runStatusLabel(context, run),
    };

/// kind → 中文。沿用派工模板那一份對照；`push` 不在模板裡（它是儀表板按出來
/// 的，見 [kRunTemplates]），所以單獨補。認不得的原樣顯示。
String runKindLabel(String kind) {
  for (final t in kRunTemplates) {
    if (t.kind == kind) return t.label;
  }
  return kind == 'push' ? L10n.current.opsPush : kind;
}

/// 最近結束卡片上的摘要節錄：去掉標題行，最多 [maxLines] 行、[maxChars] 字。
///
/// **標題行整行丟掉**（`## 收工摘要` 這類）：它在卡片上佔的是第一行內容的
/// 位置，而它講的是「接下來是摘要」——那件事卡片本身已經說了。
String opsResultExcerpt(String result,
    {int maxLines = 3, int maxChars = 160}) {
  final picked = <String>[];
  for (final raw in result.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (RegExp(r'^#{1,6}\s').hasMatch(line)) continue;
    picked.add(line);
    if (picked.length >= maxLines) break;
  }
  final text = picked.join('\n');
  if (text.length <= maxChars) return text;
  return '${text.substring(0, maxChars).trimRight()}…';
}

String _waited(String? since, DateTime? now) {
  final t = parseIso(since);
  if (t == null) return '—';
  return humanDuration((now ?? DateTime.now()).difference(t));
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
                size: 10.5,
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
          Text(title, style: UepText.sans(size: 15, color: s.inkTitle)),
          const SizedBox(height: 8),
          Text(subtitle,
              textAlign: TextAlign.center,
              style:
                  UepText.serif(size: 13.5, color: s.inkMute, height: 1.6)),
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
  final l10n = L10n.current;
  if (!c.isAcked) {
    return l10n.opsCommandSent(label, relativeTime(c.createdAt, now: now));
  }
  if (!c.isApplied) {
    // note 是執行器講的等待原因（「等 N 筆 run 結束後重啟」）。它沒講就不要
    // 替它編一個
    return c.note.isEmpty
        ? l10n.opsCommandAcked(label)
        : l10n.opsCommandAckedNote(label, c.note);
  }
  if (c.command == 'restart') {
    final applied = c.appliedTime;
    final started = DateTime.tryParse(runner.dashboard.startedAt);
    // started_at 比 applied_at 新＝它已經重開完回來了
    if (applied != null && started != null && started.isAfter(applied)) {
      return l10n.opsRestartDone(
          relativeTime(runner.dashboard.startedAt, now: now));
    }
    if (runner.isRestarting || runner.isOffline) {
      return l10n.opsRestarting;
    }
  }
  final at = relativeTime(c.appliedAt, now: now);
  return c.note.isEmpty
      ? l10n.opsCommandApplied(label, at)
      : l10n.opsCommandAppliedNote(label, at, c.note);
}

/// 命令的中文名。**與 `ops_actions` 的提示是同一份**——同一道命令在按鈕、
/// 提示與進度上叫三個名字的話，人會以為那是三件事。
String runnerCommandLabel(String command) => switch (command) {
      'pause' => L10n.current.opsCommandPause,
      'resume' => L10n.current.opsCommandResume,
      'restart' => L10n.current.opsCommandRestart,
      'drain' => L10n.current.opsCommandDrain,
      'reload' => L10n.current.opsCommandReload,
      _ => command,
    };

/// 執行器回報的重啟原因。認不得的原樣顯示——編一個對照不到的中文，等於把
/// 「它講了一個我不認識的原因」蓋掉。
String _restartReason(String reason) => switch (reason) {
      'restart_command' => L10n.current.opsRestartReasonCommand,
      'maintenance' => L10n.current.opsRestartReasonMaintenance,
      _ => reason,
    };

String _limitReason(String reason) => switch (reason) {
      'rate_limit' => L10n.current.opsLimitReasonRate,
      'weekly_limit' => L10n.current.opsLimitReasonWeekly,
      'manual' => L10n.current.opsLimitReasonManual,
      _ => reason,
    };

String _short(Duration d) {
  final l10n = L10n.current;
  if (d.inMinutes < 1) return l10n.timeDurationSeconds(d.inSeconds);
  if (d.inHours < 1) return l10n.timeDurationMinutes(d.inMinutes);
  return l10n.timeDurationHoursLong(d.inHours, d.inMinutes % 60);
}

String _num(double v) =>
    v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);
