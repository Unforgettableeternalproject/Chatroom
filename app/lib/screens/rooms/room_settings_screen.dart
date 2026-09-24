import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/rooms_api.dart';
import '../../core/errors/api_exception.dart';
import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/l10n.dart';
import '../../models/room.dart';
import '../../models/room_style.dart';
import '../../state/app_providers.dart';
import '../../state/board_providers.dart';
import '../../state/messages_providers.dart';
import '../../state/rooms_providers.dart';
import '../../widgets/empty_error_states.dart';
import '../../widgets/room_style_picker.dart';
import '../../widgets/settings_form.dart';
import '../../widgets/uep_button.dart';
import 'room_actions.dart';

/// 房間設定頁：名稱、主題、說話方式、可見度、任務板、封存。
///
/// 只從房內（聊天室頂欄的選單）進得來，而且**只給房間成員看**：非成員
/// 直接打開這個路由只會看到一句提示。主持人模式也一樣——主持人是旁觀者，
/// 不是房間成員（艾斯維爾 2026-09-23）。
///
/// 只有房主改得動，其他成員看到的是唯讀；封存房整頁唯讀（Hub 對封存房的
/// 寫入一律 409 `room_archived`）。永久刪除**不在這裡**——它只在「已封存」
/// 分頁的房間選單上。
class RoomSettingsScreen extends ConsumerStatefulWidget {
  const RoomSettingsScreen({super.key, required this.roomId});

  final String roomId;

  @override
  ConsumerState<RoomSettingsScreen> createState() => _RoomSettingsScreenState();
}

class _RoomSettingsScreenState extends ConsumerState<RoomSettingsScreen> {
  final _name = TextEditingController();
  final _topic = TextEditingController();
  final _instructions = TextEditingController();
  String _style = kRoomStyles.first.value;
  bool _private = false;

  /// 表單是從哪一份房間資料填的。資料更新（別人改了、自己存了）時重填，
  /// 但只在使用者還沒動過欄位時——打到一半的字不能被輪詢蓋掉。
  Room? _source;
  bool _dirty = false;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _topic.dispose();
    _instructions.dispose();
    super.dispose();
  }

  void _fill(Room room) {
    if (_source != null && _dirty) return;
    // Room 的 == 只比 id，這裡要的是「同一份資料」
    if (identical(_source, room)) return;
    _source = room;
    _name.text = room.name;
    _topic.text = room.topic;
    _style = room.style;
    _instructions.text = room.styleInstructions;
    _private = room.isPrivate;
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  String? get _participantId =>
      ref.read(settingsRepoProvider).participantId(widget.roomId);

  Future<void> _save(Room room) async {
    final l10n = AppLocalizations.of(context);
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.commonNameRequired)));
      return;
    }
    final instructions = _instructions.text.trim();
    if (_style == kRoomStyleCustom && instructions.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.roomsStyleCustomRequired)));
      return;
    }
    final api = ref.read(roomsApiProvider);
    final sessionKey = ref.read(appConfigProvider).deviceKey;
    final pid = _participantId;
    setState(() => _saving = true);
    try {
      // 只送改過的欄位：每一項變更都會在房裡留一則系統訊息，
      // 沒變的也送的話會留下「改成原本那樣」的噪音
      if (name != room.name) {
        await api.rename(
          widget.roomId,
          name: name,
          sessionKey: sessionKey,
          participantId: pid,
        );
      }
      if (_topic.text.trim() != room.topic) {
        await api.setTopic(
          widget.roomId,
          topic: _topic.text,
          sessionKey: sessionKey,
          participantId: pid,
        );
      }
      final wantInstructions = _style == kRoomStyleCustom ? instructions : '';
      if (_style != room.style || wantInstructions != room.styleInstructions) {
        await api.setStyle(
          widget.roomId,
          style: _style,
          instructions: wantInstructions,
          sessionKey: sessionKey,
          participantId: pid,
        );
      }
      if (_private != room.isPrivate) {
        await api.setVisibility(
          widget.roomId,
          visibility: _private ? 'private' : 'public',
          sessionKey: sessionKey,
          participantId: pid,
        );
      }
      _dirty = false;
      ref.invalidate(roomDetailProvider(widget.roomId));
      ref.invalidate(roomListProvider);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l10n.roomSettingsSaved)));
      }
    } on ApiException catch (e) {
      // 前面幾項可能已經生效，重讀一次讓畫面對上 Hub
      ref.invalidate(roomDetailProvider(widget.roomId));
      ref.invalidate(roomListProvider);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggleArchive(Room room) async {
    final l10n = AppLocalizations.of(context);
    final api = ref.read(roomsApiProvider);
    final sessionKey = ref.read(appConfigProvider).deviceKey;
    final pid = ref.read(settingsRepoProvider).participantId(widget.roomId);
    try {
      if (room.isArchived) {
        await api.unarchive(
          widget.roomId,
          sessionKey: sessionKey,
          participantId: pid,
        );
      } else {
        final ArchiveResult result = await api.archive(
          widget.roomId,
          sessionKey: sessionKey,
          participantId: pid,
        );
        // 非房主按下去是提議，不是封存
        if (!result.archived && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                result.alreadyPending
                    ? l10n.roomsArchiveAlreadyPending
                    : l10n.roomsArchiveRequestSent,
              ),
            ),
          );
        }
      }
      ref.invalidate(roomDetailProvider(widget.roomId));
      ref.invalidate(identityProvider(widget.roomId));
      ref.invalidate(roomListProvider);
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
    final detailAsync = ref.watch(roomDetailProvider(widget.roomId));
    final board = ref.watch(boardProvider(widget.roomId)).value;
    final hasBoard = (board?.boardId ?? '').isNotEmpty;

    return Scaffold(
      backgroundColor: s.bg,
      appBar: AppBar(
        backgroundColor: s.bgSoft,
        surfaceTintColor: Colors.transparent,
        shape: Border(bottom: BorderSide(color: s.line)),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, size: 18, color: s.inkSoft),
          onPressed: () => context.go('/rooms/${widget.roomId}'),
        ),
        title: Text(
          l10n.roomSettingsTitle,
          style: UepText.pageTitle(color: s.inkTitle),
        ),
      ),
      body: detailAsync.when(
        loading: () => const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: UepColors.gold,
            ),
          ),
        ),
        error: (e, _) => ErrorState(
          error: e,
          onRetry: () => ref.invalidate(roomDetailProvider(widget.roomId)),
        ),
        data: (detail) {
          final room = detail.room;
          // 成員＝我在這個房的身分還是 active。房主本人即使還沒 join 也算
          //（他能從房內選單進來，就代表 ChatScreen 已經替他 join 過了）
          final myId = _participantId;
          final isMember =
              detail.youAreAdmin ||
              (myId != null &&
                  detail.participants.any(
                    (p) =>
                        p.isActive &&
                        (p.id == myId || p.aliasIds.contains(myId)),
                  ));
          if (!isMember) {
            return EmptyState(title: l10n.roomSettingsMembersOnly);
          }
          _fill(room);
          final admin = detail.youAreAdmin;
          final editable = admin && !room.isArchived && !_saving;
          final note = room.isArchived
              ? l10n.roomSettingsArchivedReadOnly
              : admin
              ? null
              : l10n.roomSettingsOwnerOnly;
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: kPageMaxWidth),
              child: ListView(
                padding: const EdgeInsets.all(32),
                children: [
                  if (note != null) ...[
                    Text(note,
                        style: UepText.serif(
                            size: 12.5, color: UepColors.gold, height: 1.4)),
                    const SizedBox(height: 18),
                  ],
                  SettingsFieldLabel(l10n.roomsFieldName),
                  _field(controller: _name, enabled: editable),
                  const SizedBox(height: 18),
                  SettingsFieldLabel(l10n.roomsFieldTopic),
                  _field(
                    controller: _topic,
                    enabled: editable,
                    maxLines: 3,
                    hint: l10n.roomsFieldTopicHint,
                  ),
                  const SizedBox(height: 18),
                  SettingsFieldLabel(l10n.roomsStyleTitle),
                  RoomStylePicker(
                    value: _style,
                    enabled: editable,
                    onChanged: (v) => setState(() {
                      _style = v;
                      _dirty = true;
                    }),
                  ),
                  if (_style == kRoomStyleCustom) ...[
                    const SizedBox(height: 4),
                    _field(
                      controller: _instructions,
                      enabled: editable,
                      maxLines: 4,
                      hint: l10n.roomsStyleCustomHint,
                    ),
                  ],
                  const SizedBox(height: 22),
                  // 開關列：設定頁「深色主題」那一列的寫法
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(l10n.roomsPrivateTitle,
                                style: UepText.sans(
                                    size: 13.5, color: s.inkTitle)),
                            const SizedBox(height: 3),
                            Text(l10n.roomsPrivateSubtitle,
                                style: UepText.serif(
                                    size: 12, color: s.inkMute)),
                          ],
                        ),
                      ),
                      Switch(
                        value: _private,
                        activeThumbColor: UepColors.gold,
                        activeTrackColor: UepColors.gold.withValues(alpha: .28),
                        onChanged: editable
                            ? (v) => setState(() {
                                _private = v;
                                _dirty = true;
                              })
                            : null,
                      ),
                    ],
                  ),
                  if (admin && !room.isArchived) ...[
                    const SizedBox(height: 20),
                    Row(children: [
                      UepButton(
                        label: l10n.commonSave,
                        onPressed:
                            editable && _dirty ? () => _save(room) : null,
                      ),
                      const SizedBox(width: 14),
                      if (_dirty)
                        Flexible(
                          child: Text(l10n.settingsUnsavedChanges,
                              style: UepText.serif(
                                  size: 12.5,
                                  color: UepColors.gold,
                                  height: 1.4)),
                        ),
                    ]),
                  ],
                  if (admin && !room.isArchived && hasBoard) ...[
                    const SizedBox(height: 26),
                    Divider(color: s.line, height: 1),
                    const SizedBox(height: 22),
                    Text(l10n.roomSettingsBoard,
                        style: UepText.pageTitle(color: s.inkTitle)),
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: UepButton(
                        label: l10n.boardSwitchMenu,
                        variant: UepButtonVariant.outline,
                        small: true,
                        onPressed: () =>
                            switchRoomBoard(context, ref, widget.roomId),
                      ),
                    ),
                  ],
                  // 封存：房主直接封、成員送出請求（Hub 分辨）。解除封存
                  // 只給房主——其他人（包括主持人）按了只會拿到 403
                  if (!room.isArchived || admin) ...[
                    const SizedBox(height: 26),
                    Divider(color: s.line, height: 1),
                    const SizedBox(height: 22),
                    Text(l10n.roomSettingsArchiveSection,
                        style: UepText.pageTitle(color: s.inkTitle)),
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: UepButton(
                        label: room.isArchived
                            ? l10n.roomsMenuUnarchive
                            : l10n.roomsMenuArchive,
                        variant: UepButtonVariant.outline,
                        small: true,
                        onPressed: () => _toggleArchive(room),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required bool enabled,
    int maxLines = 1,
    String? hint,
  }) {
    final s = context.uep;
    return SettingsInputBox(
      child: TextField(
        controller: controller,
        enabled: enabled,
        maxLines: maxLines,
        minLines: 1,
        onChanged: (_) => _markDirty(),
        style: UepText.sans(size: 13, color: s.ink),
        decoration: settingsInputDecoration(hint, s),
      ),
    );
  }
}
