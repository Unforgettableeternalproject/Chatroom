import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/rooms_api.dart';
import '../../core/errors/api_exception.dart';
import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/l10n.dart';
import '../../models/participant.dart';
import '../../state/app_providers.dart';
import '../../state/board_providers.dart';
import '../../state/messages_providers.dart';
import '../../state/rooms_providers.dart';
import '../../widgets/uep_button.dart';
import '../board/board_attach_dialog.dart';
import '../board/board_switch.dart';

// 房間選單（房間列表的「…」、聊天畫面標題列的「⋯」）與房間設定頁共用的
// 動作。兩個選單各自維護一份的話遲早會漂移。

void _snack(BuildContext context, String text) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

/// 離開房間。
///
/// 房主離開的規則在 Hub：有別的人類就自動把房主交給加入順位下一位；
/// 沒有的話 Hub 回 409 `leave_will_archive` 而且什麼都不動——這裡問過人
/// 之後帶 `archiveIfLast` 再送一次，離開與封存同時發生。
Future<void> leaveRoomFlow(
  BuildContext context,
  WidgetRef ref,
  String roomId, {
  required String participantId,
}) async {
  final l10n = AppLocalizations.of(context);
  final api = ref.read(roomsApiProvider);
  LeaveResult result;
  try {
    result = await api.leave(roomId, participantId: participantId);
  } on ApiException catch (e) {
    if (e.code != 'leave_will_archive') {
      if (context.mounted) _snack(context, e.message);
      return;
    }
    if (!context.mounted) return;
    final ok = await _confirmLeaveAndArchive(context);
    if (!ok || !context.mounted) return;
    try {
      result = await api.leave(
        roomId,
        participantId: participantId,
        archiveIfLast: true,
      );
    } on ApiException catch (e) {
      if (context.mounted) _snack(context, e.message);
      return;
    }
  }
  await ref.read(settingsRepoProvider).setParticipantId(roomId, null);
  ref.invalidate(identityProvider(roomId));
  ref.invalidate(roomDetailProvider(roomId));
  ref.invalidate(roomListProvider);
  if (!context.mounted) return;
  final who = result.handedOverTo;
  if (result.archived) {
    _snack(context, l10n.roomsLeftArchived);
  } else if (who != null && who.isNotEmpty) {
    _snack(context, l10n.roomsLeftHandedOver(who));
  }
  context.go('/rooms');
}

Future<bool> _confirmLeaveAndArchive(BuildContext context) async {
  final s = context.uep;
  final l10n = AppLocalizations.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        l10n.roomsLeaveArchiveTitle,
        style: UepText.pageTitle(color: s.inkTitle),
      ),
      content: Text(
        l10n.roomsLeaveArchiveBody,
        style: UepText.serif(size: 14.5, color: s.inkSoft, height: 1.6),
      ),
      actions: [
        UepButton(
          label: l10n.commonCancel,
          variant: UepButtonVariant.outline,
          small: true,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        UepButton(
          label: l10n.roomsLeaveArchiveAction,
          variant: UepButtonVariant.danger,
          small: true,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// 轉移房主：從房內 active 的人類成員挑一位，走既有的 `transfer_admin`。
///
/// agent 不列入——它會被閒置掃掉，交給它等於把管理權丟掉（Hub 端同樣擋）。
Future<void> transferOwnershipFlow(
  BuildContext context,
  WidgetRef ref,
  String roomId, {
  required String participantId,
}) async {
  final l10n = AppLocalizations.of(context);
  final List<Participant> candidates;
  try {
    final detail = await ref.read(roomDetailProvider(roomId).future);
    candidates = detail.participants
        .where(
          (p) =>
              p.isHuman && p.isActive && !p.ephemeral && p.id != participantId,
        )
        .toList();
  } on ApiException catch (e) {
    if (context.mounted) _snack(context, e.message);
    return;
  }
  if (!context.mounted) return;
  if (candidates.isEmpty) {
    _snack(context, l10n.roomsTransferNoCandidates);
    return;
  }
  final picked = await showDialog<Participant>(
    context: context,
    builder: (_) => _TransferDialog(candidates: candidates),
  );
  if (picked == null || !context.mounted) return;
  try {
    final who = await ref
        .read(roomsApiProvider)
        .transferAdmin(
          roomId,
          targetParticipantId: picked.id,
          participantId: participantId,
        );
    ref.invalidate(roomDetailProvider(roomId));
    ref.invalidate(roomListProvider);
    if (context.mounted) {
      _snack(
        context,
        l10n.chatTransferAdminDone(who.isEmpty ? picked.displayName : who),
      );
    }
  } on ApiException catch (e) {
    if (context.mounted) {
      _snack(
        context,
        e.code == 'heir_not_found' ? l10n.errorHeirNotFound : e.message,
      );
    }
  }
}

class _TransferDialog extends StatefulWidget {
  const _TransferDialog({required this.candidates});

  final List<Participant> candidates;

  @override
  State<_TransferDialog> createState() => _TransferDialogState();
}

class _TransferDialogState extends State<_TransferDialog> {
  Participant? _picked;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(
        l10n.roomsMenuTransfer,
        style: UepText.pageTitle(color: s.inkTitle),
      ),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.roomsTransferPickBody,
                style: UepText.serif(size: 14, color: s.inkSoft, height: 1.6),
              ),
              const SizedBox(height: 10),
              for (final p in widget.candidates)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    _picked?.id == p.id
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                    color: _picked?.id == p.id ? UepColors.gold : s.inkMute,
                  ),
                  title: Text(
                    p.displayName,
                    style: UepText.sans(size: 14, color: s.ink),
                  ),
                  onTap: () => setState(() => _picked = p),
                ),
            ],
          ),
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
          label: l10n.roomsTransferAction,
          small: true,
          onPressed: _picked == null
              ? null
              : () => Navigator.of(context).pop(_picked),
        ),
      ],
    );
  }
}

/// 更換任務板：**先解除、再挑一塊**（618da61b）。
///
/// 中途停下來是這條路的一部分，不是失敗——`attach` 那端有
/// `room_already_has_board` 擋著，順序不能反，所以「舊的解除了、新的還
/// 沒掛上」必然會經過。四種結果各講各的話（`boardSwitchStatusMessage`）。
Future<void> switchRoomBoard(
  BuildContext context,
  WidgetRef ref,
  String roomId,
) async {
  final board = ref.read(boardProvider(roomId)).value;
  final boardId = board?.boardId ?? '';
  if (boardId.isEmpty) return;
  if (!await confirmBoardSwitch(context, boardName: board?.name ?? '')) {
    return;
  }
  final api = ref.read(boardsApiProvider);
  final key = ref.read(appConfigProvider).deviceKey;

  // 第一步：解除。失敗時什麼都沒變——**要說原本那塊還在**，
  // 否則人會以為房間空了而去做一件不必做的事
  try {
    await api.detachRoom(boardId, roomId, sessionKey: key);
  } on ApiException catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          boardSwitchStatusMessage(
            detached: false,
            attached: false,
            error: e.message,
          ),
        ),
      ),
    );
    return;
  }
  ref.invalidate(boardProvider(roomId));
  ref.invalidate(boardLibraryProvider);
  if (!context.mounted) return;

  // 第二步：挑一塊新的。取消也是一種結果，而且是**要講出來**的那種：
  // 這間房現在沒有板
  final result = await showBoardAttachDialog(
    context,
    roomName: ref.read(roomDetailProvider(roomId)).value?.room.name ?? '',
  );
  if (result == null) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          boardSwitchStatusMessage(detached: true, attached: false),
        ),
        duration: const Duration(seconds: 6),
      ),
    );
    return;
  }
  try {
    final newId = result.isCreate
        ? await api.create(
            name: result.name!,
            sessionKey: key,
            originRoomId: roomId,
          )
        : result.boardId!;
    if (!result.isCreate || result.importMembers) {
      await api.attachRoom(
        newId,
        roomId,
        sessionKey: key,
        importMembers: result.importMembers,
      );
    }
    ref.invalidate(boardProvider(roomId));
    ref.invalidate(boardLibraryProvider);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(boardSwitchStatusMessage(detached: true, attached: true)),
      ),
    );
  } on ApiException catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          boardSwitchStatusMessage(
            detached: true,
            attached: false,
            error: e.message,
          ),
        ),
        duration: const Duration(seconds: 8),
      ),
    );
  }
}
