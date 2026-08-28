import 'package:dio/dio.dart';

import '../models/participant.dart';
import '../models/room.dart';
import 'api_client.dart';

class RoomListResult {
  const RoomListResult({required this.rooms});
  final List<Room> rooms;
}

class RoomDetail {
  const RoomDetail({required this.room, required this.participants});
  final Room room;
  final List<Participant> participants;
}

class JoinResult {
  const JoinResult({
    required this.participantId,
    required this.displayName,
    required this.rejoined,
  });
  final String participantId;
  final String displayName;
  final bool rejoined;
}

class HealthResult {
  const HealthResult({required this.ok, required this.version});
  final bool ok;
  final String version;
}

class RoomsApi {
  RoomsApi(this._dio);

  final Dio _dio;

  Future<HealthResult> health() => unwrap(() async {
        final res = await _dio.get<Map<String, dynamic>>('/api/health');
        return HealthResult(
          ok: (res.data?['ok'] as bool?) ?? false,
          version: (res.data?['version'] as String?) ?? '?',
        );
      });

  Future<RoomListResult> list({String status = 'active'}) => unwrap(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/api/rooms',
          queryParameters: {'status': status},
        );
        final rooms = ((res.data?['rooms'] as List?) ?? const [])
            .map((e) => Room.fromJson(e as Map<String, dynamic>))
            .toList();
        return RoomListResult(rooms: rooms);
      });

  Future<Room> create({required String name, String topic = ''}) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/rooms',
          data: {'name': name, 'topic': topic},
        );
        return Room.fromJson(res.data!);
      });

  Future<RoomDetail> detail(String roomId) => unwrap(() async {
        final res = await _dio.get<Map<String, dynamic>>('/api/rooms/$roomId');
        return RoomDetail(
          room: Room.fromJson(res.data!['room'] as Map<String, dynamic>),
          participants: ((res.data!['participants'] as List?) ?? const [])
              .map((e) => Participant.fromJson(e as Map<String, dynamic>))
              .toList(),
        );
      });

  Future<void> archive(String roomId) =>
      unwrap(() => _dio.post('/api/rooms/$roomId/archive'));

  Future<void> unarchive(String roomId) =>
      unwrap(() => _dio.post('/api/rooms/$roomId/unarchive'));

  Future<JoinResult> join(
    String roomId, {
    required String kind,
    required String sessionKey,
    required String role,
    String? preferredName,
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/rooms/$roomId/join',
          data: {
            'kind': kind,
            'session_key': sessionKey,
            // ⚠️ role 不可遺漏：JoinRequest 預設 'agent'，
            // 人類漏送會在閒置 10 分鐘後被 sweeper 掃掉（P3-07 條件 5）。
            'role': role,
            if (preferredName != null && preferredName.isNotEmpty)
              'preferred_name': preferredName,
          },
        );
        return JoinResult(
          participantId: res.data!['participant_id'] as String,
          displayName: res.data!['display_name'] as String,
          rejoined: (res.data!['rejoined'] as bool?) ?? false,
        );
      });

  Future<void> leave(String roomId, {required String participantId}) =>
      unwrap(() => _dio.post(
            '/api/rooms/$roomId/leave',
            options: Options(headers: {'X-Participant-Id': participantId}),
          ));

  Future<void> heartbeat(String roomId, {required String participantId}) =>
      unwrap(() => _dio.post(
            '/api/rooms/$roomId/heartbeat',
            options: Options(headers: {'X-Participant-Id': participantId}),
          ));
}
