import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../notifications/local_notifier.dart';
import '../notifications/notification_center.dart';
import 'app_providers.dart';
import 'rooms_providers.dart';

final notificationCenterProvider = Provider<NotificationCenter>((ref) {
  final service = ref.watch(realtimeServiceProvider);
  final center = NotificationCenter(service.subscribe, service.unsubscribe);
  ref.onDispose(center.dispose);
  return center;
});

/// 通知管線的啟動器：AppShell watch 一次即生效。
///
/// - 房間列表載入後，跟隨所有「已加入」（本機有 participant 快取）的房間
/// - 通知事件 → OS 通知（LocalNotifier）
/// - 房間活動 → 節流刷新房間列表（未讀紅點、排序）
final notificationBootstrapProvider = Provider<void>((ref) {
  final center = ref.watch(notificationCenterProvider);
  final settings = ref.read(settingsRepoProvider);

  center.mode = settings.notifyMode;

  void followJoined() {
    final rooms = ref.read(roomListProvider('active')).value;
    if (rooms == null) return;
    final joined = rooms
        .where((r) => settings.participantId(r.id) != null)
        .toList();
    for (final r in joined) {
      center.follow(
        r.id,
        roomName: r.name,
        myParticipantId: settings.participantId(r.id),
        myDisplayName: settings.displayName(r.id),
      );
    }
    center.retainOnly(joined.map((r) => r.id).toSet());
  }

  followJoined();
  ref.listen(roomListProvider('active'), (_, next) => followJoined());

  final notifSub = center.notifications.listen(LocalNotifier.instance.show);

  // 活動 → 刷新房間列表。節流：一批訊息只打一次 REST
  Timer? refreshDebounce;
  final activitySub = center.activity.listen((_) {
    refreshDebounce?.cancel();
    refreshDebounce = Timer(const Duration(seconds: 2), () {
      ref.invalidate(roomListProvider('active'));
    });
  });

  ref.onDispose(() {
    notifSub.cancel();
    activitySub.cancel();
    refreshDebounce?.cancel();
  });
});
