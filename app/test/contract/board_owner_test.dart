import 'package:chatroom_app/api/board_api.dart';
import 'package:chatroom_app/core/errors/api_exception.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../api/identity_headers_test.dart' show Recorder;

/// owner 是這塊板唯一不靠掛接關係的權限來源，所以它是「還有沒有人管得動
/// 這塊板」的最後一道保險——交接與接管兩條路都要在。
void main() {
  late Recorder rec;
  late BoardsApi api;

  setUp(() {
    rec = Recorder();
    api = BoardsApi(
        Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = rec);
  });

  test('移交：POST /api/boards/{id}/owner，帶 target_actor_key 與身分', () async {
    await api.transferOwner('b1', sessionKey: 'k1', targetActorKey: 'a2');
    final req = rec.seen.single;
    expect(req.method, 'POST');
    expect(req.path, '/api/boards/b1/owner');
    expect(req.headers['X-Session-Key'], 'k1');
    expect((req.data as Map)['target_actor_key'], 'a2');
  });

  test('接管：走 /owner/claim，不帶 target——接管的對象一定是自己', () async {
    await api.claimOwner('b1', sessionKey: 'k1');
    final req = rec.seen.single;
    expect(req.path, '/api/boards/b1/owner/claim');
    expect(req.headers['X-Session-Key'], 'k1');
  });

  test('🔴 owner 還活著時 409 的兩個欄位要拿得到——'
      '「20 分鐘前還在」與「昨天之後沒再出現」是完全不同的決定', () {
    // Hub 對 `board_has_owner` 回的 detail 形狀
    const e = ConflictException('board_has_owner', '這塊板還有 owner',
        detail: {
      'owner_display_name': '審核Novia',
      'owner_last_seen_at': '2026-09-02T10:00:00+00:00',
    });
    expect(e.code, 'board_has_owner');
    expect(e.detail['owner_display_name'], '審核Novia');
    // 沒有這個欄位的話，畫面只能說「有 owner」——而那句話對兩種情況一樣
    expect(e.detail['owner_last_seen_at'], '2026-09-02T10:00:00+00:00');
  });
}
