import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../notifications/codex_dispatcher.dart';
import '../notifications/local_notifier.dart';
import '../notifications/notification_center.dart';
import 'app_providers.dart';
import 'rooms_providers.dart';

/// 桌面平台才有 codex CLI 可呼叫。
bool get _canDispatchCodex =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

final codexDispatcherProvider = Provider<CodexDispatcher>((ref) {
  final roomsApi = ref.watch(roomsApiProvider);
  final assignmentsApi = ref.watch(assignmentsApiProvider);
  final settings = ref.read(settingsRepoProvider);
  final dispatcher = CodexDispatcher(
    (roomId) async {
      final detail = await roomsApi.detail(roomId);
      final kinds = <String, String>{};
      final codexNames = <String>{};
      final allNames = <String>{};
      for (final p in detail.participants) {
        kinds[p.id] = p.kind;
        for (final alias in p.aliasIds) {
          kinds[alias] = p.kind; // 改名重進的舊 id 也對得上
        }
        allNames.add(p.displayName);
        final prev = p.previousName;
        if (prev != null) allNames.add(prev);
        if (p.kind == 'codex' && p.status == 'active') {
          codexNames.add(p.displayName);
        }
      }
      return RoomMembers(
        kinds: kinds,
        codexNames: codexNames,
        allNames: allNames,
      );
    },
    fetchSessions: assignmentsApi.scanSessions,
    fetchAssignments: (threadId) {
      final tail = threadId.length > 8
          ? threadId.substring(threadId.length - 8)
          : threadId;
      return assignmentsApi.listForSession(
        threadId,
        kind: 'codex',
        label: 'Codex-$tail',
      );
    },
  );
  dispatcher
    ..enabled = _canDispatchCodex && settings.codexDispatchEnabled
    ..threadOverride = settings.codexDispatchThread;
  return dispatcher;
});

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

  // Codex 轉送：同一條事件流的第二個出口（app 即本機 agent 的通知樞紐）
  final dispatcher = ref.watch(codexDispatcherProvider);
  final codexSub = center.fresh.listen(dispatcher.handle);
  // writer locks 是本機 Codex session 的存活名錄。逐一向 Hub 報到並查指派，
  // 才能讓 UI 選到每個 thread，且把 assignment 精準 queue 給被選中的 session。
  unawaited(dispatcher.pollAssignments());
  final codexAssignmentPoll = Timer.periodic(
    const Duration(seconds: 10),
    (_) => unawaited(dispatcher.pollAssignments()),
  );

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
    codexSub.cancel();
    codexAssignmentPoll.cancel();
    activitySub.cancel();
    refreshDebounce?.cancel();
  });
});
