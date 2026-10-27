import '../models/reaction.dart';
import '../ws/room_feed.dart';

/// 樂觀更新的表情切換：先改畫面，送出失敗就還原。
///
/// 選到自己目前那個＝取消，選別的＝替換（每人每則只有一個）。[send] 收到
/// `cancel`（true＝DELETE、false＝PUT），回傳 Hub 算好的最新彙總。
/// 回傳 true＝成功；false＝已還原，呼叫端提示使用者。
Future<bool> reactOptimistic({
  required RoomFeed? feed,
  required String messageId,
  required List<ReactionSummary> fallbackBefore,
  required String emoji,
  required String myName,
  required Future<List<ReactionSummary>> Function(bool cancel) send,
}) async {
  final before = feed?.byId(messageId)?.reactions ?? fallbackBefore;
  final cancel = myReactionOf(before) == emoji;
  feed?.setReactions(
    messageId,
    reactionsAfter(before, toEmoji: cancel ? null : emoji, myName: myName),
  );
  try {
    final after = await send(cancel);
    feed?.setReactions(messageId, after);
    return true;
  } catch (_) {
    feed?.setReactions(messageId, before);
    return false;
  }
}
