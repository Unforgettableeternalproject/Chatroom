import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../core/util/relative_time.dart';
import '../models/agent_run.dart';
import '../state/runs_providers.dart';
import 'kind_badge.dart';
import 'markdown_body.dart';

/// 工作房側欄的「回報」區（REMOTE-OPS-PLAN §12 待辦 2）。
///
/// **讀 `agent_run.result`，不從訊息流撿**：收工摘要同時是一則 system 訊息，
/// 但訊息會被後續發言推走，而「上一筆 run 做完了什麼」是要回頭查的東西。
/// Hub 已經把 result 存在 run 上，這裡就讀那一份。
///
/// 輪詢與儀表板同頻（10 秒）：run 的狀態變化刻意不進 `/updates`，沒有
/// notify 可以用。定時器掛在這個 widget 上——側欄不在畫面上就不打。
class RunReportPanel extends ConsumerStatefulWidget {
  const RunReportPanel({super.key, required this.roomId});

  final String roomId;

  @override
  ConsumerState<RunReportPanel> createState() => _RunReportPanelState();
}

class _RunReportPanelState extends ConsumerState<RunReportPanel>
    with WidgetsBindingObserver {
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  void _start() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 進背景就停，與執行儀表板同一個作法
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
    if (!mounted) return;
    ref.invalidate(finishedRunsProvider(widget.roomId));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final async = ref.watch(finishedRunsProvider(widget.roomId));
    final runs = async.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const MonoLabel('回報', size: 8.5, letterSpacing: 2.2),
        const SizedBox(height: 8),
        // 讀不到與「沒有」講成兩句話：前者是這一區壞了，後者是真的沒有派過
        if (runs == null && async.hasError)
          Text('讀不到派工回報：${async.error}',
              style: UepText.mono(size: 9.5, color: UepColors.errorText))
        else if (runs == null)
          Text('讀取中…', style: UepText.mono(size: 9.5, color: s.inkMute))
        else if (runs.isEmpty)
          Text('還沒有結束的派工。run 收工後的摘要會出現在這裡。',
              style: UepText.serif(size: 11.5, color: s.inkMute, height: 1.5))
        else
          for (final run in runs)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: RunReportCard(run: run),
            ),
      ],
    );
  }
}

/// 一筆結束的 run。預設收合，點標頭展開 `result`。
///
/// 收合是預設，因為摘要是整段 Markdown——五筆全展開的側欄沒有人捲得完。
class RunReportCard extends StatefulWidget {
  const RunReportCard({super.key, required this.run});

  final AgentRun run;

  @override
  State<RunReportCard> createState() => _RunReportCardState();
}

class _RunReportCardState extends State<RunReportCard> {
  bool _expanded = false;

  /// 狀態 → (標籤, 顏色)。
  (String, Color) _status(BuildContext context) => switch (widget.run.status) {
        'done' => ('完成', UepColors.success),
        'failed' => ('失敗', UepColors.error),
        'cancelled' => ('已取消', context.uep.inkMute),
        'handoff' => ('交接', UepColors.info),
        _ => (widget.run.status, context.uep.inkMute),
      };

  /// 用量那一行。
  ///
  /// **執行器沒回報 `usage_json` 時不寫 0**：一個沒有人講過的 0 會讓人以為
  /// 這筆沒花成本（同 `RunnerUsage.reported` 的理由）。
  String get _usageLine {
    final run = widget.run;
    if (run.usage.isEmpty) return '用量未回報';
    return '${run.turns} turns · \$${run.costUsd.toStringAsFixed(2)}';
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final run = widget.run;
    final (label, color) = _status(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: s.bgCard,
        border: Border.all(color: s.line),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        border: Border.all(color: color.withValues(alpha: .5)),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(label,
                          style: UepText.mono(
                              size: 8.5, color: color, letterSpacing: 1.2)),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        run.kind,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: UepText.mono(size: 9.5, color: s.inkSoft),
                      ),
                    ),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 14,
                      color: s.inkMute,
                    ),
                  ]),
                  if (run.ref.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      run.ref,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: UepText.sans(size: 12, color: s.ink),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    '${relativeTime(run.endedAt ?? run.updatedAt)} · $_usageLine',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: UepText.mono(size: 9, color: s.inkMute),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: s.line)),
              ),
              // 寬度交給父層：長路徑與 code block 由 Markdown 自己換行或
              // 在自己的框內水平捲動，不把側欄撐破
              child: run.result.isEmpty
                  ? Text(
                      run.reason.isEmpty
                          ? '這一筆沒有留下回報內容。'
                          : run.reason,
                      style: UepText.serif(
                          size: 11.5, color: s.inkMute, height: 1.5),
                    )
                  : UepMarkdownBody(data: run.result, baseColor: s.inkSoft),
            ),
        ],
      ),
    );
  }
}
