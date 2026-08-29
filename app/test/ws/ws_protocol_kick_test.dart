import 'dart:convert';

import 'package:chatroom_app/models/ws_event.dart';
import 'package:chatroom_app/ws/ws_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('error 事件解得出來，且只有 participant_kicked 算被踢', () {
    // 原本沒有這個 case，error 掉進 unknown 被安靜忽略——Hub 那半擋了，
    // App 這半什麼都沒做，於是「踢出」在使用者眼中等於沒生效。
    final kicked = WsProtocol.decode(jsonEncode({
      'type': 'error',
      'room_id': 'r1',
      'code': 'participant_kicked',
      'message': '你已被管理員移出這個聊天室',
    }));
    expect(kicked, isA<WsErrorEvent>());
    expect((kicked as WsErrorEvent).isKicked, isTrue);
    expect(kicked.roomId, 'r1');

    // 「還不知道你是誰」不是「你被踢了」——當成被踢會清掉本機身分，
    // 把時序問題偽裝成身分問題
    final noHeader = WsProtocol.decode(jsonEncode({
      'type': 'error',
      'room_id': 'r1',
      'code': 'participant_header_required',
      'message': '請求沒有帶 X-Participant-Id',
    })) as WsErrorEvent;
    expect(noHeader.isKicked, isFalse);

    // 非成員也不是被踢（可能只是身分還沒同步過來）
    final notMember = WsProtocol.decode(jsonEncode({
      'type': 'error',
      'room_id': 'r1',
      'code': 'not_a_member',
      'message': '你不是這個聊天室的成員',
    })) as WsErrorEvent;
    expect(notMember.isKicked, isFalse);
  });

  test('缺欄位的 error 不炸，退成空字串', () {
    final e = WsProtocol.decode(jsonEncode({'type': 'error'})) as WsErrorEvent;
    expect(e.roomId, '');
    expect(e.code, '');
    expect(e.isKicked, isFalse);
  });
}
