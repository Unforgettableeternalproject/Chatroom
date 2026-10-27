import 'package:flutter/material.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../l10n/l10n.dart';
import '../models/reaction.dart';
import 'kind_badge.dart';

/// 泡泡下方的表情 chip 列：emoji＋數量，自己選的那個高亮（金色細框）。
///
/// **點 chip 不改狀態**，只是開名單（[onTapChip]）；加／換／取消表情走
/// 「加表情」入口的快選列。hover 顯示簡短名單。
class ReactionChipRow extends StatelessWidget {
  const ReactionChipRow({
    super.key,
    required this.reactions,
    required this.onTapChip,
    this.alignEnd = false,
  });

  final List<ReactionSummary> reactions;
  final void Function(ReactionSummary) onTapChip;

  /// 自己的訊息靠右，chip 跟著貼右。
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Wrap(
      spacing: 5,
      runSpacing: 5,
      alignment: alignEnd ? WrapAlignment.end : WrapAlignment.start,
      children: [
        for (final r in reactions)
          Tooltip(
            message: _tooltip(r),
            waitDuration: const Duration(milliseconds: 400),
            child: InkWell(
              key: Key('reaction-chip-${r.emoji}'),
              borderRadius: BorderRadius.circular(999),
              onTap: () => onTapChip(r),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: r.mine
                      ? UepColors.gold.withValues(alpha: .10)
                      : s.bgCard,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: r.mine ? UepColors.gold : s.line,
                    width: r.mine ? 1.2 : 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(r.emoji, style: const TextStyle(fontSize: 13)),
                    const SizedBox(width: 4),
                    Text('${r.count}',
                        style: UepText.mono(
                            size: 11,
                            color: r.mine ? UepColors.gold : s.inkMute)),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  static String _tooltip(ReactionSummary r) {
    final shown = r.names.join('、');
    final more = r.count - r.names.length;
    return more > 0 ? '$shown +$more' : shown;
  }
}

/// 叫出快選表情列。回傳選到的表情；點了目前自己選的那個也是回傳它
/// （呼叫端把「同一個」解讀成取消）。沒選就關掉回 null。
Future<String?> showReactionPicker(
  BuildContext context,
  Offset globalPos, {
  String? current,
}) {
  final s = context.uep;
  final overlay = Overlay.of(context, rootOverlay: true)
      .context
      .findRenderObject()! as RenderBox;
  return showMenu<String>(
    context: context,
    useRootNavigator: true,
    position: RelativeRect.fromRect(
      Rect.fromPoints(globalPos, globalPos),
      Offset.zero & overlay.size,
    ),
    color: s.bgCard,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: BorderSide(color: s.lineStrong),
    ),
    items: [
      PopupMenuItem<String>(
        enabled: false,
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Builder(
          builder: (ctx) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final e in kReactionEmojis)
                InkWell(
                  key: Key('reaction-picker-$e'),
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => Navigator.of(ctx, rootNavigator: true).pop(e),
                  child: Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: e == current
                            ? UepColors.gold
                            : Colors.transparent,
                        width: 1.2,
                      ),
                      color: e == current
                          ? UepColors.gold.withValues(alpha: .12)
                          : null,
                    ),
                    child: Text(e, style: const TextStyle(fontSize: 18)),
                  ),
                ),
            ],
          ),
        ),
      ),
    ],
  );
}

/// 名單面板的內容：依表情分頁（全部＋各表情），每列是人名＋其表情。
/// agent 沿用 [KindBadge]。我有按的話底下給「移除我的表情」。
class ReactorsPanel extends StatefulWidget {
  const ReactorsPanel({
    super.key,
    required this.load,
    required this.onRemoveMine,
    this.canRemove = true,
  });

  final Future<List<Reactor>> Function() load;

  /// 移除我的表情（呼叫端負責送出與關閉面板）。
  final Future<void> Function() onRemoveMine;

  /// 封存房唯讀時不給移除。
  final bool canRemove;

  @override
  State<ReactorsPanel> createState() => _ReactorsPanelState();
}

class _ReactorsPanelState extends State<ReactorsPanel> {
  late final Future<List<Reactor>> _future = widget.load();
  String? _filter; // null＝全部

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    return FutureBuilder<List<Reactor>>(
      future: _future,
      builder: (context, snap) {
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text(l10n.reactionLoadFailed,
                style: UepText.sans(size: 13, color: s.inkMute)),
          );
        }
        final all = snap.data;
        if (all == null) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        final emojis = <String>[];
        for (final r in all) {
          if (!emojis.contains(r.emoji)) emojis.add(r.emoji);
        }
        final shown =
            _filter == null ? all : all.where((r) => r.emoji == _filter);
        final hasMine = all.any((r) => r.mine);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _tab(context, null, '${l10n.reactionPanelAll} ${all.length}'),
                for (final e in emojis)
                  _tab(context, e,
                      '$e ${all.where((r) => r.emoji == e).length}'),
              ],
            ),
            const SizedBox(height: 10),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final r in shown)
                    Padding(
                      key: Key('reactor-${r.participantId}'),
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        children: [
                          Text(r.emoji, style: const TextStyle(fontSize: 16)),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(r.name,
                                overflow: TextOverflow.ellipsis,
                                style: UepText.sans(
                                    size: 14,
                                    weight: FontWeight.w600,
                                    color: s.inkTitle)),
                          ),
                          const SizedBox(width: 8),
                          KindBadge(kind: r.kind.isEmpty ? 'other' : r.kind),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (hasMine && widget.canRemove) ...[
              const SizedBox(height: 8),
              TextButton(
                key: const Key('reaction-remove-mine'),
                onPressed: widget.onRemoveMine,
                child: Text(l10n.reactionRemoveMine),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _tab(BuildContext context, String? value, String label) {
    final s = context.uep;
    final selected = _filter == value;
    return InkWell(
      key: Key('reactor-tab-${value ?? 'all'}'),
      borderRadius: BorderRadius.circular(999),
      onTap: () => setState(() => _filter = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: selected ? UepColors.gold : s.line),
          color: selected ? UepColors.gold.withValues(alpha: .10) : null,
        ),
        child: Text(label,
            style: UepText.sans(
                size: 12.5, color: selected ? UepColors.gold : s.inkMute)),
      ),
    );
  }
}

/// 開名單面板：桌面用對話框，窄螢幕用 bottom sheet。
Future<void> showReactorsPanel(
  BuildContext context, {
  required Future<List<Reactor>> Function() load,
  required Future<void> Function() onRemoveMine,
  bool canRemove = true,
}) {
  final l10n = AppLocalizations.of(context);
  final s = context.uep;
  Widget panel(BuildContext ctx) => ReactorsPanel(
        load: load,
        canRemove: canRemove,
        onRemoveMine: () async {
          await onRemoveMine();
          if (ctx.mounted) Navigator.of(ctx).pop();
        },
      );
  final narrow = MediaQuery.sizeOf(context).width < 600;
  if (narrow) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: s.bgCard,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.reactionPanelTitle,
                  style: UepText.pageTitle(color: s.inkTitle)),
              const SizedBox(height: 12),
              Flexible(child: panel(ctx)),
            ],
          ),
        ),
      ),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.reactionPanelTitle,
          style: UepText.pageTitle(color: s.inkTitle)),
      content: SizedBox(width: 360, child: panel(ctx)),
    ),
  );
}
