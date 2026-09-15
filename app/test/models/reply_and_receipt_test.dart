import 'package:chatroom_app/models/message.dart';
import 'package:flutter_test/flutter_test.dart';

/// 回覆帶著被回覆訊息的 seq，收據是要另外渲染的系統訊息。
///
/// 兩者都必須容忍缺值：舊訊息落庫時沒有 `reply_to_seq`，舊版 Hub 也不會
/// 送 `system_event`。缺值時該退回舊行為，而不是空畫面或崩潰。
void main() {
  Map<String, dynamic> json(Map<String, dynamic> extra) => {
        'id': 'm1',
        'seq': 12,
        'kind': 'chat',
        'content': '內容',
        'created_at': '2026-08-30T00:00:00Z',
        ...extra,
      };

  group('回覆目標的 seq', () {
    test('reply_to_seq 會被讀進來', () {
      final m = Message.fromJson(json({'reply_to': 'm0', 'reply_to_seq': 7}));
      expect(m.replyToSeq, 7);
    });

    test('舊訊息沒有 reply_to_seq 時為 null（UI 退回不顯示 #）', () {
      final m = Message.fromJson(json({'reply_to': 'm0'}));
      expect(m.replyToSeq, isNull);
    });

    test('reply_preview 也帶 seq', () {
      final m = Message.fromJson(json({
        'reply_to': 'm0',
        'reply_to_seq': 7,
        'reply_preview': {
          'seq': 7,
          'sender_name': 'Nova',
          'excerpt': '原文',
          'deleted': false,
        },
      }));
      expect(m.replyPreview!.seq, 7);
      expect(m.replyPreview!.senderName, 'Nova');
    });

    test('舊版 Hub 的 reply_preview 沒有 seq', () {
      final m = Message.fromJson(json({
        'reply_to': 'm0',
        'reply_preview': {
          'sender_name': 'Nova',
          'excerpt': '原文',
          'deleted': false,
        },
      }));
      expect(m.replyPreview!.seq, isNull);
    });
  });

  group('收據', () {
    Message system(String? event) => Message.fromJson(json({
          'kind': 'system',
          'system_event': ?event,
        }));

    test('提問的答案與釘選通知都是收據', () {
      expect(system('question_answered').isReceipt, isTrue);
      expect(system('question_skipped').isReceipt, isTrue);
      expect(system('pin').isReceipt, isTrue);
    });

    test('加入／離開／封存那類事件不是收據，維持髮絲線樣式', () {
      for (final e in ['join', 'leave', 'kick', 'archive', 'visibility']) {
        expect(system(e).isReceipt, isFalse, reason: e);
      }
    });

    test('沒有 system_event 的系統訊息不是收據（舊版 Hub）', () {
      expect(system(null).isReceipt, isFalse);
    });

    test('一般發言不是收據', () {
      expect(Message.fromJson(json({})).isReceipt, isFalse);
    });
  });
}
