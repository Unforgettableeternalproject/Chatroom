import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/message.dart';
import '../ws/room_feed.dart';
import 'app_providers.dart';

/// 房間的訊息 feed。建立時向 realtime service 訂閱（refCount++），
/// autoDispose 時退訂——service 端保留 store 30 秒供來回切換。
final roomFeedProvider =
    Provider.autoDispose.family<RoomFeed, String>((ref, roomId) {
  final service = ref.watch(realtimeServiceProvider);
  final feed = service.subscribe(roomId);
  ref.onDispose(() => service.unsubscribe(roomId));
  return feed;
});

/// 訊息列表（seq 遞增）。feed 每次變更都重新發射快照。
final messagesProvider = StreamProvider.autoDispose
    .family<List<Message>, String>((ref, roomId) async* {
  final feed = ref.watch(roomFeedProvider(roomId));
  yield feed.messages.toList();
  await for (final _ in feed.changes) {
    yield feed.messages.toList();
  }
});

/// 人類身分：進房即 join（server 端冪等——同 session_key active 時
/// 直接回既有身分且不重複廣播，所以不需要先查再 join）。
final identityProvider = FutureProvider.autoDispose
    .family<({String participantId, String displayName}), String>(
        (ref, roomId) async {
  // 進房身分要撐過畫面重建；連結斷 30 秒後自動釋放
  final link = ref.keepAlive();
  ref.onDispose(link.close);
  final config = ref.watch(appConfigProvider);
  final api = ref.watch(roomsApiProvider);
  final result = await api.join(
    roomId,
    kind: 'human',
    sessionKey: config.deviceKey,
    // ⚠️ role 必填 'human'：漏了會被 sweeper 當 agent 掃掉（P3-07 條件 5）
    role: 'human',
    preferredName: config.preferredName.isEmpty ? null : config.preferredName,
  );
  await ref
      .read(settingsRepoProvider)
      .setParticipantId(roomId, result.participantId);
  return (
    participantId: result.participantId,
    displayName: result.displayName,
  );
});
