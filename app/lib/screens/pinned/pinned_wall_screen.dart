import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/api_exception.dart';
import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../core/util/relative_time.dart';
import '../../models/message.dart';
import '../../state/app_providers.dart';
import '../../state/messages_providers.dart';
import '../../state/rooms_providers.dart';
import '../../widgets/empty_error_states.dart';
import '../../widgets/kind_badge.dart';
import '../../widgets/markdown_body.dart';

/// 釘選訊息（pinned_only 直接問 server；client 端再濾掉 deleted）。
final _pinnedProvider = FutureProvider.autoDispose
    .family<List<Message>, String>((ref, roomId) async {
  final page = await ref
      .read(messagesApiProvider)
      .read(roomId, pinnedOnly: true, limit: 200);
  return page.messages.where((m) => !m.deleted).toList();
});

class PinnedWallScreen extends ConsumerWidget {
  const PinnedWallScreen({super.key, required this.roomId});

  final String roomId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final pinnedAsync = ref.watch(_pinnedProvider(roomId));
    final detail = ref.watch(roomDetailProvider(roomId)).value;
    final archived = detail?.room.isArchived ?? false;
    final kindById = {
      for (final p in detail?.participants ?? const [])
        p.id: p.kind
    };

    // 房間 feed 有變更（他端釘選/取消）→ 重新抓
    ref.listen(messagesProvider(roomId), (prev, next) {
      ref.invalidate(_pinnedProvider(roomId));
    });

    return Scaffold(
      backgroundColor: s.bg,
      appBar: AppBar(
        backgroundColor: s.bgSoft,
        surfaceTintColor: Colors.transparent,
        shape: Border(bottom: BorderSide(color: s.line)),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, size: 18, color: s.inkSoft),
          onPressed: () => context.go('/rooms/$roomId'),
        ),
        title: Row(children: [
          const Text('❖',
              style: TextStyle(fontSize: 12, color: UepColors.gold)),
          const SizedBox(width: 10),
          Text('釘選訊息',
              style: UepText.display(size: 22, color: s.inkTitle)),
        ]),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 20),
            child: Center(
              child: MonoLabel(
                '${detail?.room.name ?? ''} · ${pinnedAsync.value?.length ?? 0}',
                size: 9,
              ),
            ),
          ),
        ],
      ),
      body: pinnedAsync.when(
        loading: () => const Center(
            child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: UepColors.gold))),
        error: (e, _) => ErrorState(
            error: e, onRetry: () => ref.invalidate(_pinnedProvider(roomId))),
        data: (pinned) => pinned.isEmpty
            ? const EmptyState(
                title: '這個房間還沒有釘選任何訊息',
                subtitle: '在訊息上按右鍵（或長按）即可釘選')
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: ListView.separated(
                    padding: const EdgeInsets.all(22),
                    itemCount: pinned.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 14),
                    itemBuilder: (context, i) {
                      final m = pinned[pinned.length - 1 - i];
                      return _PinnedCard(
                        roomId: roomId,
                        message: m,
                        kind: m.senderId != null
                            ? (kindById[m.senderId] ?? 'other')
                            : 'other',
                        archived: archived,
                      );
                    },
                  ),
                ),
              ),
      ),
    );
  }
}

class _PinnedCard extends ConsumerWidget {
  const _PinnedCard({
    required this.roomId,
    required this.message,
    required this.kind,
    required this.archived,
  });

  final String roomId;
  final Message message;
  final String kind;
  final bool archived;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final color = kindColor(kind, context: context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
      decoration: BoxDecoration(
        color: s.bgCard,
        border: Border(
          left: BorderSide(color: color, width: 2),
          top: BorderSide(color: s.line),
          right: BorderSide(color: s.line),
          bottom: BorderSide(color: s.line),
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(message.senderName ?? '（未知）',
              style: UepText.sans(
                  size: 12.5, weight: FontWeight.w600, color: s.inkTitle)),
          const SizedBox(width: 8),
          KindBadge(kind: kind, compact: true),
          const Spacer(),
          Text('#${message.seq} · ${clockTime(message.createdAt)}',
              style: UepText.mono(size: 9, color: s.inkMute)),
        ]),
        const SizedBox(height: 9),
        UepMarkdownBody(data: message.content, mentions: message.mentions),
        const SizedBox(height: 10),
        Row(children: [
          InkWell(
            onTap: () =>
                context.go('/rooms/$roomId?focusSeq=${message.seq}'),
            child: MonoLabel('跳回原文 →',
                size: 9, color: UepColors.gold, letterSpacing: 1.4),
          ),
          const SizedBox(width: 14),
          if (!archived)
            InkWell(
              onTap: () async {
                try {
                  final identity =
                      await ref.read(identityProvider(roomId).future);
                  await ref.read(messagesApiProvider).unpin(message.id,
                      participantId: identity.participantId);
                  ref.invalidate(_pinnedProvider(roomId));
                } on ApiException catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(e.message)));
                  }
                }
              },
              child: MonoLabel('取消釘選', size: 9, letterSpacing: 1.4),
            ),
        ]),
      ]),
    );
  }
}
