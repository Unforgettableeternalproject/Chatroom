import 'package:flutter/foundation.dart';

import 'message.dart';

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

/// {"type": "pong"}
class WsPongEvent extends WsEvent {
  const WsPongEvent();
}

/// 未知事件型別（向前相容：忽略但保留 raw type 供 log）。
class WsUnknownEvent extends WsEvent {
  const WsUnknownEvent(this.type);
  final String type;
}
