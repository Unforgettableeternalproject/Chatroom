import 'package:chatroom_app/export/conversation_format.dart';
import 'package:chatroom_app/models/attachment.dart';
import 'package:chatroom_app/models/message.dart';
import 'package:flutter_test/flutter_test.dart';

Message msg(
  int seq, {
  String content = '內容',
  String? sender = 'Novia',
  String? senderId = 'p1',
  String kind = 'chat',
  String? systemEvent,
  bool pinned = false,
  bool deleted = false,
  int? replyToSeq,
  List<Attachment> attachments = const [],
  String createdAt = '2026-08-31T09:15:22.480645+00:00',
}) =>
    Message(
      id: 'm$seq',
      seq: seq,
      updateSeq: 0,
      kind: kind,
      content: content,
      createdAt: createdAt,
      senderId: senderId,
      senderName: sender,
      systemEvent: systemEvent,
      pinned: pinned,
      deleted: deleted,
      replyToSeq: replyToSeq,
      attachments: attachments,
    );

void main() {
  group('formatConversationLog', () {
    test('房名當標題，每則一行', () {
      final out = formatConversationLog(
        roomName: 'Chatroom 開發 08/31',
        messages: [msg(1, content: '早'), msg(2, content: '安')],
      );
      expect(out, startsWith('# Chatroom 開發 08/31\n'));
      expect(out, contains('Novia：早'));
      expect(out, contains('Novia：安'));
    });

    test('時間標 Z 且不轉本地——匯出檔會跨時區傳閱', () {
      final out = formatConversationLog(
        roomName: '房',
        messages: [msg(1, createdAt: '2026-08-31T09:15:22.480645+00:00')],
      );
      expect(out, contains('[2026-08-31 09:15:22Z]'));
    });

    test('非 UTC 的時間戳換算成 UTC 再輸出，不是把偏移量丟掉', () {
      final out = formatConversationLog(
        roomName: '房',
        messages: [msg(1, createdAt: '2026-08-31T17:15:22+08:00')],
      );
      expect(out, contains('[2026-08-31 09:15:22Z]'));
    });

    test('解析不了的時間原樣輸出，不吞掉', () {
      // 匯出的價值在完整。為了排版把看不懂的東西丟掉是本末倒置
      final out = formatConversationLog(
        roomName: '房',
        messages: [msg(1, createdAt: '很久以前')],
      );
      expect(out, contains('[很久以前]'));
    });

    test('撤回的訊息標「已撤回」，不是印一行空白', () {
      // Hub 已把 content 清空，照印會像資料壞掉而不像被撤回
      final out = formatConversationLog(
        roomName: '房',
        messages: [msg(1, content: '', deleted: true)],
      );
      expect(out, contains('Novia：（已撤回）'));
    });

    test('system 訊息用另一種前綴，不冒充成某人的發言', () {
      final out = formatConversationLog(
        roomName: '房',
        messages: [
          msg(1,
              kind: 'system',
              systemEvent: 'join',
              sender: null,
              senderId: null,
              content: 'Novia 加入了聊天室'),
        ],
      );
      expect(out, contains('· Novia 加入了聊天室'));
      expect(out, isNot(contains('：Novia 加入了聊天室')));
    });

    test('回覆標的是 seq 不是內容——內容會被撤回，seq 不會', () {
      final out = formatConversationLog(
        roomName: '房',
        messages: [msg(9, replyToSeq: 4, content: '同意')],
      );
      expect(out, contains('↩ #4'));
    });

    test('釘選標記與附件列在同一則底下', () {
      final out = formatConversationLog(
        roomName: '房',
        messages: [
          msg(1, pinned: true, content: '決議', attachments: [
            const Attachment(
              id: 'a1',
              filename: '截圖.png',
              mime: 'image/png',
              size: 18645,
              isImage: true,
            ),
          ]),
        ],
      );
      expect(out, contains('📌'));
      expect(out, contains('📎 截圖.png（18 KB）'));
    });

    test('沒有名字時不印空字串，缺席要看得出來是缺席', () {
      final out = formatConversationLog(
        roomName: '房',
        messages: [msg(1, sender: null, content: '孤兒訊息')],
      );
      expect(out, contains('（不明）：孤兒訊息'));
    });
  });
}
