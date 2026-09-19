import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/rooms_api.dart';
import '../core/errors/api_exception.dart';
import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../l10n/l10n.dart';
import '../state/app_providers.dart';
import '../state/rooms_providers.dart';
import 'kind_badge.dart';
import 'uep_button.dart';

/// 掛在聊天畫面上方的封存請求。
///
/// 與 [PendingInvitesBanner] 同一個理由做成常駐橫幅而不是通知：這是**待辦**，
/// 通知錯過一次就沒了，橫幅只要沒處理就一直在。
///
/// **所有成員都看得到**，但看到的東西不一樣：
/// - 建立者 → 核准／婉拒
/// - 提議者 → 收回
/// - 其他人 → 只有一行字（知道有人提了，才不會重複提）
class ArchiveRequestBanner extends ConsumerStatefulWidget {
  const ArchiveRequestBanner({
    super.key,
    required this.roomId,
    required this.request,
    required this.youAreAdmin,
  });

  final String roomId;
  final ArchiveRequest request;
  final bool youAreAdmin;

  @override
  ConsumerState<ArchiveRequestBanner> createState() =>
      _ArchiveRequestBannerState();
}

class _ArchiveRequestBannerState extends ConsumerState<ArchiveRequestBanner> {
  bool _busy = false;

  /// 三顆鈕共用：擋掉重複點擊、統一錯誤處理、統一收尾。
  /// 核准會讓整個房唯讀——連點兩下的第二下打到的是一個已經 resolved 的
  /// 請求（409），那個錯誤對使用者毫無意義。
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      ref.invalidate(roomDetailProvider(widget.roomId));
      ref.invalidate(roomListProvider);
    }
  }

  Future<void> _resolve(bool approve) => _run(() async {
        await ref.read(roomsApiProvider).resolveArchiveRequest(
              widget.request.id,
              approve: approve,
              sessionKey: ref.read(appConfigProvider).deviceKey,
              participantId:
                  ref.read(settingsRepoProvider).participantId(widget.roomId),
            );
      });

  Future<void> _cancel() => _run(() async {
        final pid = ref.read(settingsRepoProvider).participantId(widget.roomId);
        if (pid == null) return;
        await ref
            .read(roomsApiProvider)
            .cancelArchiveRequest(widget.request.id, participantId: pid);
      });

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final myId = ref.watch(settingsRepoProvider).participantId(widget.roomId);
    final isMine = myId != null && myId == widget.request.requesterId;
    final who = widget.request.requesterName.isEmpty
        ? l10n.commonSomeone
        : widget.request.requesterName;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: UepColors.gold.withValues(alpha: .07),
        border: Border.all(color: UepColors.gold.withValues(alpha: .45)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        MonoLabel(l10n.roomsArchiveRequestLabel,
            size: 9, color: UepColors.gold, letterSpacing: 1.6),
        const SizedBox(height: 8),
        Text(
          '${isMine ? l10n.roomsArchiveRequestMine : l10n.roomsArchiveRequestBy(who)}'
          '${l10n.roomsArchiveRequestNote}',
          style: UepText.sans(
              size: 14, weight: FontWeight.w600, color: s.inkTitle),
        ),
        if (widget.request.reason.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(widget.request.reason,
              style: UepText.serif(size: 13, color: s.inkSoft, height: 1.6)),
        ],
        const SizedBox(height: 8),
        if (widget.youAreAdmin)
          Row(children: [
            UepButton(
              label: l10n.roomsArchiveAction,
              small: true,
              onPressed: _busy ? null : () => _resolve(true),
            ),
            const SizedBox(width: 10),
            UepButton(
              label: l10n.commonDecline,
              variant: UepButtonVariant.outline,
              small: true,
              onPressed: _busy ? null : () => _resolve(false),
            ),
          ])
        else if (isMine)
          UepButton(
            label: l10n.roomsArchiveWithdraw,
            variant: UepButtonVariant.outline,
            small: true,
            onPressed: _busy ? null : _cancel,
          )
        else
          // 既不是建立者也不是提議者：只告訴他狀態。沒有這一行的話，
          // 他會以為是自己該處理的事
          Text(l10n.roomsArchiveWaitingCreator,
              style: UepText.serif(size: 13, color: s.inkMute, height: 1.6)),
      ]),
    );
  }
}
