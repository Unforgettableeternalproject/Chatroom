import 'package:chatroom_app/models/question.dart';
import 'package:chatroom_app/models/ws_event.dart';
import 'package:chatroom_app/ws/room_feed.dart';
import 'package:chatroom_app/ws/ws_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

Question q(String id, {String status = 'pending'}) => Question(
      id: id,
      roomId: 'r1',
      prompt: '問題 $id',
      status: status,
      createdAt: '2026-08-29T00:00:00+00:00',
    );

void main() {
  group('RoomFeed 的待答問題', () {
    test('覆寫而非合併——已回答的題目要從畫面上消失', () {
      final feed = RoomFeed('r1');
      feed.setQuestions([q('a'), q('b')]);
      expect(feed.questions.map((e) => e.id), ['a', 'b']);

      // server 推的是「目前待答」的完整快照；a 被回答後就不在裡面了
      feed.setQuestions([q('b')]);
      expect(feed.questions.map((e) => e.id), ['b']);
    });

    test('內容沒變就不通知，避免無謂重畫', () async {
      final feed = RoomFeed('r1');
      var notifications = 0;
      feed.changes.listen((_) => notifications++);

      feed.setQuestions([q('a')]);
      feed.setQuestions([q('a')]);
      await Future<void>.delayed(Duration.zero);
      expect(notifications, 1);

      feed.setQuestions([q('a'), q('b')]);
      await Future<void>.delayed(Duration.zero);
      expect(notifications, 2);
    });

    test('reset 一併清掉問題', () {
      final feed = RoomFeed('r1');
      feed.setQuestions([q('a')]);
      feed.reset();
      expect(feed.questions, isEmpty);
    });
  });

  group('WsProtocol', () {
    test('subscribe 帶 participant_id 才會收到定向問題', () {
      expect(WsProtocol.subscribe('r1', 5), isNot(contains('participant_id')));
      expect(
        WsProtocol.subscribe('r1', 5, participantId: 'p1'),
        contains('"participant_id":"p1"'),
      );
      // 空字串等同沒有身分，不該送出去讓 server 拿去比對
      expect(WsProtocol.subscribe('r1', 5, participantId: ''),
          isNot(contains('participant_id')));
    });

    test('解出 questions 事件', () {
      final event = WsProtocol.decode(
        '{"type":"questions","room_id":"r1","questions":['
        '{"id":"q1","room_id":"r1","prompt":"要用哪個方案？","status":"pending",'
        '"created_at":"2026-08-29T00:00:00+00:00","allow_free_text":false,'
        '"asker_name":"諾薇亞","options":[{"label":"A","description":"較快"}]}]}',
      );
      expect(event, isA<WsQuestionsEvent>());
      final questions = (event as WsQuestionsEvent).questions;
      expect(questions.single.prompt, '要用哪個方案？');
      expect(questions.single.askerName, '諾薇亞');
      expect(questions.single.allowFreeText, isFalse);
      expect(questions.single.options.single.description, '較快');
    });
  });
}
