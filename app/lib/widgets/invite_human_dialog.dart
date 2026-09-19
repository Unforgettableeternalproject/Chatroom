import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors/api_exception.dart';
import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../core/util/relative_time.dart';
import '../l10n/l10n.dart';
import '../models/agent_session.dart';
import '../models/participant.dart';
import '../state/app_providers.dart';
import '../state/assignments_providers.dart';
import 'kind_badge.dart';
import 'uep_button.dart';

/// 邀請一位已連上 Hub 的人類進這個房間。
///
/// 走的是與 agent 指派完全相同的機制（assignment 表）——「把一個 session
/// 請進一個房間」本來就是同一件事，分成兩套只會變成兩份要維護的邏輯。
///
/// 候選只列**已連線**的人：沒連上 Hub 的人邀了也收不到，那種情況要先給他
/// 一份邀請碼（設定頁的「邀請成員」）。
class InviteHumanDialog extends ConsumerStatefulWidget {
  const InviteHumanDialog({
    super.key,
    required this.roomId,
    required this.members,
  });

  final String roomId;

  /// 房內現有成員；已經在房裡的人不再列出來。
  final List<Participant> members;

  @override
  ConsumerState<InviteHumanDialog> createState() => _InviteHumanDialogState();
}

class _InviteHumanDialogState extends ConsumerState<InviteHumanDialog> {
  final _note = TextEditingController();
  String? _selected;
  bool _sending = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _invite() async {
    final target = _selected;
    if (target == null) return;
    setState(() => _sending = true);
    try {
      await ref.read(assignmentsApiProvider).create(
            widget.roomId,
            targetSessionKey: target,
            note: _note.text.trim(),
          );
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final sessionsAsync = ref.watch(humanSessionsProvider);
    // 已經在房裡的人不必再邀；比對 session_key 而不是名字（名字會改）
    final present = {
      for (final p in widget.members)
        if (p.isActive && p.sessionKey != null) p.sessionKey!,
    };
    final myKey = ref.watch(appConfigProvider.select((c) => c.deviceKey));

    return AlertDialog(
      backgroundColor: s.bgCard,
      title: Text(AppLocalizations.of(context).inviteHumanTitle,
          style: UepText.pageTitle(color: s.inkTitle)),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              AppLocalizations.of(context).inviteHumanHint,
              style: UepText.serif(size: 13.5, color: s.inkMute, height: 1.6),
            ),
          ),
          const SizedBox(height: 14),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: sessionsAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(20),
                child: Center(
                    child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: UepColors.gold))),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: MonoLabel(AppLocalizations.of(context).inviteScanFailed,
                    size: 9, color: UepColors.errorText),
              ),
              data: (all) {
                final candidates = all
                    .where((x) =>
                        x.sessionKey != myKey &&
                        !present.contains(x.sessionKey))
                    .toList();
                if (candidates.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Text(
                      all.isEmpty
                          ? AppLocalizations.of(context).inviteNobodyToInvite
                          // 有人但都在房裡時說清楚，否則看起來像掃描壞了
                          : AppLocalizations.of(context).inviteAllAlreadyHere,
                      textAlign: TextAlign.center,
                      style: UepText.serif(size: 13.5, color: s.inkMute),
                    ),
                  );
                }
                return ListView(
                  shrinkWrap: true,
                  children: [
                    for (final c in candidates)
                      _HumanRow(
                        session: c,
                        selected: _selected == c.sessionKey,
                        onTap: () =>
                            setState(() => _selected = c.sessionKey),
                      ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 14),
          Container(
            decoration: BoxDecoration(
              color: s.bgSunken,
              border: Border.all(color: s.lineStrong),
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TextField(
              controller: _note,
              maxLines: 2,
              style: UepText.serif(size: 14, color: s.ink, height: 1.7),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: AppLocalizations.of(context).inviteNoteHint,
                hintStyle: UepText.serif(size: 13.5, color: s.inkMute),
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
        ]),
      ),
      actions: [
        UepButton(
          label: AppLocalizations.of(context).commonCancel,
          variant: UepButtonVariant.outline,
          small: true,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        UepButton(
          label: AppLocalizations.of(context).inviteSendAction,
          small: true,
          onPressed: (_selected == null || _sending) ? null : _invite,
        ),
      ],
    );
  }
}

class _HumanRow extends StatelessWidget {
  const _HumanRow({
    required this.session,
    required this.selected,
    required this.onTap,
  });

  final AgentSession session;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final active = session.isActive;
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? s.bgSunken : null,
          border: Border.all(
              color: selected ? UepColors.gold : s.line,
              width: selected ? 1.2 : 1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? UepColors.success : null,
              border: Border.all(
                  color: active ? UepColors.success : s.inkMute),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(session.displayTitle,
                    overflow: TextOverflow.ellipsis,
                    style: UepText.sans(
                        size: 14,
                        weight: FontWeight.w600,
                        color: s.inkTitle)),
                const SizedBox(height: 2),
                Text(
                  // 位址是共用 token 時唯一分得開「這是誰」的線索
                  session.lastIp ?? AppLocalizations.of(context).inviteUnknownSource,
                  style: UepText.mono(size: 10, color: s.inkMute),
                ),
              ],
            ),
          ),
          Text(relativeTime(session.lastSeenAt),
              style: UepText.mono(size: 10, color: s.inkMute)),
        ]),
      ),
    );
  }
}
