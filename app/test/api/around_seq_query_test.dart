import 'package:chatroom_app/api/messages_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'identity_headers_test.dart' show Recorder;

/// 錨定讀取送出去的查詢參數。
///
/// B1 在 Hub 落地之後有一段時間**零 caller**——端點測試全綠，而 App 從來
/// 沒打過它。那種「功能完成」的宣稱只在 server 那一半成立（審核用 Codex F4）。
/// 這裡守的是 client 真的送得出正確的參數。
void main() {
  late Recorder rec;
  late Dio dio;

  setUp(() {
    rec = Recorder();
    dio = Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = rec;
  });

  test('around_seq 與 radius 一起送出，且不夾帶其他游標', () async {
    await MessagesApi(dio).read('r1', aroundSeq: 42, radius: 3,
        participantId: 'p1');

    final q = rec.seen.single.queryParameters;
    expect(q['around_seq'], 42);
    expect(q['radius'], 3);
    // Hub 對三方併用一律 422。夾帶了就會在正式環境變成一個必然失敗的請求
    expect(q.containsKey('after_seq'), isFalse);
    expect(q.containsKey('before_seq'), isFalse);
    expect(q.containsKey('pinned_only'), isFalse);
    expect(rec.seen.single.headers['X-Participant-Id'], 'p1');
  });

  test('沒用錨定時不送 radius——它對其他讀取沒有意義', () async {
    await MessagesApi(dio).read('r1', afterSeq: 7, participantId: 'p1');

    final q = rec.seen.single.queryParameters;
    expect(q['after_seq'], 7);
    expect(q.containsKey('radius'), isFalse);
    expect(q.containsKey('around_seq'), isFalse);
  });

  test('錨定與其他游標併用在 client 端就擋下，不要送出去被 422', () {
    expect(
      () => MessagesApi(dio).read('r1', aroundSeq: 42, beforeSeq: 10),
      throwsA(isA<AssertionError>()),
    );
    expect(
      () => MessagesApi(dio).read('r1', aroundSeq: 42, pinnedOnly: true),
      throwsA(isA<AssertionError>()),
    );
  });
}
