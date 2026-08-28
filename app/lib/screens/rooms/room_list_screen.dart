import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/api_exception.dart';
import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../core/util/relative_time.dart';
import '../../models/room.dart';
import '../../state/app_providers.dart';
import '../../state/messages_providers.dart';
import '../../state/rooms_providers.dart';
import '../../widgets/empty_error_states.dart';
import '../../widgets/kind_badge.dart';
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

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    ref.invalidate(roomListProvider);
    await ref.read(roomListProvider(_status).future);
  }

  Future<void> _createRoom() async {
    final created = await showDialog<Room>(
      context: context,
      builder: (context) => const _CreateRoomDialog(),
    );
    if (created != null && mounted) {
      ref.invalidate(roomListProvider);
      context.go('/rooms/${created.id}');
    }
  }

  Future<void> _toggleArchive(Room room) async {
    final api = ref.read(roomsApiProvider);
    try {
      if (room.isArchived) {
        await api.unarchive(room.id);
      } else {
        await api.archive(room.id);
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
    final roomsAsync = ref.watch(roomListProvider(_status));

    return Container(
      color: s.bgSoft,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(children: [
            Row(children: [
              MonoLabel('ROOMS', letterSpacing: 2.0),
              const Spacer(),
              IconButton(
                tooltip: '重新整理',
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
                    style: UepText.sans(size: 12.5, color: s.ink),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: '搜尋聊天室…',
                      hintStyle: UepText.serif(size: 12, color: s.inkMute),
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
              data: (allRooms) {
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
                          ? '沒有符合「${_search.text.trim()}」的聊天室'
                          : _status == 'active'
                              ? '目前沒有進行中的聊天室'
                              : '沒有已封存的聊天室',
                      subtitle: query.isEmpty && _status == 'active'
                          ? '按下方「建立房間」開一間，\n再用指派把 agent 請進來'
                          : null,
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
                label: '＋ 建立房間', small: true, expand: true,
                onPressed: _createRoom),
            const SizedBox(height: 10),
            MonoLabel('SWEEP 10 MIN · IDLE AUTO-REMOVE',
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
                size: 9,
                letterSpacing: 1.2,
                color: active ? UepColors.goldInkOn : s.inkMute,
                weight: active ? FontWeight.w500 : FontWeight.w400,
              ),
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
          segment('active', '進行中'),
          segment('archived', '已封存'),
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
  });

  final Room room;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onToggleArchive;
  final VoidCallback onAssign;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
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
                          size: 13.5,
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
                  style: UepText.mono(size: 9, color: s.inkMute)),
              _RoomMenu(
                  room: room,
                  onToggleArchive: onToggleArchive,
                  onAssign: onAssign),
            ]),
            if (room.topic.isNotEmpty) ...[
              const SizedBox(height: 5),
              Text(
                room.topic,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    UepText.serif(size: 11.5, color: s.inkSoft, height: 1.5),
              ),
            ],
            const SizedBox(height: 5),
            Row(children: [
              MonoLabel('${room.memberCount} MEMBERS',
                  size: 9, letterSpacing: 1.0),
              if (room.isArchived) ...[
                const SizedBox(width: 8),
                Icon(Icons.inventory_2_outlined, size: 11, color: s.inkMute),
                const SizedBox(width: 4),
                MonoLabel('已封存', size: 9, letterSpacing: 1.0),
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
  });

  final Room room;
  final VoidCallback onToggleArchive;
  final VoidCallback onAssign;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
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
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'archive',
          height: 36,
          child: Text(room.isArchived ? '解除封存' : '封存',
              style: UepText.sans(size: 12.5, color: s.ink)),
        ),
        if (!room.isArchived)
          PopupMenuItem(
            value: 'assign',
            height: 36,
            child: Text('指派 agent',
                style: UepText.sans(size: 12.5, color: s.ink)),
          ),
      ],
    );
  }
}

class _CreateRoomDialog extends ConsumerStatefulWidget {
  const _CreateRoomDialog();

  @override
  ConsumerState<_CreateRoomDialog> createState() => _CreateRoomDialogState();
}

class _CreateRoomDialogState extends ConsumerState<_CreateRoomDialog> {
  final _name = TextEditingController();
  final _topic = TextEditingController();
  bool _creating = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _topic.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '房間名稱不可為空');
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
          );
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
    return AlertDialog(
      title: Text('建立房間',
          style: UepText.display(size: 24, color: s.inkTitle)),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _field(context, 'NAME', _name, hint: 'chatroom-phase4'),
          const SizedBox(height: 14),
          _field(context, 'TOPIC（給 agent 的上下文）', _topic,
              hint: '一句話說明這個房間在做什麼…', lines: 3),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(_error!,
                  style: UepText.serif(
                      size: 12.5, color: UepColors.errorText, height: 1.5)),
            ),
          ],
        ]),
      ),
      actions: [
        UepButton(
          label: '取消',
          variant: UepButtonVariant.outline,
          small: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
        UepButton(
          label: '建立',
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
      MonoLabel(label, color: s.inkSoft, letterSpacing: 1.4),
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
              ? UepText.code(size: 12.5, color: s.ink, height: 1.4)
              : UepText.serif(size: 13, color: s.ink, height: 1.8),
          decoration: InputDecoration(
            isDense: true,
            border: InputBorder.none,
            hintText: hint,
            hintStyle: UepText.serif(size: 12.5, color: s.inkMute),
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
          ),
          onSubmitted: lines == 1 ? (_) => _create() : null,
        ),
      ),
    ]);
  }
}
