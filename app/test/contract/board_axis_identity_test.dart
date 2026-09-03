import 'package:chatroom_app/api/board_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../api/identity_headers_test.dart' show Recorder;

/// 卡片操作的身分有兩個來源：房軸帶 `X-Participant-Id`，板軸帶
/// `X-Session-Key`（Board Library 沒有房，就沒有 participant）。
///
/// 🔴 少了板軸那條的後果不是「某個動作失敗」，是**整塊板從 Library 進去
/// 只能看**——而那是艾斯維爾指出的「Board 沒有綁房間就必定是唯讀」。
void main() {
  late Recorder rec;
  late BoardApi api;

  setUp(() {
    rec = Recorder();
    api = BoardApi(
        Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = rec);
  });

  test('房軸：帶 participant，不帶 session key——語意維持原樣', () async {
    await api.claim('t1', participantId: 'p1');
    final h = rec.seen.single.headers;
    expect(h['X-Participant-Id'], 'p1');
    expect(h.containsKey('X-Session-Key'), isFalse);
  });

  test('🔴 板軸：只帶 session key 也動得了', () async {
    await api.claim('t1', sessionKey: 'k1');
    final h = rec.seen.single.headers;
    expect(h['X-Session-Key'], 'k1');
    expect(h.containsKey('X-Participant-Id'), isFalse);
  });

  test('推狀態同樣兩條軸都通', () async {
    await api.setTaskStatus('t1', sessionKey: 'k1', status: 'done');
    expect(rec.seen.single.headers['X-Session-Key'], 'k1');
  });

  test('週期的三段動作也認 session key', () async {
    await api.completeObjective('o1', sessionKey: 'k1');
    expect(rec.seen.single.headers['X-Session-Key'], 'k1');
  });

  test('🔴 板軸建週期走自己的端點——不是「板軸開不了週期」，'
      '那支端點一直都在（app.py:6042）', () async {
    final boards = BoardsApi(
        Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = rec);
    try {
      await boards.addObjective('b1', sessionKey: 'k1', title: '週期');
    } catch (_) {}
    final req = rec.seen.single;
    expect(req.path, '/api/boards/b1/objectives');
    expect(req.headers['X-Session-Key'], 'k1');
  });

  test('完成卡片的捷徑不可以把 session key 弄丟——'
      '轉發時漏掉一個具名參數不會有任何地方報錯', () async {
    await api.completeTask('t1', sessionKey: 'k1');
    expect(rec.seen.single.headers['X-Session-Key'], 'k1');
  });

  test('建階段（checklist）認 session key——板軸要能往裡面放東西', () async {
    // Recorder 回空 body，而 addChecklist 會去解析 id ⇒ 解析會炸。
    // 這裡要釘的是**送出去的身分**，不是回應的形狀
    try {
      await api.addChecklist('o1', sessionKey: 'k1', title: '階段');
    } catch (_) {}
    expect(rec.seen.single.headers['X-Session-Key'], 'k1');
  });
}
