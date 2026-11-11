import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/api_exception.dart';
import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../core/util/relative_time.dart';
import '../../l10n/l10n.dart';
import '../../models/app_notification.dart';
import '../../state/notification_inbox_providers.dart';
import '../../widgets/empty_error_states.dart';
import '../../widgets/uep_button.dart';

/// 點一則通知要去哪：有任務板就到板（任務類帶上那張卡），否則到房間。
/// 都沒有就 null（只標已讀）。
String? notificationRoute(AppNotification n) => n.targetRoute;

/// 通知中心。收件匣裡所有會找上我的事：追蹤的東西、別人動了我的物件、
/// 主持人操作、派工結果……
class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  late final NotificationsPageOpen _pageOpen;

  @override
  void initState() {
    super.initState();
    _pageOpen = ref.read(notificationsPageOpenProvider.notifier);
    // 開著這一頁時新通知直接出現在清單，不必再跳 OS 通知
    Future.microtask(() {
      if (mounted) _pageOpen.set(true);
    });
  }

  @override
  void dispose() {
    // dispose 當下不能動 provider（可能正在 widget tree 重建），延後一拍
    Future.microtask(() => _pageOpen.set(false));
    super.dispose();
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _markAll() async {
    try {
      await ref.read(notificationInboxProvider.notifier).markAllRead();
    } on ApiException catch (e) {
      _say(e.message);
    }
  }

  /// 點一筆＝標已讀＋導過去。標不掉不擋導覽——他要看的是那個東西。
  Future<void> _open(AppNotification n) async {
    try {
      await ref.read(notificationInboxProvider.notifier).markRead(n);
    } on ApiException {
      // 沿用舊收件匣的取捨：導覽優先
    }
    final route = notificationRoute(n);
    if (!mounted || route == null) return;
    context.go(route);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final inbox = ref.watch(notificationInboxProvider);
    return Scaffold(
      backgroundColor: s.bg,
      appBar: AppBar(
        backgroundColor: s.bg,
        title: Text(l10n.notificationsTitle,
            style: UepText.sectionTitle(color: s.inkTitle)),
        actions: [
          if (inbox.unread > 0)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: UepButton(
                  label: l10n.notificationsMarkAllRead,
                  variant: UepButtonVariant.outline,
                  small: true,
                  onPressed: _markAll,
                ),
              ),
            ),
        ],
      ),
      body: _body(context, inbox),
    );
  }

  Widget _body(BuildContext context, InboxState inbox) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    if (inbox.items.isEmpty) {
      if (inbox.loading) {
        return const Center(child: CircularProgressIndicator());
      }
      if (inbox.error != null) {
        return ErrorState(
          error: inbox.error!,
          onRetry: () =>
              ref.read(notificationInboxProvider.notifier).refresh(),
        );
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            l10n.notificationsEmpty,
            textAlign: TextAlign.center,
            style: UepText.serif(size: 14, color: s.inkMute, height: 1.6),
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: inbox.items.length + (inbox.hasMore ? 1 : 0),
      itemBuilder: (_, i) {
        if (i == inbox.items.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: inbox.loadingMore
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : UepButton(
                      label: l10n.notificationsLoadMore,
                      variant: UepButtonVariant.outline,
                      small: true,
                      onPressed: () => ref
                          .read(notificationInboxProvider.notifier)
                          .loadMore(),
                    ),
            ),
          );
        }
        final n = inbox.items[i];
        return NotificationRow(notification: n, onOpen: () => _open(n));
      },
    );
  }
}

String actorKindLabel(AppLocalizations l10n, String kind) => switch (kind) {
      'human' => l10n.notificationsActorHuman,
      'host' => l10n.notificationsActorHost,
      'agent' => l10n.notificationsActorAgent,
      'system' => l10n.notificationsActorSystem,
      _ => '',
    };

/// 通知清單的一列。
class NotificationRow extends StatelessWidget {
  const NotificationRow({
    super.key,
    required this.notification,
    required this.onOpen,
  });

  final AppNotification notification;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final n = notification;
    final source = n.sourceLabel;
    final kindLabel = actorKindLabel(l10n, n.actorKind);
    final hasActor = n.actorName.isNotEmpty || kindLabel.isNotEmpty;
    return InkWell(
      onTap: onOpen,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 11, 16, 11),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: s.hairline),
            left: BorderSide(
              // 未讀的左邊一條金線；讀過的留著但不再喊
              color: n.unread ? UepColors.gold : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Text(
                n.summary,
                style: UepText.sans(
                  size: 14,
                  weight: n.unread ? FontWeight.w600 : FontWeight.w400,
                  color: n.unread ? s.inkTitle : s.inkMute,
                  height: 1.45,
                ),
              ),
            ),
          ]),
          const SizedBox(height: 3),
          Wrap(
            spacing: 8,
            runSpacing: 3,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (source.isNotEmpty)
                Text(source,
                    key: const Key('notificationSource'),
                    style: UepText.mono(
                        size: 10, letterSpacing: 1.0, color: s.inkMute)),
              if (hasActor)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  if (n.actorName.isNotEmpty)
                    Text(n.actorName,
                        key: const Key('notificationActor'),
                        style: UepText.mono(
                            size: 10, letterSpacing: 1.0, color: s.inkMute)),
                  if (n.actorName.isNotEmpty && kindLabel.isNotEmpty)
                    const SizedBox(width: 5),
                  if (kindLabel.isNotEmpty)
                    _Tag(
                      key: const Key('notificationActorKind'),
                      label: kindLabel,
                      emphasized: n.byHost,
                    ),
                ]),
              if (n.forHost)
                _Tag(
                    key: const Key('notificationForHost'),
                    label: l10n.notificationsForHost,
                    emphasized: true),
              Text(relativeTime(n.displayTime),
                  style: UepText.mono(
                      size: 10, letterSpacing: 1.0, color: s.inkMute)),
            ],
          ),
          if (n.reason.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(l10n.notificationsReason(n.reason),
                key: const Key('notificationReason'),
                style: UepText.serif(size: 13, color: s.inkSoft, height: 1.5)),
          ],
        ]),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({super.key, required this.label, this.emphasized = false});

  final String label;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final color = emphasized ? UepColors.gold : s.inkMute;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: emphasized ? UepColors.gold.withValues(alpha: .14) : null,
        border: Border.all(color: emphasized ? UepColors.gold : s.line),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label,
          style: UepText.mono(
              size: 9.5,
              letterSpacing: .8,
              weight: emphasized ? FontWeight.w600 : FontWeight.w400,
              color: color)),
    );
  }
}
