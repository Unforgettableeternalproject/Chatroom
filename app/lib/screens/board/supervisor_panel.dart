import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/api_exception.dart';
import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../models/board.dart';
import '../../state/app_providers.dart';
import '../../state/board_providers.dart';
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
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _SupervisorPanel(boardId: boardId),
    );

class _SupervisorPanel extends ConsumerStatefulWidget {
  const _SupervisorPanel({required this.boardId});

  final String boardId;

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
    // 收件者必填——Hub 不接受空 target，而那個 422 的訊息只會說
    // 「至少要一個字元」，讀的人不會知道問題是「你沒挑人」
    if (text.isEmpty || (_toActorKey ?? '').isEmpty) return;
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
        content: Text(delivered
            ? '已送出，對方已被叫醒。'
            : '已寫進稽核串，但對方不在任何掛接的聊天室裡——他還不知道這件事。'),
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

  Future<void> _setSupervisor(
    String? actorKey, {
    String displayName = '',
    String actorKind = '',
  }) async {
    try {
      await ref.read(boardsApiProvider).setSupervisor(
            widget.boardId,
            sessionKey: ref.read(appConfigProvider).deviceKey,
            actorKey: actorKey,
            displayName: displayName,
            actorKind: actorKind,
          );
      ref.invalidate(boardByIdProvider(widget.boardId));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final snap = ref.watch(boardByIdProvider(widget.boardId)).value;
    final me = ref.watch(appConfigProvider).deviceKey;
    final isOwner = snap?.myRole == 'owner';
    final isSupervisor = snap?.supervisor?.actorKey == me;
    final canSend = isOwner || isSupervisor;

    return AlertDialog(
      backgroundColor: s.bgCard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: BorderSide(color: s.lineStrong),
      ),
      title: Text('Supervisor',
          style: UepText.display(size: 20, color: s.inkTitle)),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _current(context, snap, isOwner),
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

  /// 現任 Supervisor。空著時只有 owner 看得到「指派」——其他人看到的是
  /// 一句事實陳述，而不是一顆按不動的按鈕。
  Widget _current(BuildContext context, BoardSnapshot? snap, bool isOwner) {
    final s = context.uep;
    final sup = snap?.supervisor;
    if (sup == null) {
      return Row(children: [
        Expanded(
          child: Text('目前沒有人在看著這塊板。',
              style: UepText.serif(size: 12.5, color: s.inkMute)),
        ),
        if (isOwner)
          UepButton(
            label: '指派',
            small: true,
            onPressed: () => _pick(context, snap),
          ),
      ]);
    }
    return Row(children: [
      KindBadge(kind: sup.actorKind),
      const SizedBox(width: 8),
      Expanded(child: ActorName(actor: sup, size: 13, showKind: false)),
      if (isOwner) ...[
        UepButton(
          label: '換人',
          variant: UepButtonVariant.outline,
          small: true,
          onPressed: () => _pick(context, snap),
        ),
        const SizedBox(width: 6),
        UepButton(
          label: '卸任',
          variant: UepButtonVariant.outline,
          small: true,
          onPressed: () => _setSupervisor(null),
        ),
      ],
    ]);
  }

  /// 從板成員裡挑一個。
  ///
  /// ⚠️ **Supervisor 不必是板成員**（Hub 明講），所以這份清單是方便，不是
  /// 限制——真要指派一個外面的 agent，走的是 actor_key，那需要一個能貼
  /// key 的入口。這裡先做常見的那半，缺的那半不假裝它不存在。
  Future<void> _pick(BuildContext context, BoardSnapshot? snap) async {
    final members = snap?.members.values.toList() ?? const <BoardActorRef>[];
    final picked = await showDialog<BoardActorRef>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('指派 Supervisor',
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
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Text('這塊板上還沒有成員。',
                  style: UepText.serif(size: 12, color: ctx.uep.inkMute)),
            ),
        ],
      ),
    );
    if (picked != null) {
      await _setSupervisor(picked.actorKey,
          displayName: picked.displayName, actorKind: picked.actorKind);
    }
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
            // ⚠️ **沒有「對整塊板說」這個選項**。delta 那側有「空 =
            // 對全體」的語意，但送出這側 Hub 要求 target 非空
            // （min_length=1，空字串與不帶都是 422）。廣播還沒有實作，
            // 放一個必然失敗的選項在這裡，等於把錯誤留到按下去才發生。
            items: [
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
          onPressed: (_sending || (_toActorKey ?? '').isEmpty)
              ? null
              : () => _send(snap!),
        ),
      ),
    ]);
  }
}
