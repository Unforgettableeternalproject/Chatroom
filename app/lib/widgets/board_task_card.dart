import 'package:flutter/material.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../core/util/relative_time.dart';
import '../models/board.dart';
import 'actor_name.dart';
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
    this.holder,
    this.isMineToReclaim = false,
    this.conflict,
    this.onTap,
    this.onClaim,
    this.onRelease,
    this.onToggleWatch,
    this.watchBlockedReason = '',
  });

  final BoardTask task;

  /// 被指定者的顯示名稱（`assignee_participant_id` 查出來的）。
  /// 查不到就不畫——指定是「現在該由誰做」，人不在了就該看得出這個指定
  /// 已經沒有意義（所以 Hub 刻意不為它存名字快照）。
  final String? assigneeName;

  /// 持有者在**板上**的身分（由 `claim_actor_key` 查 [BoardSnapshot.members]）。
  ///
  /// 給了就用它——同一個人在不同房可能叫不同名字，板上要統一成最早進入的
  /// 那個，而別名掛在它身上。**查不到就傳 null**，卡片會退回 `claim_name`
  /// 快照：那份永遠都在，而且是「他當時叫什麼」的正確答案。
  final BoardActorRef? holder;

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

  /// 切換追蹤。`null` ＝這張卡現在不能追（唯讀、或這塊板沒有掛接房）。
  final VoidCallback? onToggleWatch;

  /// 不能追的原因。**有原因就要說出來**——一顆灰掉沒有解釋的按鈕，
  /// 使用者會一直點它，然後以為壞了。裁決 #392 ③ 要的是「明確擋下」，
  /// 而不是「可以追但收不到」：後者要等到卡完成才發現，而那時他已經在等了。
  final String watchBlockedReason;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final axis = task.axis;

    // 完成與取消收合成單行——事情結束，誰做的退成註記。
    if (axis == ClaimAxis.completed) return _completedRow(context);

    final axisColor = _axisColor(context);
    // 邊框說的是「這張卡現在對誰有話要說」：金＝只有你看得到的撿回提示，
    // 紅＝持有者不在了。兩者都比一般卡更需要被看見，所以邊框帶色而不是靠底色。
    final borderColor = isMineToReclaim
        ? UepColors.gold.withValues(alpha: .45)
        : axis == ClaimAxis.orphaned
            ? UepColors.error.withValues(alpha: .3)
            : s.hairline;
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: s.bgCard,
          border: Border.all(color: borderColor),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Axis(color: axisColor, broken: axis == ClaimAxis.orphaned),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _titleRow(context),
                      if (task.description.isNotEmpty) ...[
                        const SizedBox(height: 7),
                        Text(
                          task.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: UepText.serif(
                              size: 12, color: s.inkSoft, height: 1.7),
                        ),
                      ],
                      const SizedBox(height: 7),
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
              size: 13.5,
              weight: FontWeight.w600,
              color: s.inkTitle,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(width: 8),
        _WatchToggle(
          watching: task.watching,
          count: task.watcherCount,
          onTap: onToggleWatch,
          blockedReason: watchBlockedReason,
        ),
        const SizedBox(width: 8),
        // 狀態徽章。⚠️ 孤兒不改它——變的是人不是進度
        _StatusBadge(status: task.status),
      ],
    );
  }

  /// 卡片下緣那一行：誰在這張卡上，以及還能對它做什麼。
  Widget _footer(BuildContext context) {
    final s = context.uep;

    // 認領失敗＝一個事實，不是錯誤。放在最前面判斷：這一瞬間其他資訊
    // 都不重要，使用者只需要知道「誰贏了」
    if (conflict != null) {
      return _Notice(
        background: s.bgSoft,
        edge: s.hairlineStrong,
        child: Text.rich(
          TextSpan(
            style: UepText.serif(size: 12, color: s.inkSoft),
            children: [
              const TextSpan(text: '已經被 '),
              TextSpan(
                text: conflict,
                style: UepText.serif(
                    size: 12, weight: FontWeight.w600, color: s.inkTitle),
              ),
              const TextSpan(text: ' 領走了。'),
            ],
          ),
        ),
      );
    }

    return switch (task.axis) {
      ClaimAxis.held => Row(children: [
          Expanded(child: _holder(context, struck: false)),
          if (task.priority == 'high') ...[
            const SizedBox(width: 9),
            Text('▲ 高',
                style: UepText.mono(size: 8.5, color: s.inkTitle)),
          ],
          if (onRelease != null) ...[
            const SizedBox(width: 9),
            _TinyAction(label: '釋放認領', onTap: onRelease!),
          ],
        ]),
      ClaimAxis.orphaned => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: _holder(context, struck: true)),
              if (onRelease != null) ...[
                const SizedBox(width: 9),
                _TinyAction(label: '釋放認領', onTap: onRelease!),
              ],
            ]),
            if (isMineToReclaim) ...[
              const SizedBox(height: 8),
              _Notice(
                background: UepColors.gold.withValues(alpha: .09),
                edge: UepColors.gold,
                trailing: onClaim == null
                    ? null
                    : _TinyAction(
                        label: '撿回', onTap: onClaim!, color: UepColors.gold),
                child: Text('這是你上一世領走的卡。',
                    style: UepText.serif(size: 12, color: UepColors.gold)),
              ),
            ] else if (onClaim != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: _TinyAction(label: '接手', onTap: onClaim!),
              ),
            ],
          ],
        ),
      ClaimAxis.suggested => Row(children: [
          Text('建議給 ',
              style: UepText.mono(size: 8.5, color: s.inkSoft)),
          Text(assigneeName ?? '（已不在房內）',
              style: UepText.mono(size: 8.5, color: s.ink)),
          const SizedBox(width: 9),
          _Dot(color: s.inkMute),
          const SizedBox(width: 9),
          // 「建議不是鎖」要寫出來——不寫的話被指名者以外的人會以為自己不該碰
          Flexible(
            child: Text('建議不是鎖，誰都能領',
                overflow: TextOverflow.ellipsis,
                style: UepText.mono(size: 8.5, color: s.inkMute)),
          ),
          const Spacer(),
          if (onClaim != null) _TinyAction(label: '我來做', onTap: onClaim!),
        ]),
      _ => Row(children: [
          Text('尚未認領',
              style: UepText.mono(size: 8.5, color: s.inkMute)),
          if (task.priority == 'high') ...[
            const SizedBox(width: 9),
            _Dot(color: s.inkMute),
            const SizedBox(width: 9),
            Text('▲ 高', style: UepText.mono(size: 8.5, color: s.inkTitle)),
          ],
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
        spacing: 9,
        children: [
          if (holder != null)
            ActorName(
              actor: holder!,
              size: 11.5,
              color: struck ? s.inkMute : s.ink,
            )
          else
            Text(
              task.claimName.isEmpty ? '（不明）' : task.claimName,
              // 名字劃掉：他曾經在這張卡上，那是事實；他現在不在，也是事實
              style: UepText.sans(
                      size: 11.5,
                      weight: FontWeight.w600,
                      color: struck ? s.inkMute : s.ink)
                  .copyWith(
                decoration: struck ? TextDecoration.lineThrough : null,
              ),
            ),
          // kind 沒給（舊資料）就不畫徽章，不要猜。
          // 孤兒時 kind 一起退成灰：他的種類色屬於「他在這張卡上」的那段時間
          if (task.claimKind.isNotEmpty)
            _KindText(kind: task.claimKind, muted: struck),
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
            // 孤兒的那句話用 error 色：它是這張卡上最該被看見的一件事
            style: UepText.mono(
                size: 8.5, color: struck ? UepColors.error : s.inkMute),
          ),
        ],
    );
  }

  Widget _completedRow(BuildContext context) {
    final s = context.uep;
    final cancelled = task.status == 'cancelled';
    return InkWell(
      onTap: onTap,
      child: Opacity(
        // 取消退得比完成更遠：完成是一個成果，取消只是一筆不再發生的事
        opacity: cancelled ? .5 : .62,
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            // 取消不填色、不佔視覺重量，但留在原位
            color: cancelled ? Colors.transparent : s.bgCard,
            border: Border.all(color: s.hairline),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Axis(
                    color: cancelled ? Colors.transparent : s.hairlineStrong,
                    broken: false),
                Expanded(
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: Row(
                      children: [
                        Text(cancelled ? '✕' : '✓',
                            style: UepText.mono(
                                size: 10,
                                color: cancelled
                                    ? s.inkMute
                                    : UepColors.success)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            task.title,
                            overflow: TextOverflow.ellipsis,
                            style: UepText.sans(
                                    size: 13,
                                    color:
                                        cancelled ? s.inkMute : s.inkSoft,
                                    height: 1.5)
                                .copyWith(
                              decoration: cancelled
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                        ),
                        // 誰做的退成註記——還在，但不再是主角
                        if (!cancelled && task.claimName.isNotEmpty) ...[
                          const SizedBox(width: 12),
                          if (holder != null)
                            ActorName(
                                actor: holder!, size: 11.5, color: s.inkMute)
                          else
                            Text(task.claimName,
                                style: UepText.sans(
                                    size: 11.5, color: s.inkMute)),
                          if (task.claimKind.isNotEmpty) ...[
                            const SizedBox(width: 12),
                            _KindText(kind: task.claimKind, muted: true),
                          ],
                        ],
                        const SizedBox(width: 12),
                        _StatusBadge(status: task.status),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
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
      // 孤兒的軸**不調淡**——顏色說的是「這是誰的卡」，那件事沒有變。
      // 變的是連續性，所以斷的是線不是色
      ClaimAxis.orphaned => task.claimKind.isEmpty
          ? s.ink
          : kindColor(task.claimKind, context: context),
      // 有人被指名，但還沒有人站上去：半透明＝這個顏色還沒有兌現
      ClaimAxis.suggested => s.hairlineStrong,
      _ => s.hairline,
    };
  }
}

/// 左側色軸。[broken] 時畫成整條虛線——線斷了，人不在了。
///
/// 設計稿是 `repeating-linear-gradient`（5px 實、6px 空）。Flutter 沒有這個，
/// 用等分的堆疊畫；**整條都要斷**，不是中間斷一截——後者看起來像兩段各自
/// 完整的線，而這張卡的意思是「沒有人在上面」。
class _Axis extends StatelessWidget {
  const _Axis({required this.color, required this.broken});

  final Color color;
  final bool broken;

  @override
  Widget build(BuildContext context) {
    if (!broken) return Container(width: 2, color: color);
    // ⚠️ 不要用 LayoutBuilder 量高度：這條軸活在 IntrinsicHeight 底下，
    // 而 LayoutBuilder 算不出 intrinsic 尺寸（會 assert）。CustomPaint
    // 拿得到最終的 size，不需要先問。
    return SizedBox(
      width: 2,
      child: CustomPaint(painter: _DashedAxisPainter(color)),
    );
  }
}

/// 垂直虛線：5px 實、6px 空（設計稿的 `repeating-linear-gradient`）。
class _DashedAxisPainter extends CustomPainter {
  const _DashedAxisPainter(this.color);

  final Color color;

  static const _dash = 5.0;
  static const _gap = 6.0;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (var y = 0.0; y < size.height; y += _dash + _gap) {
      final h = (y + _dash > size.height) ? size.height - y : _dash;
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, h), paint);
    }
  }

  @override
  bool shouldRepaint(_DashedAxisPainter old) => old.color != color;
}

/// mono 小字的 kind 標。[muted] 時退成灰——用在持有者已經不在的卡上。
///
/// 刻意不用共用的 [KindBadge]：那支同時服務聊天室，而這裡需要一個
/// 「同樣的字、但不帶種類色」的變體，加參數會讓那支為了 board 長出旋鈕。
class _KindText extends StatelessWidget {
  const _KindText({required this.kind, this.muted = false});

  final String kind;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Text(
      kind.toUpperCase(),
      style: UepText.mono(
        size: 8,
        letterSpacing: 1.0,
        color: muted
            ? context.uep.inkMute
            : kindColor(kind, context: context),
      ),
    );
  }
}

/// 卡片內的一段告示：左邊 2px 色條 + 淡底。用在「認領失敗」與「撿回」。
class _Notice extends StatelessWidget {
  const _Notice({
    required this.child,
    required this.background,
    required this.edge,
    this.trailing,
  });

  final Widget child;
  final Color background;
  final Color edge;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: background,
        border: Border(left: BorderSide(color: edge, width: 2)),
      ),
      child: Row(children: [
        Expanded(child: child),
        ?trailing,
      ]),
    );
  }
}

/// 3px 的分隔圓點（設計稿在 mono 小字之間用它斷句）。
class _Dot extends StatelessWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 3,
        height: 3,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
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
    // ⚠️ 設計規則：**只有卡住與完成帶色**。待辦與進行中都是中性的——
    // 顏色在這塊板上已經有工作了（色軸講「誰」），徽章再上色會讓兩個
    // 維度打架，而進行中是常態，把常態畫成綠色等於整塊板都在發光。
    // 進行中與待辦的差別靠**填底**而不是顏色。
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
      child: Text(
        _labels[status] ?? status,
        style: UepText.mono(size: 8, color: color, letterSpacing: 1.1),
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
    final c = color ?? s.inkSoft;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(
              color: color == null
                  ? s.hairlineStrong
                  : c.withValues(alpha: .5)),
        ),
        child: Text(
          label,
          style: UepText.mono(size: 8.5, color: c, letterSpacing: 1.0),
        ),
      ),
    );
  }
}

/// 追蹤的開關與「有幾個人在等」。
///
/// 兩件事擠在同一顆小元件上是刻意的：**追蹤者關心「我有沒有在等」，
/// 認領者關心「有幾個人在等我」**，而那是同一張卡上的同一個數字。
/// 拆成兩處的話，認領者要多看一個地方才知道自己卡住了誰。
class _WatchToggle extends StatelessWidget {
  const _WatchToggle({
    required this.watching,
    required this.count,
    required this.onTap,
    required this.blockedReason,
  });

  final bool watching;
  final int count;
  final VoidCallback? onTap;
  final String blockedReason;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    // 不能追、也沒有人在等 ⇒ 整顆不畫。灰掉一顆永遠不能按的按鈕，
    // 在一塊本來就不支援追蹤的板上只是噪音
    if (onTap == null && count == 0 && blockedReason.isEmpty) {
      return const SizedBox.shrink();
    }
    final color = watching ? UepColors.gold : s.inkMute;
    final chip = Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(watching ? Icons.notifications_active : Icons.notifications_none,
          size: 13, color: onTap == null ? s.inkMute : color),
      if (count > 0) ...[
        const SizedBox(width: 3),
        Text('$count',
            style: UepText.mono(size: 9, letterSpacing: .8, color: color)),
      ],
    ]);
    if (onTap == null) {
      // ⚠️ 原因走 Tooltip：桌面 hover、行動端長按都拿得到，而它不佔版面。
      // 完全不解釋的話，使用者只看到一顆按不動的鈴鐺
      return Tooltip(
        message: blockedReason.isEmpty ? '現在不能追蹤這張卡' : blockedReason,
        child: Opacity(opacity: .4, child: chip),
      );
    }
    return Tooltip(
      message: watching
          ? '取消追蹤。已經送到收件匣的通知不會收回'
          : '追蹤：它完成、取消或重新打開時通知我',
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
          child: chip,
        ),
      ),
    );
  }
}
