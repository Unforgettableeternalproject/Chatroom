import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/errors/api_exception.dart';
import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../models/assignment.dart';
import '../state/app_providers.dart';
import '../state/rooms_providers.dart';
import 'kind_badge.dart';
import 'uep_button.dart';

/// 別人邀我進房的待處理邀請。
///
/// 放在房間列表最上方而不是做成系統通知：邀請是**待辦**，錯過一次通知就
/// 再也看不到，但這裡只要沒處理就一直在。
class PendingInvitesBanner extends ConsumerWidget {
  const PendingInvitesBanner({super.key});

  Future<void> _decline(
      BuildContext context, WidgetRef ref, Assignment a) async {
    try {
      await ref.read(assignmentsApiProvider).resolve(
            a.id,
            accept: false,
            sessionKey: ref.read(appConfigProvider).deviceKey,
          );
    } on ApiException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      ref.invalidate(roomListProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final invites = ref.watch(myPendingInvitesProvider);
    if (invites.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: UepColors.gold.withValues(alpha: .07),
        border: Border.all(color: UepColors.gold.withValues(alpha: .45)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        MonoLabel('邀請你加入（${invites.length}）',
            size: 9, color: UepColors.gold, letterSpacing: 1.6),
        const SizedBox(height: 8),
        for (final a in invites) ...[
          Text(a.roomName ?? '（未命名聊天室）',
              style: UepText.sans(
                  size: 13, weight: FontWeight.w600, color: s.inkTitle)),
          if (a.note.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(a.note,
                style:
                    UepText.serif(size: 12, color: s.inkSoft, height: 1.6)),
          ],
          const SizedBox(height: 8),
          Row(children: [
            UepButton(
              label: '加入',
              small: true,
              // 進房時 Hub 會自動把對應指派標成 accepted，這裡不必先 resolve
              onPressed: () => context.go('/rooms/${a.roomId}'),
            ),
            const SizedBox(width: 10),
            UepButton(
              label: '婉拒',
              variant: UepButtonVariant.outline,
              small: true,
              onPressed: () => _decline(context, ref, a),
            ),
          ]),
          if (a != invites.last) ...[
            const SizedBox(height: 10),
            Divider(color: UepColors.gold.withValues(alpha: .2), height: 1),
            const SizedBox(height: 10),
          ],
        ],
      ]),
    );
  }
}
