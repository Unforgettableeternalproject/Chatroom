import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/l10n.dart';
import '../../models/ops_exception.dart';
import '../../state/ops_exceptions_providers.dart';
import '../../widgets/empty_error_states.dart';
import '../../widgets/kind_badge.dart';
import '../../widgets/markdown_body.dart';
import '../../widgets/reveal.dart';
import '../../widgets/uep_button.dart';

/// 寬版／窄版的界線。與回報面板同一個值：兩塊面板疊法一樣，界線不一樣的話
/// 同一個視窗寬度會出現兩種行為。
const double _kWidePanelWidth = 1200;

/// 監控器：跨房的派工例外。
///
/// **獨立於執行儀表板**：儀表板是單房視角（`room_id` 必填），而這裡要看的
/// 正是「我的哪一間房出事了」。把跨房資料塞進單房頁面，會讓上面每一個數字
/// 都要重新確認自己講的是哪一間房。
///
/// **不是整頁，是右側面板**：原本點入口會整個畫面換掉，於是「看一下哪裡
/// 出事」要付出離開當下畫面的代價。疊法與回報面板（`RunReportOverlay`）
/// 同一套——寬版疊在右側，窄版走 bottom sheet。
class OpsExceptionsPanel extends ConsumerStatefulWidget {
  const OpsExceptionsPanel({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  ConsumerState<OpsExceptionsPanel> createState() => _OpsExceptionsPanelState();
}

class _OpsExceptionsPanelState extends ConsumerState<OpsExceptionsPanel> {
  Timer? _poll;

  /// 現在展開的是哪一筆（`null` ＝都收著）。一次只開一筆：面板只有 560 寬，
  /// 兩筆同時展開就要靠捲動才找得回自己剛剛點的那一筆。
  String? _openId;

  @override
  void initState() {
    super.initState();
    // 輪詢在畫面層（同執行儀表板）：面板關了定時器跟著走
    _poll = Timer.periodic(const Duration(seconds: 15),
        (_) => ref.invalidate(opsExceptionsProvider));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final async = ref.watch(opsExceptionsProvider);
    final list = async.value ?? const <OpsException>[];
    // 看過了：水位記在本機，未讀計數（頂欄的入口）靠它算
    if (list.isNotEmpty) {
      final newest = list.first.createdAt;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(ref.read(opsExceptionSeenProvider.notifier).markSeen(newest));
      });
    }

    return Column(children: [
      Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        decoration:
            BoxDecoration(border: Border(bottom: BorderSide(color: s.line))),
        child: Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.opsExceptionsTitle,
                    style: UepText.pageTitle(color: s.inkTitle)),
                // 範圍要講清楚：看起來像全量的清單，會讓人根據一份
                // 不完整的資料判斷「今天沒出事」
                Text(l10n.opsExceptionsScope,
                    style: UepText.mono(size: 10.5, color: s.inkMute)),
              ],
            ),
          ),
          MonoLabel(l10n.opsRefreshEvery15s, size: 9, letterSpacing: 1.2),
          const SizedBox(width: 6),
          IconButton(
            tooltip: l10n.commonRefresh,
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.refresh, size: 16, color: s.inkMute),
            onPressed: () => ref.invalidate(opsExceptionsProvider),
          ),
          IconButton(
            tooltip: l10n.commonClose,
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close, size: 16, color: s.inkMute),
            onPressed: widget.onClose,
          ),
        ]),
      ),
      Expanded(
        child: async.when(
          loading: () => list.isEmpty
              ? const Center(
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: UepColors.gold)))
              : _list(list),
          error: (e, _) =>
              ErrorState(error: e, onRetry: () => ref.invalidate(opsExceptionsProvider)),
          data: _list,
        ),
      ),
    ]);
  }

  Widget _list(List<OpsException> list) {
    if (list.isEmpty) {
      final l10n = AppLocalizations.of(context);
      return EmptyState(
        title: l10n.opsExceptionsEmptyTitle,
        subtitle: l10n.opsExceptionsEmptySubtitle,
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      itemCount: list.length,
      itemBuilder: (context, i) {
        final item = list[i];
        return _ExceptionTile(
          item: item,
          expanded: item.id == _openId,
          // 再點同一筆＝收起來
          onTap: () => setState(
              () => _openId = item.id == _openId ? null : item.id),
        );
      },
    );
  }
}

/// 清單上的一筆。**點它是展開詳情，不是導覽**：原本整列點下去會跳到那間
/// 房，於是「這筆為什麼失敗」在面板上永遠看不到——要去訊息流裡翻。跳房的
/// 動作收進詳情裡的次要按鈕。
class _ExceptionTile extends StatelessWidget {
  const _ExceptionTile({
    required this.item,
    required this.expanded,
    required this.onTap,
  });

  final OpsException item;
  final bool expanded;
  final VoidCallback onTap;

  Color _dot() {
    switch (item.severity) {
      case 'error':
        return UepColors.error;
      case 'info':
        return UepColors.info;
      default:
        return UepColors.gold;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              margin: const EdgeInsets.only(top: 5),
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: _dot(), shape: BoxShape.circle),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.title,
                      style: UepText.serif(size: 14, color: s.inkTitle)),
                  const SizedBox(height: 3),
                  Text(
                    '${item.roomName.isEmpty ? item.roomId : item.roomName}'
                    ' · ${item.reason}',
                    style: UepText.mono(size: 10.5, color: s.inkMute),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(item.createdAt,
                style: UepText.mono(size: 10, color: s.inkMute)),
            Icon(expanded ? Icons.expand_less : Icons.expand_more,
                size: 16, color: expanded ? UepColors.gold : s.inkMute),
          ]),
        ),
      ),
      UepExpand(
        expanded: expanded,
        alignment: Alignment.topLeft,
        child: _ExceptionDetail(item: item),
      ),
    ]);
  }
}

/// 一筆異常的完整內容：事件自己帶的欄位 ＋ 對應 run 的最後回報。
///
/// **run 那一段另外撈**：`/api/ops/exceptions` 回的是事件摘要，寫著結果的
/// `result`／`reason` 在 run 上（`GET /api/runs/{run_id}`）。沒有 run 的
/// 事件（執行器上下線）就沒有這一段，不畫一塊永遠空的區域。
class _ExceptionDetail extends ConsumerWidget {
  const _ExceptionDetail({required this.item});

  final OpsException item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final room = item.roomName.isEmpty ? item.roomId : item.roomName;
    final target = item.runRef.isEmpty
        ? l10n.opsExceptionTargetUnspecified
        : (item.runKind.isEmpty
            ? item.runRef
            : '${item.runKind} · ${item.runRef}');

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 2, 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: s.bgCard,
        border: Border.all(color: s.line),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _row(context, l10n.opsExceptionFieldTime, item.createdAt),
        _row(context, l10n.opsExceptionFieldRoom, room),
        _row(context, l10n.opsExceptionFieldKind, item.kind),
        _row(context, l10n.opsExceptionFieldReason, item.reason),
        _row(context, l10n.opsExceptionFieldSeverity, item.severity),
        _row(context, l10n.opsExceptionFieldTarget, target),
        if (item.runId.isNotEmpty)
          _row(context, l10n.opsExceptionFieldRunId, item.runId),
        if (item.runnerId.isNotEmpty)
          _row(context, l10n.opsExceptionFieldRunner,
              '${item.runnerLabel} · ${item.runnerId}'),
        // detail 的鍵是事件自己帶的（`stalled_seconds`、`label`…），會長出
        // 新的——逐鍵列而不是挑幾個認得的畫，不然新欄位在畫面上等於不存在
        for (final e in item.detail.entries)
          _row(context, e.key, '${e.value}'),
        if (item.runId.isNotEmpty) ...[
          const SizedBox(height: 10),
          MonoLabel(l10n.opsExceptionReportLabel, size: 8.5, letterSpacing: 2.2),
          const SizedBox(height: 6),
          _report(context, ref),
        ],
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: UepButton(
            label: l10n.opsExceptionGotoRoom,
            variant: UepButtonVariant.outline,
            small: true,
            onPressed: () => context.go('/rooms/${item.roomId}'),
          ),
        ),
      ]),
    );
  }

  Widget _report(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final async = ref.watch(opsExceptionRunProvider((item.roomId, item.runId)));

    Widget note(String text, {bool error = false}) => Text(
          text,
          style: error
              ? UepText.mono(size: 10.5, color: UepColors.errorText)
              : UepText.serif(size: 12.5, color: s.inkMute, height: 1.5),
        );

    return async.when(
      // 讀不到與「沒有回報」講成兩句話：前者是這一段壞了，後者是真的沒留下
      loading: () => note(l10n.commonLoading),
      error: (e, _) => note(l10n.opsExceptionReportFailed('$e'), error: true),
      data: (run) {
        if (run == null) return note(l10n.opsRunNoReport);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            '${run.status}'
            '${run.endedAt == null ? '' : ' · ${run.endedAt}'}',
            style: UepText.mono(size: 10.5, color: s.inkSoft),
          ),
          const SizedBox(height: 6),
          if (run.result.isNotEmpty)
            UepMarkdownBody(data: run.result, baseColor: s.inkSoft)
          else
            note(run.reason.isEmpty ? l10n.opsRunNoReport : run.reason),
        ]);
      },
    );
  }

  Widget _row(BuildContext context, String label, String value) {
    final s = context.uep;
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 88,
          child: Text(label,
              style: UepText.mono(size: 10, color: s.inkMute)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: SelectableText(value,
              style: UepText.mono(size: 10.5, color: s.inkSoft)),
        ),
      ]),
    );
  }
}

/// 疊在畫面右側的異常面板（寬版）。
///
/// 掛法與回報面板（`RunReportOverlay`）同一套：`Positioned.fill` 疊在內容
/// 之上，左邊那塊透明區域就是「點外面關閉」的接收面，寬度同樣是
/// 480～560、且不超過主區的 60%。
class OpsExceptionsOverlay extends ConsumerWidget {
  const OpsExceptionsOverlay({super.key, this.sidebarWidth = 0});

  /// 右邊已經有側欄時（聊天室）面板貼著它的左緣；儀表板沒有，就是 0。
  final double sidebarWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(opsExceptionsPanelOpenProvider);
    void close() => ref.read(opsExceptionsPanelOpenProvider.notifier).close();

    return UepReveal(
      slide: const Offset(.04, 0),
      child: !open ? null : _buildPanel(context, close),
    );
  }

  Widget _buildPanel(BuildContext context, VoidCallback close) {
    final s = context.uep;
    return LayoutBuilder(
      builder: (context, c) {
        final mainWidth = math.max(0.0, c.maxWidth - sidebarWidth);
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
                  child: OpsExceptionsPanel(onClose: close),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 頂欄的入口：一顆 icon + 未讀計數。
///
/// 計數是**比本機水位新的筆數**，不是總數：總數永遠不會歸零，然後就跟
/// 沒有一樣。
class OpsExceptionsEntry extends ConsumerWidget {
  const OpsExceptionsEntry({super.key});

  /// 寬版把「開著沒有」寫進 provider，由 [OpsExceptionsOverlay] 疊出來；
  /// 窄版沒有那塊空間，改開全寬的 bottom sheet（同回報面板的作法）。
  void _open(BuildContext context, WidgetRef ref) {
    if (MediaQuery.sizeOf(context).width >= _kWidePanelWidth) {
      ref.read(opsExceptionsPanelOpenProvider.notifier).toggle();
      return;
    }
    ref.read(opsExceptionsPanelOpenProvider.notifier).close();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.uep.bgSoft,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: .85,
        child: OpsExceptionsPanel(
          onClose: () => Navigator.of(sheetContext).pop(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final list = ref.watch(opsExceptionsProvider).value ?? const [];
    final unread =
        unreadExceptionCount(list, ref.watch(opsExceptionSeenProvider));
    return Stack(clipBehavior: Clip.none, children: [
      IconButton(
        tooltip: AppLocalizations.of(context).opsExceptionsTitle,
        icon: Icon(Icons.warning_amber_rounded, size: 17, color: s.inkMute),
        onPressed: () => _open(context, ref),
      ),
      if (unread > 0)
        Positioned(
          right: 4,
          top: 2,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: UepColors.error,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(unread > 99 ? '99+' : '$unread',
                style: UepText.mono(size: 9, color: Colors.white)),
          ),
        ),
    ]);
  }
}
