import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/message.dart';
import '../models/question.dart';
import '../ws/room_feed.dart';
import 'app_providers.dart';

/// 房間的訊息 feed。建立時向 realtime service 訂閱（refCount++），
/// autoDispose 時退訂——service 端保留 store 30 秒供來回切換。
final roomFeedProvider =
    Provider.autoDispose.family<RoomFeed, String>((ref, roomId) {
  final service = ref.watch(realtimeServiceProvider);
  // 上次進房留下的身分（同步可讀）先用著；首次進房時是 null，
  // 由 roomQuestionsProvider 在 join 完成後補送
  final cached = ref.watch(settingsRepoProvider).participantId(roomId);
  final feed = service.subscribe(roomId, participantId: cached);
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
  final settings = ref.read(settingsRepoProvider);
  await settings.setParticipantId(roomId, result.participantId);
  // 顯示名稱供通知中心做 mention 比對（房內重名時 Hub 會改名，以實際值為準）
  await settings.setDisplayName(roomId, result.displayName);
  return (
    participantId: result.participantId,
    displayName: result.displayName,
  );
});

/// 指名問「我」的待答問題。
///
/// 這裡順便把 join 後才拿得到的 participant_id 交給 realtime service——
/// 訂閱發生在 join 之前，不補送的話首次進房永遠收不到問題。
final roomQuestionsProvider = StreamProvider.autoDispose
    .family<List<Question>, String>((ref, roomId) async* {
  final feed = ref.watch(roomFeedProvider(roomId));
  final identity = ref.watch(identityProvider(roomId));
  final participantId = identity.value?.participantId;
  if (participantId != null) {
    ref.watch(realtimeServiceProvider).setParticipantId(roomId, participantId);
  }
  yield feed.questions;
  await for (final _ in feed.changes) {
    yield feed.questions;
  }
});
