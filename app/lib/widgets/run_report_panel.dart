import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../core/util/relative_time.dart';
import '../models/agent_run.dart';
import '../state/runs_providers.dart';
import 'kind_badge.dart';
import 'markdown_body.dart';
import 'reveal.dart';
import 'uep_button.dart';

/// 工作房側欄的「回報」區（REMOTE-OPS-PLAN §12 待辦 2）。
///
/// **讀 `agent_run.result`，不從訊息流撿**：收工摘要同時是一則 system 訊息，
/// 但訊息會被後續發言推走，而「上一筆 run 做完了什麼」是要回頭查的東西。
/// Hub 已經把 result 存在 run 上，這裡就讀那一份。
///
/// **內容不在側欄裡展開**：摘要是整段 Markdown，在 288 寬的側欄裡向下展開
/// 會把側欄拉成沒有人捲得完的長條。點卡片改成在側欄左側開一塊
/// [RunReportOverlay]（窄版走 bottom sheet），側欄這邊只留固定高度的清單。
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
  /// 一頁幾筆。原本固定只給 5 筆——那是「最近」，不是「查得到」。
  static const int _pageSize = 20;

  Timer? _poll;
  int _limit = _pageSize;

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

  /// 點卡片。
  ///
  /// 寬版把「打開哪一筆」寫進 provider，由 [RunReportOverlay] 在訊息區上方
  /// 畫出來；窄版沒有那塊空間，改開全寬的 bottom sheet。
  void _open(BuildContext context, AgentRun run) {
    final notifier = ref.read(selectedRunIdProvider.notifier);
    if (MediaQuery.sizeOf(context).width >= 1200) {
      // 再點同一張＝收起來，跟原本的展開／收合一致
      notifier.toggle(widget.roomId, run.id);
      return;
    }
    notifier.clear(widget.roomId);
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
    final async = ref.watch(finishedRunsProvider(widget.roomId));
    final runs = async.value;
    final selectedId = ref.watch(selectedRunIdProvider)[widget.roomId];

    Widget note(String text, {bool error = false, bool mono = true}) => Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Text(
            text,
            style: mono
                ? UepText.mono(
                    size: 10.5, color: error ? UepColors.errorText : s.inkMute)
                : UepText.serif(size: 12.5, color: s.inkMute, height: 1.5),
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const MonoLabel('回報', size: 8.5, letterSpacing: 2.2),
        const SizedBox(height: 8),
        // 讀不到與「沒有」講成兩句話：前者是這一區壞了，後者是真的沒有派過
        if (runs == null && async.hasError)
          note('讀不到派工回報：${async.error}', error: true)
        else if (runs == null)
          note('讀取中…')
        else if (runs.isEmpty)
          note('還沒有結束的派工', mono: false)
        else
          // **限高可捲**：回報筆數是會長的，側欄的高度不是
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(right: 2, bottom: 4),
              children: [
                for (final run in runs.take(_limit))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: RunReportCard(
                      run: run,
                      selected: run.id == selectedId,
                      onTap: () => _open(context, run),
                    ),
                  ),
                if (runs.length > _limit)
                  UepButton(
                    label: '更多（還有 ${runs.length - _limit}）',
                    variant: UepButtonVariant.outline,
                    small: true,
                    expand: true,
                    onPressed: () => setState(() => _limit += _pageSize),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 展開在訊息區上方、靠右貼著側欄的回報面板（寬版）。
///
/// 掛法是 `Positioned.fill` 疊在聊天列上：它要蓋住訊息區，但**不蓋側欄**
/// ——點另一張卡要能直接換內容，而不是先被關掉一次。左邊那塊透明區域就是
/// 「點外面關閉」的接收面。
///
/// **開關有過場**：窄版走 bottom sheet，Flutter 自己會滑上來；寬版這塊是
/// 自己疊的，沒有人替它做動畫，一塊 560 寬的面板瞬間出現在訊息上像是畫面
/// 壞掉。這裡用共用的 [UepReveal]（淡入＋自右微幅滑入）補上。
///
/// 不撐高（`grow`）：它是 `Positioned.fill` 的疊層，高度本來就是整條。
class RunReportOverlay extends ConsumerWidget {
  const RunReportOverlay({
    super.key,
    required this.roomId,
    this.sidebarWidth = 288,
  });

  final String roomId;

  /// 成員側欄的寬度：面板貼著它的左緣。
  final double sidebarWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = ref.watch(selectedRunIdProvider)[roomId];
    final runs = id == null
        ? const <AgentRun>[]
        : ref.watch(finishedRunsProvider(roomId)).value ?? const [];
    AgentRun? run;
    for (final r in runs) {
      if (r.id == id) {
        run = r;
        break;
      }
    }
    void close() => ref.read(selectedRunIdProvider.notifier).clear(roomId);

    return UepReveal(
      slide: const Offset(.04, 0),
      // 那一筆已經不在清單裡（換房、被過濾掉）就當沒開，不畫一塊空面板
      child: run == null ? null : _buildPanel(context, run, close),
    );
  }

  Widget _buildPanel(BuildContext context, AgentRun run, VoidCallback close) {
    final s = context.uep;
    return LayoutBuilder(
      builder: (context, c) {
        final mainWidth = math.max(0.0, c.maxWidth - sidebarWidth);
        // 480～560，且不超過主區的 60%
        final width = math.min(560.0, mainWidth * .6);
        return Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: math.max(0.0, mainWidth - width),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: close,
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              right: sidebarWidth,
              top: 0,
              bottom: 0,
              width: width,
              child: Material(
                color: s.bgSoft,
                elevation: 8,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(color: s.line),
                      right: BorderSide(color: s.line),
                    ),
                  ),
                  child: RunReportDetailPanel(run: run, onClose: close),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 一筆 run 的完整回報：標題列（狀態、kind、ref、結束時間、用量）＋可捲內容。
class RunReportDetailPanel extends StatelessWidget {
  const RunReportDetailPanel({
    super.key,
    required this.run,
    required this.onClose,
  });

  final AgentRun run;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final (label, color) = runStatusLabel(context, run);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: s.line)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                _StatusChip(label: label, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    run.kind,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: UepText.mono(size: 10.5, color: s.inkSoft),
                  ),
                ),
                IconButton(
                  tooltip: '關閉',
                  visualDensity: VisualDensity.compact,
                  onPressed: onClose,
                  icon: Icon(Icons.close, size: 16, color: s.inkMute),
                ),
              ]),
              if (run.ref.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  run.ref,
                  style: UepText.sans(size: 15, color: s.ink),
                ),
              ],
              const SizedBox(height: 4),
              Text(
                '${relativeTime(run.endedAt ?? run.updatedAt)} · '
                '${runUsageLine(run)}',
                style: UepText.mono(size: 10.5, color: s.inkMute),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
            child: run.result.isEmpty
                ? Text(
                    run.reason.isEmpty ? '這一筆沒有留下回報內容。' : run.reason,
                    style:
                        UepText.serif(size: 13.5, color: s.inkMute, height: 1.6),
                  )
                : UepMarkdownBody(data: run.result, baseColor: s.inkSoft),
          ),
        ),
      ],
    );
  }
}

/// 狀態 → (標籤, 顏色)。
(String, Color) runStatusLabel(BuildContext context, AgentRun run) =>
    switch (run.status) {
      'done' => ('完成', UepColors.success),
      'failed' => ('失敗', UepColors.error),
      'cancelled' => ('已取消', context.uep.inkMute),
      'handoff' => ('交接', UepColors.info),
      _ => (run.status, context.uep.inkMute),
    };

/// 用量那一行。
///
/// **執行器沒回報 `usage_json` 時不寫 0**：一個沒有人講過的 0 會讓人以為
/// 這筆沒花成本（同 `RunnerUsage.reported` 的理由）。
String runUsageLine(AgentRun run) {
  if (run.usage.isEmpty) return '用量未回報';
  return '${run.turns} turns · \$${run.costUsd.toStringAsFixed(2)}';
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          border: Border.all(color: color.withValues(alpha: .5)),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(label,
            style:
                UepText.mono(size: 10, color: color, letterSpacing: 1.2)),
      );
}

/// 一筆結束的 run 在側欄裡的那張卡。點它打開左側面板／bottom sheet。
///
/// **卡片自己不展開內容**：整段 Markdown 塞進 288 寬的側欄，等於把側欄變成
/// 第二條訊息流。
class RunReportCard extends StatelessWidget {
  const RunReportCard({
    super.key,
    required this.run,
    this.selected = false,
    this.onTap,
  });

  final AgentRun run;

  /// 這張是現在打開的那一筆：外框換成金色，讓面板的內容對得上來源。
  final bool selected;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final (label, color) = runStatusLabel(context, run);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: s.bgCard,
        border: Border.all(color: selected ? UepColors.gold : s.line),
        borderRadius: BorderRadius.circular(6),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                _StatusChip(label: label, color: color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    run.kind,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: UepText.mono(size: 10.5, color: s.inkSoft),
                  ),
                ),
                Icon(
                  Icons.chevron_left,
                  size: 14,
                  color: selected ? UepColors.gold : s.inkMute,
                ),
              ]),
              if (run.ref.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  run.ref,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: UepText.sans(size: 13, color: s.ink),
                ),
              ],
              const SizedBox(height: 4),
              Text(
                '${relativeTime(run.endedAt ?? run.updatedAt)} · '
                '${runUsageLine(run)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: UepText.mono(size: 10, color: s.inkMute),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
