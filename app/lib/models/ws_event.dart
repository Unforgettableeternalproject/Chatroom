import 'package:flutter/foundation.dart';

import 'message.dart';
import 'question.dart';

/// WS 伺服器事件。協定唯一定義處在 ws/ws_protocol.dart，
/// 這裡只放解碼後的資料形。
sealed class WsEvent {
  const WsEvent();
}

/// {"type": "messages", "room_id", "room_status", "messages": [...]}
/// 新訊息與既有訊息的狀態變更（釘選/刪除）共用此事件——
/// server 推的是完整快照，client 以 seq upsert 覆寫即可。
@immutable
class WsMessagesEvent extends WsEvent {
  const WsMessagesEvent({
    required this.roomId,
    required this.roomStatus,
    required this.messages,
  });

  final String roomId;
  final String? roomStatus;
  final List<Message> messages;
}

/// {"type": "questions", "room_id", "questions": [...]}
/// 只會推給被問的那個人（subscribe 時帶 participant_id 才會收到）。
/// server 推的是該人目前所有待答問題的完整快照，client 直接覆蓋。
@immutable
class WsQuestionsEvent extends WsEvent {
  const WsQuestionsEvent({required this.roomId, required this.questions});

  final String roomId;
  final List<Question> questions;
}

/// {"type": "pong"}
class WsPongEvent extends WsEvent {
  const WsPongEvent();
}

/// 未知事件型別（向前相容：忽略但保留 raw type 供 log）。
class WsUnknownEvent extends WsEvent {
  const WsUnknownEvent(this.type);
  final String type;
}

/// {"type": "error", "room_id", "code", "message"}
///
/// Hub 拒絕這個房的訂閱。**必須看 `code` 而不是有沒有錯**——
/// `participant_kicked` 是「不要再看到這裡」的人為決定，該退場；
/// `participant_header_required` 只是「還不知道你是誰」，清掉本機身分
/// 會把版本／時序問題偽裝成身分問題（2026-08-29 踩過）。
@immutable
class WsErrorEvent extends WsEvent {
  const WsErrorEvent({
    required this.roomId,
    required this.code,
    required this.message,
  });

  final String roomId;
  final String code;
  final String message;

  /// 管理員把這個身分移出了房間——本機該跟著退場。
  bool get isKicked => code == 'participant_kicked';
}
