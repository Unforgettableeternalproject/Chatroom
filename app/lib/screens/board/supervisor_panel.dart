import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/api_exception.dart';
import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../core/util/relative_time.dart';
import '../../models/board.dart';
import '../../state/app_providers.dart';
import '../../models/participant.dart';
import '../../state/board_providers.dart';
import '../../state/messages_providers.dart';
import '../../state/rooms_providers.dart';
import '../../widgets/actor_name.dart';
import '../../widgets/kind_badge.dart';
import '../../widgets/uep_button.dart';

/// Supervisor 面板：誰在看著這塊板、他說了什麼、以及送出下一則判斷。
///
/// **刻意不做成收件匣。** 艾斯維爾裁決走 B 案（`board_directive` 事件），
/// 而 directive 是「對這塊板上的工作說的話」——它屬於板，不屬於某個人的
/// 信箱。放在板上，任何人打開板都看得到那些判斷是怎麼下的；放進收件匣，
/// 那段脈絡只有收件人自己有。
///
/// 誰能送：**owner 或 Supervisor 本人**。其餘的人看得到稽核串，看不到
/// 輸入框——把一個必然拿 403 的輸入框擺在那裡，跟不給一樣糟。
Future<void> showSupervisorPanel(
  BuildContext context, {
  required String boardId,
  String? roomId,
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _SupervisorPanel(boardId: boardId, roomId: roomId),
    );

class _SupervisorPanel extends ConsumerStatefulWidget {
  const _SupervisorPanel({required this.boardId, this.roomId});

  final String boardId;

  /// 從哪一間房打開的。板軸（Board Library）進來時是 null。
  ///
  /// **Supervisor 是 per-room 的**（艾斯維爾 2026-09-03），所以「指派誰來看
  /// 著」這件事只有站在某一間房裡才問得出來——板掛三間房就有三個位置，
  /// 板軸上沒有「這一間」可言。
  final String? roomId;

  @override
  ConsumerState<_SupervisorPanel> createState() => _SupervisorPanelState();
}

class _SupervisorPanelState extends ConsumerState<_SupervisorPanel> {
  final _message = TextEditingController();
  String? _toActorKey;
  bool _sending = false;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _send(BoardSnapshot snap) async {
    final text = _message.text.trim();
    // 收件者必**選**，但空字串是一個合法的選擇（＝對整塊板說）。
    //
    // ⚠️ 所以判準是 `== null`（還沒挑），不是 `.isEmpty`（挑了廣播）。
    // 用後者的話廣播那個選項會永遠送不出去，而按鈕就那樣灰在那裡，
    // 沒有任何東西說明為什麼
    if (text.isEmpty || _toActorKey == null) return;
    final broadcast = _toActorKey!.isEmpty;
    setState(() => _sending = true);
    try {
      final delivered = await ref.read(boardsApiProvider).sendDirective(
            widget.boardId,
            sessionKey: ref.read(appConfigProvider).deviceKey,
            text: text,
            targetActorKey: _toActorKey,
          );
      ref.invalidate(boardByIdProvider(widget.boardId));
      if (!mounted) return;
      _message.clear();
      // ⚠️ delivered=false **要講出來**。它表示這句話寫進稽核串了，但對方
      // 不在任何掛接房裡、沒有被喚醒。不講的話送出的人會以為對方已經知道
      // 了——而那是他接下來所有判斷的前提
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        // 廣播與單點的落空原因不同，講法也要不同：單點是「那個人不在」，
        // 廣播是「板上沒有任何人在掛接的房裡」。混用同一句話，
        // 送出的人會以為自己挑錯了人
        content: Text(switch ((broadcast, delivered)) {
          (true, true) => '已送出，板上在線的成員都被叫醒了。',
          (true, false) =>
            '已寫進稽核串，但板上沒有人在掛接的聊天室裡——現在沒有人知道這件事。',
          (false, true) => '已送出，對方已被叫醒。',
          (false, false) =>
            '已寫進稽核串，但對方不在任何掛接的聊天室裡——他還不知道這件事。',
        }),
        duration: Duration(seconds: delivered ? 2 : 6),
      ));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final snap = ref.watch(boardByIdProvider(widget.boardId)).value;
    final me = ref.watch(appConfigProvider).deviceKey;
    final isOwner = snap?.myRole == 'owner';
    // 🔴 問的是**掛接房**，不是頂層那個欄位。頂層 `snap.supervisor` 讀的是
    // server 的 `board.supervisor_*`，而那幾欄恆空（2026-09-05 查生產庫：
    // board 層級 0 筆）⇒ 這一行以前恆 false ⇒ **只有 owner 按得到「發指令」，
    // 而 supervisor 其實送得出去**（server 的權限第二問走掛接房）。
    // 少一顆按鈕不會報錯，所以沒有人發現。
    final isSupervisor = snap?.supervisesAnyRoom(me) ?? false;
    final canSend = isOwner || isSupervisor;

    return AlertDialog(
      backgroundColor: s.bgCard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: BorderSide(color: s.lineStrong),
      ),
      title: Text('Supervisor',
          style: UepText.display(size: 20, color: s.inkTitle)),
      // ⚠️ **一定要能捲。** AlertDialog 的 content 不會自己給捲軸：內容一長
      // 就直接被裁掉，而畫面上沒有任何東西表示下面還有東西
      // （艾斯維爾 2026-09-03：「也無法捲動，因此後面我還沒測」）。
      // 這個面板本來只有一段，今天加到四段之後就溢出了
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // **Supervisor 只有 per-room 這一種**（艾斯維爾 2026-09-03）。
          //
          // 板層級的那一份（頂層 `supervisor` ＋「指派／換人／卸任」）已經
          // 退場：在板軸上指派一個「這塊板的 supervisor」，等於在 per-room
          // 的契約上開一個後門——而那個後門看起來就跟正門一樣，沒有任何
          // 地方會說它是不同的東西。
          //
          // 2026-09-05 收尾：畫面、server 端點（`3a5979b`）、App 的模型欄位
          // 三層都拿掉了。板軸現在顯示的是**掛接房的唯讀彙整**。
          if (widget.roomId != null) ...[
            _RoomSupervisorSection(
              roomId: widget.roomId!,
              boardId: widget.boardId,
              attached: snap?.attachedRooms[widget.roomId!],
            ),
            const SizedBox(height: 14),
            const Divider(height: 1),
            const SizedBox(height: 12),
          ] else ...[
            // 板軸沒有「這一間房」，所以這裡是**唯讀的彙整**：掛了幾間房，
            // 每一間各是誰在看。指派入口只在房軸上（在板軸上指派等於在
            // per-room 的契約上開一個看起來跟正門一樣的後門）。
            _AttachedSupervisorsSection(sups: snap?.roomSupervisors ?? const []),
            const SizedBox(height: 14),
            const Divider(height: 1),
            const SizedBox(height: 12),
          ],
          _BoardOwnerSection(boardId: widget.boardId, snap: snap),
          const SizedBox(height: 14),
          const Divider(height: 1),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: MonoLabel('判斷與建議', color: s.inkSoft, letterSpacing: 1.4),
          ),
          const SizedBox(height: 8),
          SizedBox(height: 180, child: _trail(context, snap)),
          if (canSend) ...[
            const SizedBox(height: 12),
            _composer(context, snap),
          ],
        ]),
        ),
      ),
      actions: [
        UepButton(
          label: '關閉',
          variant: UepButtonVariant.outline,
          small: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  Widget _trail(BuildContext context, BoardSnapshot? snap) {
    final s = context.uep;
    final items = snap?.sortedDirectives ?? const <BoardDirective>[];
    if (items.isEmpty) {
      return Center(
        child: Text('還沒有人下過判斷。',
            style: UepText.serif(size: 12, color: s.inkMute)),
      );
    }
    return ListView.builder(
      itemCount: items.length + (snap!.directivesHasMore ? 1 : 0),
      itemBuilder: (_, i) {
        // 截斷要講出來。不講的話這串看起來就是全部，而它不是
        if (i == items.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: Text('還有更早的紀錄（只顯示最近 50 則）',
                  style: UepText.mono(size: 9, color: s.inkMute)),
            ),
          );
        }
        final d = items[i];
        final to = snap.memberOf(
            d.toActorKey.isEmpty ? null : d.toActorKey);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              // 送的人只有名字快照可用——Supervisor 不必是板成員，
              // 查 members[] 會查不到
              Text(d.fromName.isEmpty ? '（不明）' : d.fromName,
                  style: UepText.sans(size: 10.5, color: s.inkSoft)),
              const SizedBox(width: 6),
              Text(
                // 沒有指定收件者＝對整塊板講的。那與「對某個人講」是兩件事，
                // 混在一起的話讀的人分不出這句話是不是在對自己說
                to == null
                    ? '→ 全體'
                    : '→ ${to.displayName.isEmpty ? d.toActorKey : to.displayName}',
                style: UepText.mono(size: 9, color: s.inkMute),
              ),
              // 沒投影出去＝沒有人被叫醒。稽核串上要看得出這一則是
              // 「說了但對方不知道」，否則之後回頭查會以為他讀過了
              if (d.originRoomId.isEmpty && d.toActorKey.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text('未送達',
                    style: UepText.mono(size: 9, color: UepColors.errorText)),
              ],
            ]),
            const SizedBox(height: 3),
            Text(d.text,
                style: UepText.serif(size: 12.5, color: s.ink, height: 1.5)),
          ]),
        );
      },
    );
  }

  Widget _composer(BuildContext context, BoardSnapshot? snap) {
    final s = context.uep;
    final members = snap?.members.values.toList() ?? const <BoardActorRef>[];
    return Column(children: [
      if (members.isEmpty)
        Align(
          alignment: Alignment.centerLeft,
          child: Text('這塊板上還沒有成員，沒有人可以收。',
              style: UepText.serif(size: 12, color: s.inkMute)),
        )
      else
      Row(children: [
        Expanded(
          child: DropdownButtonFormField<String?>(
            initialValue: _toActorKey,
            isExpanded: true,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
            ),
            style: UepText.sans(size: 12, color: s.ink),
            onChanged: (v) => setState(() => _toActorKey = v),
            // 空字串＝**對整塊板說**（Hub `5fbd7db` 起支援；在那之前
            // `target_actor_key` 是 min_length=1，這個選項放上來等於把
            // 必然失敗的錯誤留到按下去才發生）。
            //
            // ⚠️ 收件人是板上的**成員**，不是掛接房裡的所有人——
            // 選單文字要照那個母體寫，寫成「房裡所有人」會讓 Supervisor
            // 以為某個只在房裡、不在板上的人也收得到
            items: [
              DropdownMenuItem(
                value: '',
                child: Text('所有板成員（${members.length}）',
                    overflow: TextOverflow.ellipsis,
                    style: UepText.sans(size: 12, color: s.inkSoft)),
              ),
              for (final m in members)
                DropdownMenuItem(
                  value: m.actorKey,
                  child: Text(m.displayName,
                      overflow: TextOverflow.ellipsis,
                      style: UepText.sans(size: 12, color: s.ink)),
                ),
            ],
          ),
        ),
      ]),
      const SizedBox(height: 8),
      TextField(
        controller: _message,
        maxLines: 3,
        style: UepText.sans(size: 12.5, color: s.ink),
        decoration: const InputDecoration(
          hintText: '這輪你看到什麼、建議怎麼走…',
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerRight,
        child: UepButton(
          label: _sending ? '送出中…' : '送出',
          small: true,
          // 同上：`== null` 是「還沒挑」，空字串是「挑了廣播」
          onPressed: (_sending || _toActorKey == null)
              ? null
              : () => _send(snap!),
        ),
      ),
    ]);
  }
}

/// 「這間房的 Supervisor」——per-room 那一半。
///
/// ## 為什麼它跟板上那個分開
///
/// 艾斯維爾 2026-09-03：「每個聊天室綁的 supervisor 可以不同，這是每個 room
/// 範疇的。」板掛三間房就有三個位置，板軸上問不出「這一間」是哪一間。
///
/// ## 為什麼從前指派不了
///
/// 兩層擋著，兩層都要拆：
///
/// 1. 板上那個指派入口看 `myRole == 'owner'`，而艾斯維爾在板上是 editor
///    ——按鈕根本不畫出來，看起來像功能沒做
/// 2. room-scoped 的端點從前只收 `session_key`，而那個值 Hub 刻意不外流
///    ⇒ UI 手上沒有任何送得出去的值，選單做不出來
///
/// 現在權限看**房間管理者**（`you_are_admin`），送出去的是 `participant_id`。
/// 板軸上的 supervisor 彙整：**唯讀，而且每一筆都說得出是哪一間房的**。
///
/// 只畫名字的話，板掛三間房時這份清單讀起來像「這塊板有三個 supervisor」，
/// 而真相是三間房各有一個——那正是 per-room 這件事要講清楚的地方。
///
/// 空的時候要明說「沒有人在看」而不是留白：**沒掛房、都沒指派、資料沒載到
/// 在畫面上長得一模一樣**，而前兩者是正常狀態，第三種是壞掉。
class _AttachedSupervisorsSection extends StatelessWidget {
  const _AttachedSupervisorsSection({required this.sups});

  final List<RoomSupervisor> sups;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      MonoLabel('掛接聊天室的 SUPERVISOR', color: s.inkSoft, letterSpacing: 1.4),
      const SizedBox(height: 8),
      if (sups.isEmpty)
        Text(
          '這塊板掛著的聊天室裡還沒有人在看。指派要從聊天室那一邊做——'
          'Supervisor 是綁在房間上的，不是綁在板上。',
          style: UepText.serif(size: 12, color: s.inkMute, height: 1.5),
        )
      else
        for (final sup in sups)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              KindBadge(kind: sup.actor.actorKind),
              const SizedBox(width: 8),
              Text(
                sup.actor.displayName,
                // 走了的人名字劃掉——三種狀態要分得出來，只有「有人／
                // 沒人」兩種畫法時，人走了會被畫成「還有人在看」
                style: UepText.sans(
                  size: 13,
                  color: sup.departed ? s.inkMute : s.ink,
                ).copyWith(
                  decoration:
                      sup.departed ? TextDecoration.lineThrough : null,
                ),
              ),
              if (sup.departed) ...[
                const SizedBox(width: 6),
                Text('已離開',
                    style: UepText.mono(
                        size: 8.5, letterSpacing: 1.0, color: UepColors.error)),
              ],
              const Spacer(),
              // 來源房。**這是這份清單唯一有意義的欄位**——少了它，多房時
              // 讀者分不出這幾個人是三間房各一個，還是同一間房有三個
              Flexible(
                child: Text(
                  sup.roomName.isEmpty ? sup.roomId : sup.roomName,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: UepText.mono(
                      size: 9, letterSpacing: 1.0, color: s.inkMute),
                ),
              ),
            ]),
          ),
    ]);
  }
}

class _RoomSupervisorSection extends ConsumerWidget {
  const _RoomSupervisorSection({
    required this.roomId,
    required this.boardId,
    required this.attached,
  });

  final String roomId;
  final String boardId;

  /// 這間房在板上的那一筆。板還沒載完時是 null。
  final AttachedRoom? attached;

  Future<void> _set(BuildContext context, WidgetRef ref, String? pid) async {
    try {
      final me = await ref.read(identityProvider(roomId).future);
      await ref.read(boardApiProvider).setSupervisor(
            roomId,
            participantId: me.participantId,
            targetParticipantId: pid,
          );
      ref.invalidate(boardByIdProvider(boardId));
      ref.invalidate(boardProvider(roomId));
    } on ApiException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  /// 挑一個**房內的人**。板外指定那條路留在板軸那一半——這裡問的是
  /// 「這間房裡誰來看著」，房外的人不在這個問題的範圍內。
  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final detail = ref.read(roomDetailProvider(roomId)).value;
    final members = [
      for (final p in detail?.participants ?? const <Participant>[])
        // 已離開的人不能當 supervisor：指派完當場就是 departed 狀態
        if (p.status == 'active') p,
    ];
    final picked = await showDialog<Participant>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('這間房的 Supervisor',
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
    if (picked != null && context.mounted) {
      await _set(context, ref, picked.id);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    // 權限看**房間管理者**，不是板上的角色
    // ⚠️ `you_are_admin` 在**回應頂層**，不在 `room` 物件裡（房間列表那支
    // 才塞進 room）。寫成 `.room.youAreAdmin` 會**永遠是 false**——指派
    // 按鈕就這樣消失了，而畫面上看起來只是「這間房沒有指派入口」
    // （艾斯維爾 2026-09-03 實機：「不知為何無法指定裁定Novia」）
    final canAssign =
        ref.watch(roomDetailProvider(roomId)).value?.youAreAdmin ?? false;
    final sup = attached?.supervisor;
    final departed = attached?.supervisorDeparted ?? false;
    // 我是不是這間房的 supervisor。人類的 actor_key 就是 deviceKey
    final iAmSupervisor = sup != null &&
        !departed &&
        sup.actorKey == ref.read(appConfigProvider).deviceKey;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Align(
        alignment: Alignment.centerLeft,
        child: MonoLabel('這間房的 SUPERVISOR', color: s.inkSoft,
            letterSpacing: 1.4),
      ),
      const SizedBox(height: 8),
      Row(children: [
        if (sup == null)
          Expanded(
            child: Text('這間房還沒有指派 Supervisor。',
                style: UepText.serif(size: 12.5, color: s.inkMute)),
          )
        else ...[
          KindBadge(kind: sup.actorKind),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ActorName(actor: sup, size: 13, showKind: false),
                // 三種狀態的第三種：**本來是誰在看，但他已經走了**。
                // 退場是標記不是清空，少了這一句，畫面就只能在「有人在看」
                // 與「沒有人」之間二選一，而兩個都不是真的
                if (departed)
                  Text('已經離開這間房了。指派的紀錄留著，但沒有人在看。',
                      style: UepText.serif(size: 11.5, color: UepColors.gold)),
              ],
            ),
          ),
        ],
        // 追蹤介面的入口。**supervisor 本人與房間管理者才看得到**——
        // 它是「監察」用的視角，對其他成員來說只是同一批卡換個排法
        if (canAssign || iAmSupervisor) ...[
          const SizedBox(width: 8),
          UepButton(
            label: '誰在做什麼',
            variant: UepButtonVariant.outline,
            small: true,
            onPressed: () {
              Navigator.of(context).pop();
              context.go('/rooms/$roomId/board/track');
            },
          ),
        ],
        if (canAssign) ...[
          const SizedBox(width: 8),
          UepButton(
            label: sup == null ? '指派' : '換人',
            variant: sup == null
                ? UepButtonVariant.gold
                : UepButtonVariant.outline,
            small: true,
            onPressed: () => _pick(context, ref),
          ),
          if (sup != null) ...[
            const SizedBox(width: 6),
            UepButton(
              label: '卸任',
              variant: UepButtonVariant.outline,
              small: true,
              onPressed: () => _set(context, ref, null),
            ),
          ],
        ],
      ]),
    ]);
  }
}

/// 「這塊板是誰的」——owner 的移交與接管。
///
/// ## 為什麼它在這個面板裡
///
/// 這個面板管的是**這塊板的人事**：誰在看著（Supervisor）、誰管得動
/// （owner）。分成兩個入口的話，「板鎖死了要找誰」會變成得先知道去哪找。
///
/// ## owner 為什麼要能交接
///
/// owner 是唯一不靠掛接關係的權限來源（`_board_role` 開頭就認它），也就是
/// 「這塊板還有沒有人管得動」的最後一道保險。不能交接的話，換一份工作、
/// 換一個 session，那塊板就永遠鎖在一個不再回來的人手上。
class _BoardOwnerSection extends ConsumerWidget {
  const _BoardOwnerSection({required this.boardId, required this.snap});

  final String boardId;
  final BoardSnapshot? snap;

  BoardActorRef? get _owner {
    for (final m in snap?.members.values ?? const <BoardActorRef>[]) {
      if (m.role == 'owner') return m;
    }
    return null;
  }

  Future<void> _transfer(BuildContext context, WidgetRef ref) async {
    final me = _owner?.actorKey;
    final members = [
      for (final m in snap?.members.values ?? const <BoardActorRef>[])
        if (m.actorKey != me) m,
    ];
    final picked = await showDialog<BoardActorRef>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('把這塊板交給誰',
            style: UepText.display(size: 17, color: ctx.uep.inkTitle)),
        children: [
          for (final m in members)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(m),
              child: Row(children: [
                KindBadge(kind: m.actorKind, compact: true),
                const SizedBox(width: 6),
                Expanded(child: ActorName(actor: m, size: 12.5)),
              ]),
            ),
          if (members.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
              child: Text('板上沒有別人可以接。先把人加進來。',
                  style: UepText.serif(size: 12, color: ctx.uep.inkMute)),
            ),
        ],
      ),
    );
    if (picked == null || !context.mounted) return;
    try {
      await ref.read(boardsApiProvider).transferOwner(
            boardId,
            sessionKey: ref.read(appConfigProvider).deviceKey,
            targetActorKey: picked.actorKey,
          );
      ref.invalidate(boardByIdProvider(boardId));
    } on ApiException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _claim(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(boardsApiProvider).claimOwner(
            boardId,
            sessionKey: ref.read(appConfigProvider).deviceKey,
          );
      ref.invalidate(boardByIdProvider(boardId));
      ref.invalidate(boardLibraryProvider);
    } on ApiException catch (e) {
      if (!context.mounted) return;
      // ⚠️ **owner 還活著時要講出他是誰、什麼時候還在。**
      // 「這塊板有 owner」這句話對「20 分鐘前還在」與「昨天之後沒再出現」
      // 是同一句，而那兩種情況該做的決定完全不同
      final who = e.detail['owner_display_name'] as String?;
      final seen = e.detail['owner_last_seen_at'] as String?;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.code == 'board_has_owner' && who != null
            ? '$who 還是這塊板的 owner'
                '${seen == null ? '' : '（最後出現：${relativeTime(seen)}）'}'
                '——接管只在無主的板上做得到'
            : e.message),
        duration: const Duration(seconds: 6),
      ));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final owner = _owner;
    final iAmOwner = snap?.myRole == 'owner';
    // 主持人模式開著才給接管——這與「持有主 token」是兩件事，
    // 開關現在是關的時候，Hub 那支端點本來就會拒絕
    final host = ref.watch(hostViewProvider);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Align(
        alignment: Alignment.centerLeft,
        child: MonoLabel('這塊板是誰的', color: s.inkSoft, letterSpacing: 1.4),
      ),
      const SizedBox(height: 8),
      Row(children: [
        if (owner == null)
          Expanded(
            child: Text('這塊板現在沒有人管得動。',
                style: UepText.serif(size: 12.5, color: s.inkMute)),
          )
        else ...[
          KindBadge(kind: owner.actorKind),
          const SizedBox(width: 8),
          Expanded(child: ActorName(actor: owner, size: 13, showKind: false)),
        ],
        if (iAmOwner) ...[
          const SizedBox(width: 8),
          UepButton(
            label: '移交',
            variant: UepButtonVariant.outline,
            small: true,
            onPressed: () => _transfer(context, ref),
          ),
        ],
        // 接管：主持人限定。**不是 owner 的時候才有意義**，
        // 自己已經是 owner 還畫一顆「接管」只會讓人以為它有別的作用
        if (host && !iAmOwner) ...[
          const SizedBox(width: 6),
          UepButton(
            label: '接管',
            variant: UepButtonVariant.outline,
            small: true,
            onPressed: () => _claim(context, ref),
          ),
        ],
      ]),
    ]);
  }
}
