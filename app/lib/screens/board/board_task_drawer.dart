import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../core/util/relative_time.dart';
import '../../models/board.dart';
import '../../models/participant.dart';
import '../../state/board_providers.dart';
import '../../state/messages_providers.dart';
import '../../state/rooms_providers.dart';
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
    required this.boardId,
    required this.task,
    required this.checklistTitle,
    required this.onClose,
    this.assigneeName,
    this.readOnly = false,
    this.width = 420,
  });

  /// 從哪一間房打開的。**板軸（Board Library）進來時是 null**——那時沒有
  /// 房內身分，也沒有訊息流可以跳回去。
  ///
  /// ⚠️ 這裡從前是 `String`，而板軸的呼叫端寫 `widget.roomId!` ⇒ 板軸點開
  /// 任何一張卡都是 build 期 null check 例外，畫面整片灰、沒有任何錯誤訊息
  /// （艾斯維爾 2026-09-03 實機）。
  final String? roomId;

  /// 這張卡屬於哪塊板。**兩條軸都有**，動作要靠它挑身分來源。
  final String boardId;

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
    // 與這張卡有關的商量。Hub **只回與我有關的**（我提的、或指名我的）——
    // 全部都回的話，房裡每個人都看得到別人之間的商量，那不是通知是廣播。
    final snap = roomId != null
        ? ref.watch(boardProvider(roomId!)).value
        : ref.watch(boardByIdProvider(boardId)).value;
    final requests = [
      for (final r in snap?.taskRequests ?? const <TaskRequest>[])
        if (r.taskId == task.id) r,
    ];
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
                _meta(context, requests),
                // 來源訊息只有房軸看得到——板軸沒有房，就沒有那條路。
                // **拿不到不是錯誤**，收起來就好
                if (task.sourceSeq != null && roomId != null) ...[
                  const SizedBox(height: 18),
                  _source(context, ref),
                ],
              ],
            ),
          ),
          if (!readOnly)
            _TaskActionBar(
              requests: requests,
              roomId: roomId,
              boardId: boardId,
              task: task,
            ),
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
  Widget _meta(BuildContext context, List<TaskRequest> requests) {
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
    for (final r in requests) {
      rows.add(_MetaRow(
        label: r.isPending ? '待回覆' : (r.isAccepted ? '已接受' : '已婉拒'),
        value: r.targetName.isEmpty ? '某人' : r.targetName,
        // 🔴 **拒絕留紀錄不刪除**（Hub 刻意）：提議者要分得出「他看過了
        // 說不要」與「他還沒看到」——前者要換人，後者要再等。把拒絕的
        // 那筆從畫面上拿掉，兩種處境會長得一模一樣
        trailing: r.requesterName.isEmpty
            ? ''
            : '${r.requesterName}提出 · ${relativeTime(r.createdAt)}',
        struck: r.isDeclined,
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
    final rid = roomId!;
    final message = ref.watch(roomFeedProvider(rid)).bySeq(seq);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('長出這張卡的訊息',
            style:
                UepText.mono(size: 8.5, color: s.inkMute, letterSpacing: 1.6)),
        const SizedBox(height: 8),
        InkWell(
          onTap: () => context.go('/rooms/$rid?focusSeq=$seq'),
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
  const _TaskActionBar({
    this.requests = const [],
    required this.roomId,
    required this.boardId,
    required this.task,
  });

  /// 與這張卡有關、**與我有關**的商量。
  final List<TaskRequest> requests;

  final String? roomId;
  final String boardId;
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

  /// 回答一筆請求。**拒絕也要送出去**——不回答與說不要是兩件事，
  /// 而提議者只能從這裡分辨。
  Future<void> _respond(
      BoardActions actions, TaskRequest r, bool accept) async {
    await runBoardAction(context, () async {
      await actions.resolveTaskRequest(r.id, accept: accept);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(accept ? '接下了，這張卡現在指向你' : '已回覆婉拒'),
      ));
    });
  }

  /// 挑一個房內的人，把這張卡請給他。
  ///
  /// 送出後**要說出實際發生了什麼**：管理員按下去是「已指派」，其他人是
  /// 「已送出請求，等他回覆」。兩種都正常，但說錯的話提議者會以為事情
  /// 已經定了。
  Future<void> _assign(BoardActions actions) async {
    final detail = ref.read(roomDetailProvider(widget.roomId!)).value;
    final members = [
      for (final p in detail?.participants ?? const <Participant>[])
        // 已離開的人指了也沒用——他收不到，那張卡只會掛著
        if (p.status == 'active') p,
    ];
    final picked = await showDialog<Participant>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('請誰接手這張卡',
            style: UepText.display(size: 17, color: ctx.uep.inkTitle)),
        children: [
          for (final m in members)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(m),
              child: Row(children: [
                KindBadge(kind: m.kind, compact: true),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(m.displayName,
                      style: UepText.sans(size: 12.5, color: ctx.uep.ink)),
                ),
              ]),
            ),
          if (members.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
              child: Text('這間房裡沒有其他人。',
                  style: UepText.serif(size: 12, color: ctx.uep.inkMute)),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    await runBoardAction(context, () async {
      final out = await actions.assignTask(widget.task.id,
          targetParticipantId: picked.id);
      if (out == null || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          out.assigned
              ? '已指派給 ${picked.displayName}'
              : out.alreadyPending
                  // 重按不是失敗，但要講清楚沒有生出第二筆
                  ? '已經在等 ${picked.displayName} 回覆了'
                  : '已送出請求，等 ${picked.displayName} 回覆',
        ),
      ));
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    // 兩條軸各自的身分來源：房軸帶 participant，板軸帶 session key
    final actions = widget.roomId != null
        ? ref.read(boardActionsProvider(widget.roomId!))
        : ref.read(boardActionsByIdProvider(widget.boardId));
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

    // 「請人接手」。**只在房軸出現**——板軸沒有房，也就沒有「這裡有誰」
    // 可問；板成員清單是另一個範圍的問題（同 supervisor 的處理）。
    //
    // ⚠️ 標籤一律是「請人接手」，**不看自己算不算管理員**。那個判準在
    // server（Hub 主持人／板 owner／房建立者），複製到 client 就是第二份
    // 會漂移的真相——按下去讓 server 回答發生了什麼，比先預測它可靠
    // （@開發Novia (Hub) 2026-09-04）。
    final canAssign = widget.roomId != null &&
        !const ['done', 'cancelled'].contains(widget.task.status);

    // 有沒有一筆**在等我回答**的。
    //
    // ⚠️ 判準是「指名我」，而 Hub 已經只回與我有關的了——所以這裡不必
    // （也不該）自己比對身分：那需要一個 UI 手上沒有的 actor_key，
    // 拼一個出來比對必然漂移。剩下要分的只是「我是被指名的那個」還是
    // 「我是提出的那個」，靠 `target_participant_id` 對本房身分即可。
    final myPid = widget.roomId == null
        ? null
        : ref.watch(identityProvider(widget.roomId!)).value?.participantId;
    final pending = widget.requests
        .where((r) => r.isPending && r.targetParticipantId == myPid)
        .firstOrNull;

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
        // 🔴 **有人在等我回答的話，那件事排在所有動作前面。**
        // 藏在資訊區裡只是「顯示」——被指名的人要有地方按，否則
        // 「需要對方同意」在畫面上就不成立
        if (pending != null) ...[
          if (leading.isNotEmpty) const SizedBox(width: 8),
          _DrawerAction(
            label: '接下',
            bordered: false,
            onTap: () => _respond(actions, pending, true),
          ),
          const SizedBox(width: 8),
          _DrawerAction(
            label: '婉拒',
            bordered: true,
            onTap: () => _respond(actions, pending, false),
          ),
        ] else if (canAssign) ...[
          if (leading.isNotEmpty) const SizedBox(width: 8),
          _DrawerAction(
            label: '請人接手',
            bordered: true,
            onTap: () => _assign(actions),
          ),
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
