import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/api_exception.dart';
import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../core/util/relative_time.dart';
import '../../l10n/l10n.dart';
import '../../models/room.dart';
import '../../models/room_style.dart';
import '../../state/app_providers.dart';
import '../../state/messages_providers.dart';
import '../../models/board.dart';
import '../../state/board_providers.dart';
import '../../state/rooms_providers.dart';
import '../../state/runner_kit_presence.dart';
import '../../widgets/delete_room_confirm.dart';
import '../../widgets/pending_invites_banner.dart';
import '../../widgets/room_style_picker.dart';
import '../../widgets/empty_error_states.dart';
import '../../widgets/kind_badge.dart';
import '../../widgets/host_mode_toggle.dart';
import '../../widgets/uep_button.dart';

/// 房間列表（桌機左欄 / 手機整頁共用）。
class RoomListPane extends ConsumerStatefulWidget {
  const RoomListPane({super.key, this.selectedRoomId});

  final String? selectedRoomId;

  @override
  ConsumerState<RoomListPane> createState() => _RoomListPaneState();
}

class _RoomListPaneState extends ConsumerState<RoomListPane> {
  String _status = 'active';
  final _search = TextEditingController();
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    // 邀請沒有推播通道可搭：WS 是 per-room 訂閱的，而被邀請的人還不是成員、
    // 也還沒進房——他訂不到那個房。房間列表的其他變動（別人建房、封存）同理
    // 落在通道之外。所以這裡輪詢，週期照指派畫面那個 10s 的先例。
    //
    // ⚠️ 輪詢是**兜底**，不是主要機制：使用者自己按下的動作（加入、婉拒）
    // 一律在當下 invalidate，不等下一輪。剛按完鍵要等 10 秒，跟壞掉沒有分別。
    _poll = Timer.periodic(const Duration(seconds: 10), (_) {
      ref.invalidate(roomListProvider);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    ref.invalidate(roomListProvider);
    await ref.read(roomListProvider(_status).future);
  }

  Future<void> _createRoom() async {
    final created = await showCreateRoomDialog(context);
    if (created != null && mounted) {
      ref.invalidate(roomListProvider);
      context.go('/rooms/${created.id}');
    }
  }

  Future<void> _deleteRoom(Room room) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => DeleteRoomConfirm(name: room.name),
    );
    if (ok != true) return;
    try {
      final counts = await ref.read(roomsApiProvider).deleteRoom(
            room.id,
            sessionKey: ref.read(appConfigProvider).deviceKey,
            participantId: ref.read(settingsRepoProvider).participantId(room.id),
          );
      await ref.read(settingsRepoProvider).setParticipantId(room.id, null);
      ref.invalidate(roomListProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context).roomsDeleted(
            room.name,
            counts['message'] ?? 0,
            counts['attachment'] ?? 0,
          )),
        ));
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _toggleArchive(Room room) async {
    final api = ref.read(roomsApiProvider);
    // 封存／解封是房內管理動作，Hub 要求身分。房間列表上大多沒有 join 過
    // 的房，participantId 會是 null——那是正常的，建立者靠 deviceKey 過關
    final sessionKey = ref.read(appConfigProvider).deviceKey;
    final participantId = ref.read(settingsRepoProvider).participantId(room.id);
    try {
      if (room.isArchived) {
        await api.unarchive(room.id,
            sessionKey: sessionKey, participantId: participantId);
      } else {
        final result = await api.archive(room.id,
            sessionKey: sessionKey, participantId: participantId);
        // 非建立者按下去是提議。房間列表上沒有卡片可以顯示，這則
        // snackbar 是他唯一會看到的回饋
        if (!result.archived && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(result.alreadyPending
                ? AppLocalizations.of(context).roomsArchivePendingAlready
                : AppLocalizations.of(context).roomsArchiveRequested),
          ));
        }
      }
      ref.invalidate(roomListProvider);
      // 聊天畫面若開著同一房，房間狀態與身分都要跟著換
      ref.invalidate(roomDetailProvider(room.id));
      ref.invalidate(identityProvider(room.id));
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final roomsAsync = ref.watch(roomListProvider(_status));

    return Container(
      color: s.bgSoft,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(children: [
            Row(children: [
              MonoLabel(l10n.roomsPaneLabel, letterSpacing: 2.0),
              const Spacer(),
              IconButton(
                tooltip: l10n.commonRefresh,
                visualDensity: VisualDensity.compact,
                onPressed: _refresh,
                icon: Icon(Icons.refresh, size: 15, color: s.inkMute),
              ),
            ]),
            const SizedBox(height: 8),
            _StatusToggle(
              status: _status,
              onChanged: (v) => setState(() => _status = v),
            ),
            // 主持人模式。只有持主 token 的人看得到這一列——對其他人來說
            // 一個永遠按不動的開關比沒有這個開關更難懂
            if (roomsAsync.value?.youAreHost ?? false) ...[
              const SizedBox(height: 8),
              HostModeToggle(
                on: ref.watch(hostViewProvider),
                onLabel: l10n.roomsHostModeLabel,
              ),
            ],
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: s.bgSunken,
                border: Border.all(color: s.line),
                borderRadius: BorderRadius.circular(999),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                Icon(Icons.search, size: 14, color: s.inkMute),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    style: UepText.sans(size: 13.5, color: s.ink),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: l10n.roomsSearchHint,
                      hintStyle: UepText.serif(size: 13, color: s.inkMute),
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
                if (_search.text.isNotEmpty)
                  InkWell(
                    onTap: () => setState(_search.clear),
                    child: Icon(Icons.close, size: 13, color: s.inkMute),
                  ),
              ]),
            ),
          ]),
        ),
        const PendingInvitesBanner(),
        Expanded(
          child: RefreshIndicator(
            color: UepColors.gold,
            onRefresh: _refresh,
            child: roomsAsync.when(
              loading: () => const Center(
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: UepColors.gold))),
              error: (e, _) => ErrorState(error: e, onRetry: _refresh),
              data: (result) {
                final allRooms = result.rooms;
                final query = _search.text.trim().toLowerCase();
                final rooms = query.isEmpty
                    ? allRooms
                    : allRooms
                        .where((r) =>
                            r.name.toLowerCase().contains(query) ||
                            r.topic.toLowerCase().contains(query))
                        .toList();
                if (rooms.isEmpty) {
                  return ListView(children: [
                    const SizedBox(height: 120),
                    EmptyState(
                      title: query.isNotEmpty
                          ? l10n.roomsEmptySearch(_search.text.trim())
                          : _status == 'active'
                              ? l10n.roomsEmptyActive
                              : l10n.roomsEmptyArchived,
                      subtitle: null,
                    ),
                  ]);
                }
                return ListView.builder(
                  itemCount: rooms.length,
                  itemBuilder: (context, i) => _RoomTile(
                    room: rooms[i],
                    selected: rooms[i].id == widget.selectedRoomId,
                    onTap: () => context.go('/rooms/${rooms[i].id}'),
                    onToggleArchive: () => _toggleArchive(rooms[i]),
                    onDelete: () => _deleteRoom(rooms[i]),
                    onAssign: () =>
                        context.go('/rooms/${rooms[i].id}/assign'),
                  ),
                );
              },
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: s.line)),
          ),
          child: Column(children: [
            UepButton(
                label: l10n.roomsCreateButton, small: true, expand: true,
                onPressed: _createRoom),
            const SizedBox(height: 10),
            MonoLabel(l10n.roomsSweepNote,
                size: 8.5, letterSpacing: 1.2),
          ]),
        ),
      ]),
    );
  }
}

class _StatusToggle extends StatelessWidget {
  const _StatusToggle({required this.status, required this.onChanged});

  final String status;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    Widget segment(String value, String label) {
      final active = status == value;
      return Expanded(
        child: InkWell(
          onTap: () => onChanged(value),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 5),
            color: active ? UepColors.gold : Colors.transparent,
            alignment: Alignment.center,
            child: Text(
              label,
              style: UepText.mono(
                size: 10,
                letterSpacing: 1.2,
                color: active ? UepColors.goldInkOn : s.inkMute,
                weight: active ? FontWeight.w500 : FontWeight.w400),
            ),
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: s.line),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(children: [
          segment('active', l10n.commonActive),
          segment('archived', l10n.commonArchived),
        ]),
      ),
    );
  }
}

class _RoomTile extends ConsumerWidget {
  const _RoomTile({
    required this.room,
    required this.selected,
    required this.onTap,
    required this.onToggleArchive,
    required this.onAssign,
    required this.onDelete,
  });

  final Room room;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onToggleArchive;
  final VoidCallback onAssign;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final zone = zoneForRoomId(room.id);
    final palette = uepZonePalettes[zone]!;
    final brightness = Theme.of(context).brightness;
    final unread =
        ref.watch(settingsRepoProvider).lastReadSeq(room.id) < room.lastSeq &&
            !selected;

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
        decoration: BoxDecoration(
          color: selected ? palette.tint(brightness) : null,
          border: Border(
            left: BorderSide(
                color: selected ? palette.main : Colors.transparent, width: 2),
            bottom: BorderSide(color: s.line),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Row(children: [
                  Flexible(
                    child: Text(
                      room.name,
                      overflow: TextOverflow.ellipsis,
                      style: UepText.sans(
                          size: 14.5,
                          weight: FontWeight.w600,
                          // 封存房整體灰掉，與進行中的房間一眼區分
                          color: room.isArchived
                              ? s.inkMute
                              : selected
                                  ? s.inkTitle
                                  : s.ink),
                    ),
                  ),
                  if (unread) ...[
                    const SizedBox(width: 8),
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                          shape: BoxShape.circle, color: UepColors.gold),
                    ),
                  ],
                ]),
              ),
              Text(relativeTime(room.lastActivityAt ?? room.createdAt),
                  style: UepText.mono(size: 10, color: s.inkMute)),
              _RoomMenu(
                  room: room,
                  onToggleArchive: onToggleArchive,
                  onAssign: onAssign,
                  onDelete: onDelete,
                  hostMode: ref.watch(hostViewProvider)),
            ]),
            if (room.topic.isNotEmpty) ...[
              const SizedBox(height: 5),
              Text(
                room.topic,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    UepText.serif(size: 12.5, color: s.inkSoft, height: 1.5),
              ),
            ],
            const SizedBox(height: 5),
            Row(children: [
              MonoLabel(l10n.roomsMemberCount(room.memberCount),
                  size: 9, letterSpacing: 1.0),
              // 私人房：只有你有份才會出現在這份列表上，所以標記的用途是
              // 「這個房別人看不到」——發言前該知道的事
              if (room.isPrivate) ...[
                const SizedBox(width: 8),
                Icon(Icons.lock_outline,
                    size: 11,
                    color: room.isArchived ? s.inkMute : UepColors.gold),
                const SizedBox(width: 4),
                MonoLabel(l10n.roomsPrivateBadge,
                    size: 9,
                    letterSpacing: 1.0,
                    color: room.isArchived ? s.inkMute : UepColors.gold),
              ],
              // 工作房的徽章。分區與徽章擇一時選徽章：房間列表已經有
              // 「進行中／已封存」一個分段器，再切一層會讓搜尋結果散成兩段，
              // 而人是照名字找房間的
              if (room.isOps) ...[
                const SizedBox(width: 8),
                Icon(Icons.precision_manufacturing_outlined,
                    size: 11,
                    color: room.isArchived ? s.inkMute : UepColors.gold),
                const SizedBox(width: 4),
                MonoLabel(l10n.roomsOpsBadge,
                    size: 9,
                    letterSpacing: 1.0,
                    color: room.isArchived ? s.inkMute : UepColors.gold),
              ],
              if (room.isArchived) ...[
                const SizedBox(width: 8),
                Icon(Icons.inventory_2_outlined, size: 11, color: s.inkMute),
                const SizedBox(width: 4),
                MonoLabel(l10n.commonArchived, size: 9, letterSpacing: 1.0),
              ],
            ]),
          ],
        ),
      ),
    );
  }
}

class _RoomMenu extends StatelessWidget {
  const _RoomMenu({
    required this.room,
    required this.onToggleArchive,
    required this.onAssign,
    required this.onDelete,
    this.hostMode = false,
  });

  final Room room;
  final VoidCallback onToggleArchive;
  final VoidCallback onAssign;
  final VoidCallback onDelete;

  /// 主持人模式開著。Hub 對主持人放行封存／解封／刪除，UI 要跟著給——
  /// 不給的話那個模式只是「看得到」，而看得到卻動不了正是使用者回報
  /// 「刪除功能消失」的樣子。
  final bool hostMode;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_horiz, size: 14, color: s.inkMute),
      iconSize: 14,
      padding: EdgeInsets.zero,
      color: s.bgCard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: s.lineStrong),
      ),
      onSelected: (v) {
        switch (v) {
          case 'archive':
            onToggleArchive();
          case 'assign':
            onAssign();
          case 'delete':
            onDelete();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'archive',
          height: 36,
          child: Text(
              room.isArchived ? l10n.roomsMenuUnarchive : l10n.roomsMenuArchive,
              style: UepText.sans(size: 13.5, color: s.ink)),
        ),
        if (!room.isArchived)
          PopupMenuItem(
            value: 'assign',
            height: 36,
            child: Text(l10n.assignTitle,
                style: UepText.sans(size: 13.5, color: s.ink)),
          ),
        // 刪除也要在**列表上**給得到：封存房的操作場景就在這裡，沒有人會
        // 為了刪掉一個封存房而先點進去。
        //
        // 主持人模式開著時一律給：Hub 端對主持人放行刪除，而
        // `you_are_admin` 只答「這個房是不是你開的」——deviceKey 換過一次，
        // 舊房就全部答 false，creator 為 NULL 的舊房更是誰都刪不掉。
        // 那正是這個模式要解決的
        if (room.youAreAdmin || hostMode)
          PopupMenuItem(
            value: 'delete',
            height: 36,
            child: Text(l10n.roomsMenuDelete,
                style: UepText.sans(size: 13.5, color: UepColors.errorText)),
          ),
      ],
    );
  }
}

/// 開啟建房對話框。建好回傳那個房間，取消回 null。
///
/// 對話框本身是私有的：入口只有這一個，呼叫端不必知道它長什麼樣子。
@visibleForTesting
Future<Room?> showCreateRoomDialog(BuildContext context) =>
    showDialog<Room>(
      context: context,
      builder: (_) => const _CreateRoomDialog(),
    );

class _CreateRoomDialog extends ConsumerStatefulWidget {
  const _CreateRoomDialog();

  @override
  ConsumerState<_CreateRoomDialog> createState() => _CreateRoomDialogState();
}

class _CreateRoomDialogState extends ConsumerState<_CreateRoomDialog> {
  final _name = TextEditingController();
  final _topic = TextEditingController();
  final _styleInstructions = TextEditingController();
  bool _creating = false;
  bool _private = false;

  /// chat | ops。ops 是遠端派工的工作房（REMOTE-OPS-PLAN §4.1）。
  ///
  /// **建立時就要選**：Hub 沒有「把一間房改成工作房」的端點，房間類型是
  /// 建出來就定了的。選錯只能重開一間。
  String _kind = 'chat';
  String _style = kRoomStyles.first.value;
  String? _error;

  /// 建完之後要掛哪塊板。null ＝不掛。
  ///
  /// **預設不掛是刻意的**（`BOARD_DESIGN` §1.2：建房不自動建空板）。多數
  /// 房間是一次性的討論，替每一間都生一塊板，Board Library 很快就會變成
  /// 一整排沒有人打開過的空板——那時「哪塊板還活著」就看不出來了。
  String? _boardId;

  @override
  void dispose() {
    _name.dispose();
    _topic.dispose();
    _styleInstructions.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(
          () => _error = AppLocalizations.of(context).roomsErrorNameEmpty);
      return;
    }
    final instructions = _styleInstructions.text.trim();
    // Hub 也擋，但在這裡先講：送出去再被退回來，使用者得自己看懂 422
    if (_style == kRoomStyleCustom && instructions.isEmpty) {
      setState(() =>
          _error = AppLocalizations.of(context).roomsErrorCustomStyleEmpty);
      return;
    }
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final room = await ref.read(roomsApiProvider).create(
            name: name,
            topic: _topic.text.trim(),
            // 建立者即管理員
            sessionKey: ref.read(appConfigProvider).deviceKey,
            visibility: _private ? 'private' : 'public',
            kind: _kind,
            style: _style,
            styleInstructions: instructions,
          );
      // 掛板失敗**不能讓建房也跟著失敗**：房已經建好了，這時丟例外會讓
      // 使用者以為整件事沒成功，然後再建一間
      if (_boardId != null) {
        try {
          await ref.read(boardsApiProvider).attachRoom(
                _boardId!,
                room.id,
                sessionKey: ref.read(appConfigProvider).deviceKey,
              );
        } on ApiException catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(AppLocalizations.of(context)
                    .roomsBoardAttachFailed(e.message))));
          }
        }
      }
      if (mounted) Navigator.of(context).pop(room);
    } on ApiException catch (e) {
      setState(() {
        _creating = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.roomsCreateTitle,
          style: UepText.pageTitle(color: s.inkTitle)),
      // 內容要能捲：加上說話方式（四個選項＋自訂輸入框）之後，這個對話框
      // 在一般筆電螢幕上就已經高過視窗，而 AlertDialog 不會自己處理——
      // 它會讓按鈕直接壓在內容上，下面的欄位整個被擠出畫面
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
          _field(context, l10n.roomsFieldName, _name,
              hint: 'chatroom-phase4'),
          const SizedBox(height: 14),
          _field(context, l10n.roomsFieldTopic, _topic,
              hint: l10n.roomsFieldTopicHint, lines: 3),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(l10n.roomsFieldKind,
                style: UepText.fieldLabel(color: context.uep.inkSoft)),
          ),
          const SizedBox(height: 7),
          _KindPicker(
            value: _kind,
            enabled: !_creating,
            // 這台機器沒裝執行器就開不了工作房：工作房的用途是給遠端派工，
            // 而派工要有一台執行器接。**還在查的時候先當成沒有**——問題
            // 只在按下去那一刻才成立，而它很快就會回答
            opsEnabled: ref.watch(runnerKitPresentProvider).value ?? false,
            onChanged: (v) => setState(() => _kind = v),
          ),
          const SizedBox(height: 14),
          // 說話方式在**建立時**就選：房間開起來的第一件事往往就是叫 agent
          // 進來，等他講完第一輪長篇再改就已經晚了
          Align(
            alignment: Alignment.centerLeft,
            child: Text(l10n.roomsFieldStyle,
                style: UepText.fieldLabel(color: context.uep.inkSoft)),
          ),
          const SizedBox(height: 7),
          RoomStylePicker(
            value: _style,
            enabled: !_creating,
            onChanged: (v) => setState(() => _style = v),
          ),
          if (_style == kRoomStyleCustom) ...[
            const SizedBox(height: 10),
            _field(context, l10n.roomsFieldStyleInstructions,
                _styleInstructions,
                hint: l10n.roomsFieldStyleInstructionsHint, lines: 3),
          ],
          const SizedBox(height: 6),
          // 建立當下就能鎖：先開成公開再鎖起來，中間那段時間房間是所有人
          // 都看得到、都能自己走進來的
          CheckboxListTile(
            value: _private,
            onChanged: _creating
                ? null
                : (v) => setState(() => _private = v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(l10n.roomsPrivateTitle,
                style: UepText.sans(size: 13.5, color: s.ink)),
            subtitle: Text(l10n.roomsPrivateSubtitle,
                style: UepText.serif(
                    size: 12.5, color: s.inkMute, height: 1.4)),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(l10n.roomsFieldBoard,
                style: UepText.fieldLabel(color: context.uep.inkSoft)),
          ),
          const SizedBox(height: 7),
          _BoardPicker(
            value: _boardId,
            enabled: !_creating,
            onChanged: (v) => setState(() => _boardId = v),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(_error!,
                  style: UepText.serif(
                      size: 13.5, color: UepColors.errorText, height: 1.5)),
            ),
          ],
          ]),
        ),
      ),
      actions: [
        UepButton(
          label: l10n.commonCancel,
          variant: UepButtonVariant.outline,
          small: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
        UepButton(
          label: l10n.commonCreate,
          small: true,
          onPressed: _creating ? null : _create,
        ),
      ],
    );
  }

  Widget _field(
    BuildContext context,
    String label,
    TextEditingController controller, {
    String? hint,
    int lines = 1,
  }) {
    final s = context.uep;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: UepText.fieldLabel(color: s.inkSoft)),
      const SizedBox(height: 7),
      Container(
        decoration: BoxDecoration(
          color: s.bgSunken,
          border: Border.all(color: s.lineStrong),
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: TextField(
          controller: controller,
          maxLines: lines,
          autofocus: lines == 1,
          style: lines == 1
              ? UepText.code(size: 13, color: s.ink, height: 1.4)
              : UepText.serif(size: 14, color: s.ink, height: 1.8),
          decoration: InputDecoration(
            isDense: true,
            border: InputBorder.none,
            hintText: hint,
            hintStyle: UepText.serif(size: 13.5, color: s.inkMute),
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
          ),
          onSubmitted: lines == 1 ? (_) => _create() : null,
        ),
      ),
    ]);
  }
}

/// 房間類型的二選一。
///
/// 說明文字只講**實作真的做得到的事**：ops 房不自動封存（Hub 的 sweeper
/// 跳過它）、給遠端派工用（派工端點對非 ops 房一律 409）。不要寫成「更安全」
/// 或「有專屬權限」之類 server 沒做的承諾——畫面上的一句話會被當成事實。
class _KindPicker extends StatelessWidget {
  const _KindPicker({
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.opsEnabled = true,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final bool enabled;

  /// 這台機器裝了執行器沒有。沒裝就選不了工作房——開一間沒有人接得了單的
  /// 工作房，使用者要等到第一次派工才會發現，而那時房已經建好了。
  final bool opsEnabled;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    // 直排的單選列，與同一個對話框裡的「說話方式」一致：橫排兩欄那版用了
    // Row + CrossAxisAlignment.stretch，而這裡的父層是 SingleChildScrollView
    // ——垂直方向沒有上界，stretch 要求的是一個有界的高度，整個對話框會被
    // 撐開、後面的欄位被擠出畫面
    Widget option(String kind, String label, String summary,
        {bool available = true}) {
      final active = value == kind;
      final usable = enabled && available;
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: InkWell(
          onTap: usable ? () => onChanged(kind) : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
            decoration: BoxDecoration(
              color: active ? s.bgSunken : Colors.transparent,
              border: Border.all(color: active ? s.lineStrong : s.line),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    active
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 15,
                    color: active ? s.ink : s.inkMute,
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: UepText.sans(
                              size: 13.5,
                              color: usable ? s.ink : s.inkMute)),
                      const SizedBox(height: 2),
                      Text(summary,
                          style: UepText.serif(
                              size: 12.5, color: s.inkMute, height: 1.4)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Column(children: [
      option('chat', l10n.roomsKindChat, l10n.roomsKindChatSummary),
      option('ops', l10n.roomsKindOps, l10n.roomsKindOpsSummary,
          available: opsEnabled),
      // 只講擋住的理由，不解釋原理、也不在這裡教怎麼裝——那是 runner-kit
      // 的 README 的事
      if (!opsEnabled)
        Padding(
          padding: const EdgeInsets.only(left: 24, bottom: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(l10n.roomsKindOpsUnavailable,
                style: UepText.serif(
                    size: 12.5, color: s.inkMute, height: 1.4)),
          ),
        ),
    ]);
  }
}

/// 建房時選一塊既有的板來掛。
///
/// **只列既有的，不提供「順便建一塊」**——建板要取名字，而房間名字與板的
/// 名字是兩件事（板活得比房久，它的名字要撐得住之後的每一間房）。要建新板
/// 就進房之後用 app bar 那個入口，那裡有完整的建立流程。
class _BoardPicker extends ConsumerWidget {
  const _BoardPicker({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String? value;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final async = ref.watch(boardLibraryProvider('active'));
    // 端點還沒上線、或一塊板都沒有時**整個不顯示**。一個永遠只有「不掛」
    // 一個選項的下拉選單，只會讓人以為自己漏看了什麼
    final boards =
        async.value?.boards.where((b) => b.canEdit).toList() ??
            const <BoardSummary>[];
    if (boards.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          async.isLoading ? l10n.roomsBoardLoading : l10n.roomsBoardNone,
          style: UepText.serif(size: 12.5, color: s.inkMute),
        ),
      );
    }
    return DropdownButtonFormField<String?>(
      initialValue: value,
      isExpanded: true,
      decoration: const InputDecoration(
        isDense: true,
        border: OutlineInputBorder(),
      ),
      style: UepText.sans(size: 13.5, color: s.ink),
      onChanged: enabled ? onChanged : null,
      items: [
        DropdownMenuItem(
          value: null,
          child: Text(l10n.roomsBoardNoAttach,
              style: UepText.sans(size: 13.5, color: s.inkMute)),
        ),
        for (final b in boards)
          DropdownMenuItem(
            value: b.id,
            child: Text(
              l10n.roomsBoardOption(b.name, b.attachedRoomCount),
              overflow: TextOverflow.ellipsis,
              style: UepText.sans(size: 13.5, color: s.ink),
            ),
          ),
      ],
    );
  }
}
