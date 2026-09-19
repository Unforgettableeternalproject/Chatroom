import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/l10n.dart';
import '../../models/agent_run.dart';
import '../../state/rooms_providers.dart';
import '../../state/runs_providers.dart';
import '../../widgets/empty_error_states.dart';
import '../../widgets/kind_badge.dart';
import 'exceptions_panel.dart';
import 'ops_actions.dart';
import 'ops_dashboard_view.dart';

/// 工作房的執行儀表板（REMOTE-OPS-PLAN §4.4、§5.6、§5.7）。
///
/// **輪詢在這裡，不在 provider 裡**：畫面走了定時器跟著走。掛在 provider
/// 上的話，離開這個畫面之後那條迴圈還會每 10 秒叫一次 Hub，而沒有人在看。
class OpsDashboardScreen extends ConsumerStatefulWidget {
  const OpsDashboardScreen({super.key, required this.roomId});

  final String roomId;

  @override
  ConsumerState<OpsDashboardScreen> createState() => _OpsDashboardScreenState();
}

class _OpsDashboardScreenState extends ConsumerState<OpsDashboardScreen>
    with WidgetsBindingObserver {
  Timer? _poll;
  String? _busyRunnerId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  void _start() {
    _poll?.cancel();
    // 10 秒，與指派列表同一個節奏。run 的狀態變化刻意不進 `/updates`，
    // 所以這一格只能輪詢
    _poll = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // App 進背景就停。看不到的畫面沒有理由每 10 秒叫一次 Hub
    if (state == AppLifecycleState.resumed) {
      _refresh();
      _start();
    } else {
      _poll?.cancel();
      _poll = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }

  void _refresh() {
    ref.invalidate(roomRunnerBoardProvider(widget.roomId));
    ref.invalidate(finishedRunsProvider(widget.roomId));
  }

  Future<void> _command(AgentRunner runner, String command) async {
    setState(() => _busyRunnerId = runner.id);
    await sendRunnerCommand(context, ref,
        runner: runner, command: command, roomId: widget.roomId);
    if (!mounted) return;
    setState(() => _busyRunnerId = null);
    _refresh();
  }

  Future<void> _push(AgentRunner runner, RepoView repo) async {
    final ok = await pushRepo(context, ref,
        roomId: widget.roomId,
        // repo 的鍵是 `<project>/<repo>`，而 run 要的 project 是前半段。
        // 拿不到（舊格式沒有斜線）時退回這台執行器宣告的第一個專案
        project: repo.projectKey.isNotEmpty
            ? repo.projectKey
            : (runner.projects.isEmpty ? '' : runner.projects.first),
        repo: repo);
    if (ok) _refresh();
  }

  Future<void> _cancel(AgentRun run) async {
    final ok = await cancelRun(context, ref, run: run);
    if (ok) _refresh();
  }

  Future<void> _softStop(AgentRun run) async {
    final ok = await softStopRun(context, ref, run: run);
    if (ok) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final room = ref.watch(roomDetailProvider(widget.roomId)).value?.room;
    final boardAsync = ref.watch(roomRunnerBoardProvider(widget.roomId));
    // 儀表板只列最近結束的那幾筆（截斷從 provider 移到這裡）
    final finished = (ref.watch(finishedRunsProvider(widget.roomId)).value ??
            const <AgentRun>[])
        .take(5)
        .toList();

    return Scaffold(
      backgroundColor: s.bg,
      body: Column(children: [
        Container(
          padding: const EdgeInsets.fromLTRB(24, 14, 18, 12),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: s.line)),
          ),
          child: Row(children: [
            IconButton(
              tooltip: l10n.opsBackToChat,
              icon: Icon(Icons.arrow_back, size: 18, color: s.inkSoft),
              onPressed: () => context.go('/rooms/${widget.roomId}'),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.opsDashboardTitle,
                      style: UepText.pageTitle(color: s.inkTitle)),
                  Text(room?.name ?? widget.roomId,
                      style: UepText.mono(size: 10.5, color: s.inkMute)),
                ],
              ),
            ),
            // 異常面板的入口：跨房的，所以不畫在這個單房面板裡，只留一顆
            // 帶未讀計數的 icon
            const OpsExceptionsEntry(),
            const SizedBox(width: 4),
            MonoLabel(l10n.opsRefreshEvery10s, size: 9, letterSpacing: 1.2),
            const SizedBox(width: 10),
            IconButton(
              tooltip: l10n.commonRefresh,
              icon: Icon(Icons.refresh, size: 16, color: s.inkMute),
              onPressed: _refresh,
            ),
          ]),
        ),
        Expanded(
          child: room != null && !room.isOps
              // 非 ops 房沒有佇列，Hub 對它的建單一律 409。畫一個永遠失敗
              // 的面板不如把話講清楚
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(l10n.opsNotOpsRoom,
                        style: UepText.serif(size: 14, color: s.inkMute)),
                  ),
                )
              : boardAsync.when(
                  loading: () => const Center(
                      child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: UepColors.gold))),
                  error: (e, _) => ErrorState(error: e, onRetry: _refresh),
                  data: (board) => OpsDashboardView(
                    board: board,
                    finished: finished,
                    busyRunnerId: _busyRunnerId,
                    onCommand: _command,
                    onPush: _push,
                    onCancel: _cancel,
                    onSoftStop: _softStop,
                  ),
                ),
        ),
      ]),
    );
  }
}
