import 'dart:convert';

import '../models/message.dart';
import '../models/question.dart';
import '../models/ws_event.dart';

/// WS 協定的唯一定義處。server 的 /ws 是純 JSON text frame：
/// 指令 subscribe / unsubscribe / ping，事件 messages / pong。
class WsProtocol {
  WsProtocol._();

  /// ``participantId`` 帶了才會收到 questions 事件——提問是定向的，
  /// server 只推給被問的那個人。
  static String subscribe(String roomId, int afterSeq, {String? participantId}) =>
      jsonEncode({
        'type': 'subscribe',
        'room_id': roomId,
        'after_seq': afterSeq,
        if (participantId != null && participantId.isNotEmpty)
          'participant_id': participantId,
      });

  static String unsubscribe(String roomId) =>
      jsonEncode({'type': 'unsubscribe', 'room_id': roomId});

  static String ping() => jsonEncode({'type': 'ping'});

  static WsEvent decode(String raw) {
    final data = jsonDecode(raw);
    if (data is! Map<String, dynamic>) return const WsUnknownEvent('?');
    switch (data['type']) {
      case 'messages':
        return WsMessagesEvent(
          roomId: data['room_id'] as String,
          roomStatus: data['room_status'] as String?,
          messages: ((data['messages'] as List?) ?? const [])
              .map((e) => Message.fromJson(e as Map<String, dynamic>))
              .toList(),
        );
      case 'questions':
        return WsQuestionsEvent(
          roomId: data['room_id'] as String,
          questions: ((data['questions'] as List?) ?? const [])
              .map((e) => Question.fromJson(e as Map<String, dynamic>))
              .toList(),
        );
      case 'error':
        // Hub 拒絕這個房的訂閱。原本沒有這個 case，於是它掉進 unknown 被
        // 安靜忽略——被踢的人畫面上什麼事都沒發生，內容照樣看得到，
        // 只是從此不再有新訊息（Hub 那半有做，App 這半沒接）。
        return WsErrorEvent(
          roomId: (data['room_id'] as String?) ?? '',
          code: (data['code'] as String?) ?? '',
          message: (data['message'] as String?) ?? '',
        );
      case 'pong':
        return const WsPongEvent();
      default:
        return WsUnknownEvent('${data['type']}');
    }
  }

  /// http(s) base URL → ws(s) /ws URL（token 走 query string，
  /// ⚠️ 這條 URL 絕不可進 log——redacting_logger 會遮，但別依賴它）。
  static Uri wsUri(String baseUrl, String? token) {
    final base = Uri.parse(baseUrl);
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '/ws',
      queryParameters: {
        if (token != null && token.isNotEmpty) 'token': token,
      },
    );
  }
}
