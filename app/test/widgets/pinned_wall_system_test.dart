import 'package:chatroom_app/models/message.dart';
import 'package:chatroom_app/screens/pinned/pinned_wall_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// 釘選牆上的 system 訊息（09/08 卡 bf3547db）。
///
/// 艾斯維爾釘了一則收據之後，牆上長出一個叫「（未知）」、徽章寫 OTHER 的
/// 發話者——而房裡沒有任何人離開過。那句話是假的，更糟的是它指向一個不存在
/// 的偵錯方向（去查誰離開了）。
///
/// ⚠️ 這裡守的是**兩種情況要分得開**：沒有發話者（system）與查不到名字
/// （人走了／快取還沒補）。合成同一句話的話，真正該追的那種就沒人追了。
Message _msg({required String kind, String? senderName}) => Message(
      id: 'm1',
      seq: 76,
      updateSeq: 0,
      kind: kind,
      content: '內容',
      createdAt: '2026-09-08T00:00:00+00:00',
      senderId: kind == 'system' ? null : 'p1',
      senderName: senderName,
    );

void main() {
  test('🔴 system 訊息掛在「系統」名下，不是某個未知的人', () {
    expect(pinnedSenderLabel(_msg(kind: 'system')), '系統');
  });

  test('查不到名字的真人／agent 仍然是（未知）——那種才需要去追', () {
    expect(pinnedSenderLabel(_msg(kind: 'chat')), '（未知）');
  });

  test('一般發話者照舊顯示自己的名字', () {
    expect(pinnedSenderLabel(_msg(kind: 'chat', senderName: '決策Novia')),
        '決策Novia');
  });

  test('system 訊息即使帶著名字也不冒充發話者', () {
    // Hub 未來若在 system 訊息上塞了名字（例如操作者），釘選牆也不該把它
    // 畫成「這則是他說的」——那是一則系統留痕，不是他的發言
    expect(pinnedSenderLabel(_msg(kind: 'system', senderName: '某人')), '系統');
  });
}
