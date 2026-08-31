import 'package:chatroom_app/api/messages_api.dart';
import 'package:chatroom_app/models/message.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'api/identity_headers_test.dart' show Recorder;

Message _msg({String? editedAt}) => Message.fromJson({
      'id': 'm1',
      'seq': 7,
      'content': '原本的內容',
      'sender_name': '諾薇亞',
      'edited_at': ?editedAt,
    });

void main() {
  group('編輯過的訊息看得出來——那正是這條權限界線的理由', () {
    test('edited_at 解析得出來', () {
      expect(_msg(editedAt: '2026-08-31T10:00:00+00:00').editedAt, isNotNull);
    });

    test('沒編輯過就是 null，不是空字串——空字串會讓標記一直亮著', () {
      expect(_msg().editedAt, isNull);
    });
  });

  group('編輯只送 content，且要帶身分', () {
    late Recorder rec;
    late MessagesApi api;

    setUp(() {
      rec = Recorder();
      api = MessagesApi(
          Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = rec);
    });

    test('走 PATCH，帶 X-Participant-Id', () async {
      await api.edit('m1', participantId: 'p1', content: '改過的');
      expect(rec.seen.single.method, 'PATCH');
      expect(rec.seen.single.headers['X-Participant-Id'], 'p1');
    });

    test('**不送 mentions**——改了會讓「誰被叫醒」與內容對不上，'
        '而喚醒已經發生過了', () async {
      await api.edit('m1', participantId: 'p1', content: '改過的');
      final body = rec.seen.single.data as Map;
      expect(body.keys, ['content']);
    });
  });
}
