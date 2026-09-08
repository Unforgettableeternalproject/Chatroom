import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/rooms_api.dart';
import '../../core/errors/api_exception.dart';
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
import 'board_move_dialog.dart';

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
                _meta(context, ref, requests),
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
  Widget _meta(
      BuildContext context, WidgetRef ref, List<TaskRequest> requests) {
    final s = context.uep;
    final rows = <Widget>[];

    // 搬走的卡**留在原地顯示**（09/08 可見度規則，@開發Novia (除錯) 定），
    // 所以它需要一列說出去了哪裡——否則畫面上只剩一個「已搬走」徽章，
    // 那與「不見了」在讀者眼裡是同一件事。
    //
    // ⚠️ 去向空白是**存量會有的真實狀態**（這個功能之前搬卡不寫去向），
    // 不是壞掉。要講出來，但不能講成錯誤：那張卡還在，只是沒人說去哪。
    if (task.status == 'moved') {
      final snap = roomId != null
          ? ref.watch(boardProvider(roomId!)).value
          : ref.watch(boardByIdProvider(boardId)).value;
      final target = task.movedTo.isEmpty ? null : snap?.tasks[task.movedTo];
      rows.add(_MetaRow(
        label: '搬去了',
        // 查不到不等於不存在——目標可能在還沒載入的週期裡，或已經被刪掉。
        // 兩種都不該講成「沒有去向」，那是另一件事
        value: task.movedTo.isEmpty
            ? '沒說去哪'
            : (target?.title ?? '這份快取裡找不到的一張卡'),
        trailing: task.movedTo.isEmpty ? '去向留白' : '',
        trailingIsAlert: task.movedTo.isEmpty,
      ));
    }

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

  /// 取消這張卡的指派。
  ///
  /// 送空的 `target_participant_id`——照 supervisor 那條既有慣例，
  /// 空是「卸任」不是「沒填」。
  /// 搬到別處。**先問去哪，再搬**——[showBoardMoveDialog] 會在目標清單建一張
  /// 新卡並把這張指過去，所以這裡不必（也不可以）自己推一次 `moved`。
  Future<void> _move() async {
    final newId = await showBoardMoveDialog(
      context,
      task: widget.task,
      boardId: widget.boardId,
      roomId: widget.roomId,
    );
    if (newId == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已搬走。新的那張卡在你選的清單上，這張指向它。')),
    );
  }

  Future<void> _clearAssignee(BoardActions actions) async {
    await runBoardAction(context, () async {
      final out =
          await actions.assignTask(widget.task.id, targetParticipantId: '');
      if (out == null || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        // ⚠️ `cleared` 與 `assigned` 都是 false 時**不是同一件事**：
        // 只看 assigned 的話，取消成功會被講成「送出了一筆請求」
        content: Text(out.cleared ? '已取消指派' : '沒有東西可以取消'),
      ));
    });
  }

  /// 板軸專用：這張卡要指到哪一間掛接房。
  ///
  /// 掛一間就回那間，不問——問一個只有一個答案的問題，得到的只有一次多餘
  /// 的點擊。多間才開選單，每一筆都寫出房名，因為「指到哪一間」正是板軸
  /// 上唯一問不出來的那件事。
  Future<String?> _pickRoom(List<AttachedRoom> rooms) async {
    if (rooms.length == 1) return rooms.first.id;
    final picked = await showDialog<AttachedRoom>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('指到哪一間聊天室',
            style: UepText.display(size: 17, color: ctx.uep.inkTitle)),
        children: [
          for (final r in rooms)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(r),
              child: Row(children: [
                Expanded(
                  child: Text(r.name.isEmpty ? r.id : r.name,
                      style: UepText.sans(size: 12.5, color: ctx.uep.ink)),
                ),
                // 封存房也列出來，但要看得出來：那間房裡的人多半已經散了，
                // 指過去的卡不會有人接。藏掉的話，多房時使用者會覺得
                // 「少了一間」而去找它
                if (r.status == 'archived')
                  Text('已封存',
                      style: UepText.mono(size: 8.5, color: ctx.uep.inkMute)),
              ]),
            ),
        ],
      ),
    );
    return picked?.id;
  }

  /// 挑一個房內的人，把這張卡請給他。
  ///
  /// 送出後**要說出實際發生了什麼**：管理員按下去是「已指派」，其他人是
  /// 「已送出請求，等他回覆」。兩種都正常，但說錯的話提議者會以為事情
  /// 已經定了。
  Future<void> _assign(BoardActions actions, List<AttachedRoom> rooms) async {
    // 板軸沒有「這一間房」，所以指派的第一個問題是**指到哪一間**。
    // 掛一間就不問——多問一次沒有增加任何資訊，只是多一步
    final rid = widget.roomId ?? await _pickRoom(rooms);
    if (rid == null || !mounted) return;
    // 板軸這條要現拉：房軸進來時這份早就在快取裡，板軸是第一次碰這間房。
    //
    // ⚠️ 拉不到不是空清單。**「這間房裡沒有人」與「我讀不到這間房」不是
    // 同一件事**——前者按下去也沒用，後者要講出來，不然看的人會以為那間
    // 房是空的（板軸的人未必是那間房的成員）
    final RoomDetail detail;
    try {
      detail = await ref.read(roomDetailProvider(rid).future);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('讀不到那間房的成員：${e.message}')));
      return;
    }
    if (!mounted) return;
    final members = [
      for (final p in detail.participants)
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
          // 「搬到別處」不是單純推一次狀態：去向要在同一個動作裡定下來，
          // 否則留下的是一張「搬走了、不知道去哪」的卡。所以它走對話框，
          // 不走這條共用的 runBoardAction
          onTap: a.target == 'moved'
              ? _move
              : () => runBoardAction(
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

    // 「請人接手」。**兩條軸都出現**（決策 2026-09-07 裁「房選擇器」路）。
    //
    // 指派的目標是**房內身分**，而板可以掛好幾間房、也可以一間都沒掛——
    // 所以板軸上「指派給誰」沒有唯一答案。解法是**指派前先選房**：
    // 掛一間就直接用那間，掛多間先問，零房則按鈕停用並說出為什麼。
    //
    // ⚠️ 不動 server 契約（原卡另一條路是改用 actor_key）：那條與今天的
    // 憑證分離撞在同一個區域，兩邊同時動風險太高。
    //
    // ⚠️ 標籤一律是「請人接手」，**不看自己算不算管理員**。那個判準在
    // server（Hub 主持人／板 owner／房建立者），複製到 client 就是第二份
    // 會漂移的真相——按下去讓 server 回答發生了什麼，比先預測它可靠
    // （@開發Novia (Hub) 2026-09-04）。
    final settled = const ['done', 'cancelled'].contains(widget.task.status);
    // 板軸可以指到哪些房：**還掛著的才算**。`detached` 的房算進去的話，
    // 送出的指派會指向一個與這塊板已無關係的人，server 那端會拒——
    // UI 不該先製造那次失敗
    final rooms = widget.roomId != null
        ? const <AttachedRoom>[]
        : (ref.watch(boardByIdProvider(widget.boardId)).value?.liveRooms ??
                const <AttachedRoom>[])
            .toList();
    final canAssign = !settled;
    // 板軸零房：入口留著但按不動。**消失會被讀成「板軸沒有這個功能」**，
    // 而真相是「這塊板現在沒有人可以指」——後者有下一步（去掛一間房）
    final noRoomToAssign = widget.roomId == null && rooms.isEmpty;

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
        // ⚠️ **這排會換行，不會溢出。** 板軸長出「請人接手」之後，
        // 420px 的抽屜在 `todo` 那組動作下就超出 45px——而 Row 的溢位
        // 是一條黃黑斜紋，不是任何一種可用的畫面。多一顆按鈕就爆版的東西
        // 不能靠「目前剛好放得下」撐著
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final a in leading) button(a),
              // 🔴 **有人在等我回答的話，那件事排在所有動作前面。**
              // 藏在資訊區裡只是「顯示」——被指名的人要有地方按，否則
              // 「需要對方同意」在畫面上就不成立
              if (pending != null) ...[
                _DrawerAction(
                  label: '接下',
                  bordered: false,
                  onTap: () => _respond(actions, pending, true),
                ),
                _DrawerAction(
                  label: '婉拒',
                  bordered: true,
                  onTap: () => _respond(actions, pending, false),
                ),
              ] else if (canAssign) ...[
                _DrawerAction(
                  label: (widget.task.assigneeParticipantId ?? '').isEmpty
                      ? '請人接手'
                      : '改請別人',
                  bordered: true,
                  onTap: noRoomToAssign ? null : () => _assign(actions, rooms),
                ),
                // 停用要說出理由，而且理由要能導向下一步
                if (noRoomToAssign)
                  Text('掛到房間後才能指派',
                      style: UepText.mono(size: 8.5, color: s.inkMute)),
                // 取消指派。**只在真的有指派時出現**——沒有指派時給一顆
                // 取消鈕，是在問一個不存在的問題。
                //
                // ⚠️ 取消是管理動作，一般人按下去會 403 `not_assign_admin`。
                // 那顆按鈕仍然畫出來：**權限判準在 server**，UI 自己算一份
                // 會漂移，而漂移的方向如果是「藏起來」，管理員會找不到功能
                // 且沒有任何線索
                if ((widget.task.assigneeParticipantId ?? '').isNotEmpty)
                  _DrawerAction(
                    label: '取消指派',
                    bordered: true,
                    onTap: () => _clearAssignee(actions),
                  ),
              ],
            ],
          ),
        ),
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
    // 「已搬走」不是完成也不是取消——講錯的話，讀板的人會以為這件事
    // 在這裡做完了（done）或不做了（cancelled），而它其實在別的地方進行
    'moved': '已搬走',
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
      // 與取消同一種淡，但**不共用**：兩者的意思不同，哪天要分開畫時
      // 這一行已經在了
      'moved' => (s.inkMute, s.hairline, null),
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

  /// null ＝ 現在按不動。**按鈕仍然畫出來**：整顆藏掉的話，看的人得到的是
  /// 「這裡沒有這個功能」，而真相是「現在還不行」——後者有下一步可做，
  /// 前者沒有。停用時務必在旁邊講出理由。
  final VoidCallback? onTap;
  final bool bordered;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final disabled = onTap == null;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: bordered
            ? const EdgeInsets.symmetric(horizontal: 13, vertical: 7)
            : const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
        decoration: bordered
            ? BoxDecoration(
                border: Border.all(
                    color: disabled ? s.hairline : s.hairlineStrong))
            : null,
        child: Text(label,
            style: UepText.mono(
                size: 9,
                color: disabled
                    ? s.inkMute.withValues(alpha: .5)
                    : (accent ?? s.inkSoft),
                letterSpacing: 1.4)),
      ),
    );
  }
}
