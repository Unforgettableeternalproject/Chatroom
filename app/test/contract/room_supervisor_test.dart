import 'package:chatroom_app/api/board_api.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../api/identity_headers_test.dart' show Recorder;

/// Supervisor 是 **per-room** 的（艾斯維爾 2026-09-03：「他不再是 per board
/// 而是 per room」）。這裡釘住那條契約的兩端：送出去的形狀、讀回來的形狀。
void main() {
  group('指派送的是 participant_id，不是 session_key', () {
    late Recorder rec;
    late BoardApi api;

    setUp(() {
      rec = Recorder();
      api = BoardApi(
          Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = rec);
    });

    test('🔴 本次修的根因：UI 拿不到 session_key，所以只能送 participant_id',
        () async {
      await api.setSupervisor('r1',
          participantId: 'me', targetParticipantId: 'p9');
      final req = rec.seen.single;
      expect(req.method, 'POST');
      expect(req.path, '/api/rooms/r1/board/supervisor');
      expect(req.headers['X-Participant-Id'], 'me');
      final body = req.data as Map;
      expect(body['participant_id'], 'p9');
      // session_key 一併送空字串：Hub 兩個欄位都收，空的那個表示「不用這條路」
      expect(body['session_key'], '');
    });

    test('不給對象＝卸任', () async {
      await api.setSupervisor('r1', participantId: 'me');
      final body = rec.seen.single.data as Map;
      expect(body['participant_id'], '');
      expect(body['session_key'], '');
    });
  });

  group('attached_rooms[].supervisor 兩種狀態都讀得出來', () {
    AttachedRoom parse(Map<String, dynamic> sup) =>
        AttachedRoom.fromJson({'id': 'r1', 'name': '房', 'supervisor': sup});

    test('沒有指派', () {
      final r = AttachedRoom.fromJson({'id': 'r1', 'supervisor': null});
      expect(r.supervisor, isNull);
    });

    test('在任', () {
      final r = parse({
        'actor_key': 'k1',
        'display_name': '艾斯維爾',
        'actor_kind': 'human',
        'departed': false,
      });
      expect(r.supervisor?.displayName, '艾斯維爾');
    });

    test('離場即卸任：舊 Hub 帶 departed 也照常讀，不再有已離開狀態', () {
      final r = parse({
        'actor_key': 'k1',
        'display_name': '艾斯維爾',
        'actor_kind': 'human',
        'departed': true,
      });
      expect(r.supervisor, isNotNull);
    });
  });
}
