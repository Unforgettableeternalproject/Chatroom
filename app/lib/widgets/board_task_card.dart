import 'package:flutter/material.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../core/util/relative_time.dart';
import '../models/board.dart';
import 'kind_badge.dart';

/// Board 的 Task 卡片。
///
/// 設計稿（`Board 外觀設計.dc.html` artboard 02）的核心規則，實作不要自己改：
///
/// > **色軸講誰，徽章講到哪。**
///
/// 認領與狀態是兩個正交的維度，各走各的視覺通道。最要緊的是**孤兒卡的狀態
/// 徽章不變**——一張做到一半而持有者不見了的卡，如果把狀態一起打回「待辦」，
/// 它就跟沒人碰過的卡長得一模一樣，而那正是 board 上最需要被看見的一種。
class BoardTaskCard extends StatelessWidget {
  const BoardTaskCard({
    super.key,
    required this.task,
    this.assigneeName,
    this.isMineToReclaim = false,
    this.conflict,
    this.onTap,
    this.onClaim,
    this.onRelease,
  });

  final BoardTask task;

  /// 被指定者的顯示名稱（`assignee_participant_id` 查出來的）。
  /// 查不到就不畫——指定是「現在該由誰做」，人不在了就該看得出這個指定
  /// 已經沒有意義（所以 Hub 刻意不為它存名字快照）。
  final String? assigneeName;

  /// 這張是我這把 session 上一世領走的。金框只有本人看得到。
  final bool isMineToReclaim;

  /// 剛剛認領失敗時，Hub 回的現任持有者。
  ///
  /// **這不是錯誤狀態**：兩個 agent 同時領同一張，本來就只有一個會成功。
  /// 卡片直接換成事實，沒有紅字、沒有重試按鈕。
  final String? conflict;

  final VoidCallback? onTap;
  final VoidCallback? onClaim;
  final VoidCallback? onRelease;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final axis = task.axis;

    // 完成與取消收合成單行——事情結束，誰做的退成註記。
    if (axis == ClaimAxis.completed) return _completedRow(context);

    final axisColor = _axisColor(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          color: s.bgCard,
          borderRadius: const BorderRadius.horizontal(right: Radius.circular(4)),
          border: isMineToReclaim
              ? Border.all(color: UepColors.gold.withValues(alpha: .55))
              : Border.all(color: s.hairline),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Axis(color: axisColor, broken: axis == ClaimAxis.orphaned),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _titleRow(context),
                      if (task.description.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          task.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: UepText.serif(size: 11, color: s.inkMute),
                        ),
                      ],
                      const SizedBox(height: 6),
                      _footer(context),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _titleRow(BuildContext context) {
    final s = context.uep;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            task.title,
            style: UepText.sans(
              size: 13,
              weight: FontWeight.w600,
              color: s.inkTitle,
            ),
          ),
        ),
        const SizedBox(width: 8),
        // 狀態徽章。⚠️ 孤兒不改它——變的是人不是進度
        _StatusBadge(status: task.status),
        if (task.priority == 'high') ...[
          const SizedBox(width: 6),
          Text('▲ 高',
              style: UepText.mono(size: 9, color: UepColors.kindOther)),
        ],
      ],
    );
  }

  /// 卡片下緣那一行：誰在這張卡上，以及還能對它做什麼。
  Widget _footer(BuildContext context) {
    final s = context.uep;

    // 認領失敗＝一個事實，不是錯誤。放在最前面判斷：這一瞬間其他資訊
    // 都不重要，使用者只需要知道「誰贏了」
    if (conflict != null) {
      return Text(
        '已經被 $conflict 領走了。',
        style: UepText.mono(size: 10, color: s.inkMute),
      );
    }

    return switch (task.axis) {
      ClaimAxis.held => Row(children: [
          Expanded(child: _holder(context, struck: false)),
          const SizedBox(width: 8),
          if (onRelease != null)
            _TinyAction(label: '釋放認領', onTap: onRelease!),
        ]),
      ClaimAxis.orphaned => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _holder(context, struck: true),
            if (isMineToReclaim) ...[
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                  child: Text('這是你上一世領走的卡。',
                      style: UepText.mono(
                          size: 10, color: UepColors.gold)),
                ),
                if (onClaim != null)
                  _TinyAction(
                      label: '撿回', onTap: onClaim!, color: UepColors.gold),
              ]),
            ] else if (onClaim != null) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: _TinyAction(label: '接手', onTap: onClaim!),
              ),
            ],
          ],
        ),
      ClaimAxis.suggested => Row(children: [
          Text('建議給 ',
              style: UepText.mono(size: 10, color: s.inkMute)),
          Text(assigneeName ?? '（已不在房內）',
              style: UepText.mono(size: 10, color: s.ink)),
          const Spacer(),
          if (onClaim != null) _TinyAction(label: '我來做', onTap: onClaim!),
        ]),
      _ => Row(children: [
          Text('尚未認領',
              style: UepText.mono(size: 10, color: s.inkMute)),
          const Spacer(),
          if (onClaim != null) _TinyAction(label: '認領', onTap: onClaim!),
        ]),
    };
  }

  /// 持有者那一行。孤兒時名字劃掉、補上為什麼不在了。
  ///
  /// ⚠️ **不自己包 `Expanded`**：它同時被放進 Row（held）與 Column
  /// （orphaned），而 Column 在卡片裡是無界高度的，Expanded 進去就爆。
  /// 要撐滿的那一邊自己包。
  Widget _holder(BuildContext context, {required bool struck}) {
    final s = context.uep;
    final when = task.claimedAt == null
        ? ''
        : relativeTime(task.claimedAt);
    return Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        children: [
          Text(
            task.claimName.isEmpty ? '（不明）' : task.claimName,
            // 名字劃掉：他曾經在這張卡上，那是事實；他現在不在，也是事實
            style: UepText.sans(size: 11, color: struck ? s.inkMute : s.ink)
                .copyWith(
              decoration: struck ? TextDecoration.lineThrough : null,
            ),
          ),
          // kind 沒給（舊資料）就不畫徽章，不要猜
          if (task.claimKind.isNotEmpty)
            KindBadge(kind: task.claimKind, compact: true),
          Text(
            struck
                ? [
                    if (task.orphanedReasonLabel.isNotEmpty)
                      task.orphanedReasonLabel
                    else
                      '已不在房內',
                    if (when.isNotEmpty) '$when 認領',
                  ].join(' · ')
                : when.isEmpty
                    ? ''
                    : '$when 認領',
            style: UepText.mono(size: 9, color: s.inkMute),
          ),
        ],
    );
  }

  Widget _completedRow(BuildContext context) {
    final s = context.uep;
    final cancelled = task.status == 'cancelled';
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            Text(cancelled ? '✕' : '✓',
                style: UepText.mono(
                    size: 11,
                    color: cancelled ? s.inkMute : UepColors.success)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                task.title,
                overflow: TextOverflow.ellipsis,
                style: UepText.sans(size: 12, color: s.inkMute).copyWith(
                  decoration: cancelled ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
            if (!cancelled && task.claimName.isNotEmpty)
              Text(task.claimName,
                  style: UepText.mono(size: 9, color: s.inkMute)),
            if (cancelled)
              Text('已取消', style: UepText.mono(size: 9, color: s.inkMute)),
          ],
        ),
      ),
    );
  }

  Color _axisColor(BuildContext context) {
    final s = context.uep;
    return switch (task.axis) {
      // 持有者的種類色。kind 沒給就退成一般前景色——寧可少一個資訊，
      // 也不要用猜的顏色說「他是 claude」
      ClaimAxis.held => task.claimKind.isEmpty
          ? s.ink
          : kindColor(task.claimKind, context: context),
      ClaimAxis.orphaned => (task.claimKind.isEmpty
              ? s.ink
              : kindColor(task.claimKind, context: context))
          .withValues(alpha: .5),
      // 有人被指名，但還沒有人站上去
      ClaimAxis.suggested => s.hairlineStrong,
      _ => s.hairline,
    };
  }
}

/// 左側色軸。[broken] 時畫成斷開的兩截——線斷了，人不在了。
class _Axis extends StatelessWidget {
  const _Axis({required this.color, required this.broken});

  final Color color;
  final bool broken;

  @override
  Widget build(BuildContext context) {
    if (!broken) return Container(width: 2, color: color);
    return SizedBox(
      width: 2,
      child: Column(
        children: [
          Expanded(flex: 2, child: Container(color: color)),
          const Expanded(flex: 3, child: SizedBox()),
          Expanded(flex: 2, child: Container(color: color)),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

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
    final color = switch (status) {
      'in_progress' => UepColors.kindClaude,
      'blocked' => UepColors.kindOther,
      'done' => UepColors.success,
      _ => s.inkMute,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: .4)),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(
        _labels[status] ?? status,
        style: UepText.mono(size: 8.5, color: color, letterSpacing: .8),
      ),
    );
  }
}

class _TinyAction extends StatelessWidget {
  const _TinyAction({required this.label, required this.onTap, this.color});

  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          label,
          style: UepText.mono(size: 10, color: color ?? s.ink),
        ),
      ),
    );
  }
}
