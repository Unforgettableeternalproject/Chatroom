import 'package:chatroom_app/api/assignments_api.dart';
import 'package:chatroom_app/api/messages_api.dart';
import 'package:chatroom_app/api/rooms_api.dart';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 攔下請求、記下標頭與 body，然後直接回 200——不需要真的 Hub。
/// 其他測試檔也用得到，所以不加底線。
class Recorder implements HttpClientAdapter {
  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(
      RequestOptions options, Stream<Uint8List>? _, Future<void>? _) async {
    seen.add(options);
    return ResponseBody.fromString('{"ok":true}', 200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Recorder rec;
  late Dio dio;

  setUp(() {
    rec = Recorder();
    dio = Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = rec;
  });

  group('房內動作要送得出身分——Hub 已經在驗，漏帶就是 401/403', () {
    test('撤回訊息帶 X-Participant-Id', () async {
      await MessagesApi(dio).delete('m1', participantId: 'p1');
      expect(rec.seen.single.headers['X-Participant-Id'], 'p1');
    });

    test('回應指派帶 X-Session-Key——指派寄給一把 key，回應資格是同一把', () async {
      await AssignmentsApi(dio)
          .resolve('a1', accept: false, sessionKey: 'dev-key');
      expect(rec.seen.single.headers['X-Session-Key'], 'dev-key');
    });

    test('回應指派**不靠** participant：婉拒的人根本不會進房', () async {
      await AssignmentsApi(dio)
          .resolve('a1', accept: true, sessionKey: 'dev-key');
      expect(rec.seen.single.headers.containsKey('X-Participant-Id'), isFalse);
    });

    test('收回指派兩種身分都送——房主可能還沒 join 自己的房', () async {
      await AssignmentsApi(dio)
          .cancel('a1', sessionKey: 'dev-key', participantId: 'p9');
      expect(rec.seen.single.headers['X-Session-Key'], 'dev-key');
      expect(rec.seen.single.headers['X-Participant-Id'], 'p9');
    });

    test('收回指派沒有 participant 時不送空標頭——空字串會被 Hub 當成有帶',
        () async {
      await AssignmentsApi(dio).cancel('a1', sessionKey: 'dev-key');
      expect(rec.seen.single.headers.containsKey('X-Participant-Id'), isFalse);
    });

    test('封存帶兩種身分——不帶的話 Hub 回 401，而那句錯誤講的是程式錯，'
        '沒權限的人會看到一則跟自己無關的話', () async {
      await RoomsApi(dio)
          .archive('r1', sessionKey: 'dev-key', participantId: 'p9');
      expect(rec.seen.single.headers['X-Session-Key'], 'dev-key');
      expect(rec.seen.single.headers['X-Participant-Id'], 'p9');
    });

    test('解封是同一道門的另一面，一樣要帶身分', () async {
      await RoomsApi(dio)
          .unarchive('r1', sessionKey: 'dev-key', participantId: 'p9');
      expect(rec.seen.single.headers['X-Session-Key'], 'dev-key');
      expect(rec.seen.single.headers['X-Participant-Id'], 'p9');
    });

    test('封存沒 join 過的房時不送空的 participant 標頭——建立者靠 session '
        'key 過關，空字串會讓 Hub 以為有帶', () async {
      await RoomsApi(dio).archive('r1', sessionKey: 'dev-key');
      expect(rec.seen.single.headers['X-Session-Key'], 'dev-key');
      expect(rec.seen.single.headers.containsKey('X-Participant-Id'), isFalse);
    });
  });
}
