import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../core/util/relative_time.dart';
import '../../models/board.dart';
import '../../state/board_providers.dart';
import '../../state/messages_providers.dart';
import '../../widgets/kind_badge.dart';
import 'board_action_feedback.dart';

/// Task 詳情抽屜（設計稿 artboard 03，420px）。
///
/// 卡片上放不下的東西在這裡：完整描述、誰指定的、誰建立的，以及
/// **長出這張卡的那則訊息**。
///
/// 那則訊息是這個抽屜真正的理由：board 上的一張卡最後總會變成一句沒有上下文
/// 的話，而決定它的討論還在聊天室裡。`source_seq` 是回去的路，跳轉一次就能
/// 看到當初為什麼要做這件事。
class BoardTaskDrawer extends ConsumerWidget {
  const BoardTaskDrawer({
    super.key,
    required this.roomId,
    required this.task,
    required this.checklistTitle,
    required this.onClose,
    this.assigneeName,
    this.readOnly = false,
    this.width = 420,
  });

  final String roomId;
  final BoardTask task;

  /// 這張卡長在哪個階段底下。標頭列寫出來——抽屜蓋住了板，
  /// 不寫的話就看不到自己在三層樹的哪裡。
  final String checklistTitle;

  final String? assigneeName;

  /// 封存的房間：只讀不動。抽屜照樣開得起來——**看歷史是唯讀的用途，
  /// 不是被禁止的動作**，收掉的只有底下那排轉移。
  final bool readOnly;

  /// 抽屜寬度。窄視窗時由呼叫端縮，但**不吃滿**——留一段板子看得到，
  /// 才知道自己還在板上而不是換了一個畫面。
  final double width;

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: s.bg,
        border: Border(left: BorderSide(color: s.hairlineStrong)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .35),
            blurRadius: 60,
            offset: const Offset(-30, 0),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
              children: [
                _title(context),
                if (task.description.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Text(task.description,
                      style: UepText.serif(
                          size: 13, color: s.inkSoft, height: 1.95)),
                ],
                const SizedBox(height: 18),
                _meta(context),
                if (task.sourceSeq != null) ...[
                  const SizedBox(height: 18),
                  _source(context, ref),
                ],
              ],
            ),
          ),
          if (!readOnly) _TaskActionBar(roomId: roomId, task: task),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    final s = context.uep;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: s.bgSoft,
        border: Border(bottom: BorderSide(color: s.hairline)),
      ),
      child: Row(children: [
        Expanded(
          child: Text(
            checklistTitle.isEmpty ? 'TASK' : 'TASK · $checklistTitle',
            overflow: TextOverflow.ellipsis,
            style:
                UepText.mono(size: 9, color: s.inkMute, letterSpacing: 1.8),
          ),
        ),
        InkWell(
          onTap: onClose,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text('✕',
                style: UepText.mono(size: 11, color: s.inkSoft)),
          ),
        ),
      ]),
    );
  }

  Widget _title(BuildContext context) {
    final s = context.uep;
    // 色軸在這裡也留著：卡片上是誰的顏色，抽屜裡就是誰的顏色
    final axisColor = switch (task.axis) {
      ClaimAxis.held || ClaimAxis.orphaned => task.claimKind.isEmpty
          ? s.ink
          : kindColor(task.claimKind, context: context),
      _ => s.hairlineStrong,
    };
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(width: 2, color: axisColor),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(task.title,
                    style: UepText.display(
                        size: 21,
                        weight: FontWeight.w600,
                        color: s.inkTitle,
                        height: 1.35)),
                const SizedBox(height: 9),
                Row(children: [
                  _StatusChip(status: task.status),
                  if (task.priority == 'high') ...[
                    const SizedBox(width: 8),
                    Text('▲ 高',
                        style: UepText.mono(size: 8.5, color: s.inkTitle)),
                  ],
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 中繼資料。**空的列不畫**——「指定對象：（無）」比不寫更佔位置，
  /// 而這個抽屜的每一列都該是一件確實成立的事。
  Widget _meta(BuildContext context) {
    final s = context.uep;
    final rows = <Widget>[];

    if (task.claimName.isNotEmpty) {
      rows.add(_MetaRow(
        label: '持有者',
        value: task.claimName,
        struck: task.isOrphaned,
        kind: task.claimKind,
        trailing: task.isOrphaned
            ? (task.orphanedReasonLabel.isEmpty
                ? '已不在房內'
                : task.orphanedReasonLabel)
            : (task.claimedAt == null
                ? ''
                : '${relativeTime(task.claimedAt)} 認領'),
        trailingIsAlert: task.isOrphaned,
      ));
    }
    if (assigneeName != null) {
      rows.add(_MetaRow(
        label: '指定對象',
        value: assigneeName!,
        // 誰指定的要寫出來——「建議」不是規則，看得到是誰提的才知道份量
        trailing: task.assignedByName.isEmpty
            ? '建議'
            : '${task.assignedByName}指定 · 建議',
      ));
    }
    if (task.createdByName.isNotEmpty) {
      rows.add(_MetaRow(
        label: '建立',
        value: task.createdByName,
        trailing: relativeTime(task.createdAt),
      ));
    }
    if (rows.isEmpty) return const SizedBox.shrink();

    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: s.hairline),
          bottom: BorderSide(color: s.hairline),
        ),
      ),
      child: Column(children: [
        for (var i = 0; i < rows.length; i++)
          Container(
            decoration: i == 0
                ? null
                : BoxDecoration(
                    border: Border(top: BorderSide(color: s.hairline))),
            child: rows[i],
          ),
      ]),
    );
  }

  /// 長出這張卡的訊息。內文從已載入的 feed 拿得到就畫，拿不到就只給路。
  ///
  /// **拿不到不是錯誤**：那則訊息可能在還沒捲到的歷史裡。跳轉本身照樣成立，
  /// 所以不要因為引不到內文就把入口一起收掉。
  Widget _source(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final seq = task.sourceSeq!;
    final message = ref.watch(roomFeedProvider(roomId)).bySeq(seq);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('長出這張卡的訊息',
            style:
                UepText.mono(size: 8.5, color: s.inkMute, letterSpacing: 1.6)),
        const SizedBox(height: 8),
        InkWell(
          onTap: () => context.go('/rooms/$roomId?focusSeq=$seq'),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 2, color: UepColors.gold),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    decoration: BoxDecoration(
                      color: s.bgCard,
                      border: Border(
                        top: BorderSide(color: s.hairline),
                        right: BorderSide(color: s.hairline),
                        bottom: BorderSide(color: s.hairline),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            if (message != null) ...[
                              Flexible(
                                child: Text(message.senderName ?? '',
                                    overflow: TextOverflow.ellipsis,
                                    style: UepText.sans(
                                        size: 12,
                                        weight: FontWeight.w600,
                                        color: s.inkTitle)),
                              ),
                              const SizedBox(width: 8),
                            ],
                            const Spacer(),
                            Text('#$seq',
                                style: UepText.mono(
                                    size: 8.5, color: s.inkMute)),
                          ],
                        ),
                        if (message != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            message.content,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: UepText.serif(
                                size: 12, color: s.inkSoft, height: 1.75),
                          ),
                        ] else ...[
                          const SizedBox(height: 6),
                          Text('這則訊息還沒載入到手上。',
                              style: UepText.serif(
                                  size: 12, color: s.inkMute)),
                        ],
                        const SizedBox(height: 6),
                        Text('↩ 跳回聊天室',
                            style: UepText.mono(
                                size: 8.5,
                                color: UepColors.gold,
                                letterSpacing: 1.2)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

}

/// 底部動作列。**只給狀態轉移，不給認領**——認領在卡片上，那是掃視板子
/// 時就該按得到的東西；進到這裡的人已經在看細節了。
///
/// 出哪幾顆完全由 [taskActionsFor] 決定，這裡不做任何自己的判斷。舊版是
/// 「還沒收尾就全部出」，於是 `todo` 長出「標記完成」、`blocked` 長出
/// 「標記完成」、`done` 的重新開啟送 `todo`——四顆非法按鈕，按下去只會拿
/// 409，而當時連 409 都看不見。
class _TaskActionBar extends ConsumerStatefulWidget {
  const _TaskActionBar({required this.roomId, required this.task});

  final String roomId;
  final BoardTask task;

  @override
  ConsumerState<_TaskActionBar> createState() => _TaskActionBarState();
}

class _TaskActionBarState extends ConsumerState<_TaskActionBar> {
  /// Hub 在上一個 409 裡說的「從這裡還能去哪」。
  ///
  /// 本機那份轉移表是副本，副本會漂移；有了這個，畫面在漂移發生時會自己
  /// 收斂回 Hub 的說法，而不是留著一顆永遠按不動的按鈕。
  Set<String>? _allowed;

  @override
  void didUpdateWidget(_TaskActionBar old) {
    super.didUpdateWidget(old);
    // 狀態變了，上一次的 allowed 是對上一個狀態說的，留著會蓋錯
    if (old.task.status != widget.task.status) _allowed = null;
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final actions = ref.read(boardActionsProvider(widget.roomId));
    final items = taskActionsFor(widget.task.status, allowed: _allowed);

    Widget button(TaskAction a) => _DrawerAction(
          label: a.label,
          bordered: !a.trailing,
          accent: a.danger ? UepColors.error : null,
          onTap: () => runBoardAction(
            context,
            () => actions.setTaskStatus(widget.task.id, a.target),
            onConflict: (e) {
              // 拒絕本身要說出來，順手把按鈕修正成 Hub 認的那幾顆
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(e.message)));
              if (e.allowed.isNotEmpty && mounted) {
                setState(() => _allowed = e.allowed.toSet());
              }
            },
          ),
        );

    final leading = items.where((a) => !a.trailing).toList();
    final trailing = items.where((a) => a.trailing).toList();

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: s.hairline)),
      ),
      child: Row(children: [
        for (final a in leading) ...[
          button(a),
          if (a != leading.last) const SizedBox(width: 8),
        ],
        const Spacer(),
        for (final a in trailing) button(a),
      ]),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.label,
    required this.value,
    this.trailing = '',
    this.kind = '',
    this.struck = false,
    this.trailingIsAlert = false,
  });

  final String label;
  final String value;
  final String trailing;
  final String kind;
  final bool struck;
  final bool trailingIsAlert;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(children: [
        SizedBox(
          width: 76,
          child: Text(label,
              style: UepText.mono(
                  size: 8.5, color: s.inkMute, letterSpacing: 1.4)),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            overflow: TextOverflow.ellipsis,
            style: UepText.sans(
                    size: 12.5,
                    weight: struck ? FontWeight.w400 : FontWeight.w600,
                    color: struck ? s.inkMute : s.inkTitle)
                .copyWith(
              decoration: struck ? TextDecoration.lineThrough : null,
            ),
          ),
        ),
        if (kind.isNotEmpty) ...[
          const SizedBox(width: 8),
          Text(kind.toUpperCase(),
              style: UepText.mono(
                size: 8,
                letterSpacing: 1.0,
                color: struck ? s.inkMute : kindColor(kind, context: context),
              )),
        ],
        const Spacer(),
        if (trailing.isNotEmpty)
          Text(trailing,
              style: UepText.mono(
                  size: 8.5,
                  color: trailingIsAlert ? UepColors.error : s.inkMute)),
      ]),
    );
  }
}

/// 抽屜標題底下的狀態徽章。與卡片上那顆同一套規則：
/// **只有卡住與完成帶色**。
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;

  static const _labels = {
    'todo': '待辦',
    'in_progress': '進行中',
    'blocked': '卡住',
    'done': '完成',
    'cancelled': '已取消',
  };

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final (color, border, background) = switch (status) {
      'in_progress' => (s.inkTitle, s.inkMute, s.bgSoft),
      'blocked' => (
          UepColors.error,
          UepColors.error.withValues(alpha: .4),
          null,
        ),
      'done' => (
          UepColors.success,
          UepColors.success.withValues(alpha: .35),
          null,
        ),
      'cancelled' => (s.inkMute, s.hairline, null),
      _ => (s.inkMute, s.hairlineStrong, null),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: border),
      ),
      child: Text(_labels[status] ?? status,
          style: UepText.mono(size: 8, color: color, letterSpacing: 1.1)),
    );
  }
}

class _DrawerAction extends StatelessWidget {
  const _DrawerAction({
    required this.label,
    required this.onTap,
    this.bordered = true,
    this.accent,
  });

  final String label;
  final VoidCallback onTap;
  final bool bordered;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: bordered
            ? const EdgeInsets.symmetric(horizontal: 13, vertical: 7)
            : const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
        decoration: bordered
            ? BoxDecoration(border: Border.all(color: s.hairlineStrong))
            : null,
        child: Text(label,
            style: UepText.mono(
                size: 9,
                color: accent ?? s.inkSoft,
                letterSpacing: 1.4)),
      ),
    );
  }
}
