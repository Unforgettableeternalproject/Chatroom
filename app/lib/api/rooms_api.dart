import 'package:dio/dio.dart';

import '../models/assignment.dart';
import '../models/participant.dart';
import '../models/room.dart';
import 'api_client.dart';

class RoomListResult {
  const RoomListResult({
    required this.rooms,
    this.pendingAssignments = const [],
  });

  final List<Room> rooms;

  /// 帶 session_key 查詢時，Hub 一併回傳指派給該 session 的 pending 邀請。
  final List<Assignment> pendingAssignments;
}

class RoomDetail {
  const RoomDetail({
    required this.room,
    required this.participants,
    this.youAreAdmin = false,
  });

  final Room room;
  final List<Participant> participants;

  /// 帶 X-Session-Key 查詢且與建立者相符時為 true（可移出成員）。
  final bool youAreAdmin;
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

  Future<RoomListResult> list({String status = 'active', String? sessionKey}) =>
      unwrap(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/api/rooms',
          queryParameters: {
            'status': status,
            if (sessionKey != null && sessionKey.isNotEmpty)
              'session_key': sessionKey,
          },
        );
        final rooms = ((res.data?['rooms'] as List?) ?? const [])
            .map((e) => Room.fromJson(e as Map<String, dynamic>))
            .toList();
        final pending = ((res.data?['pending_assignments'] as List?) ??
                const [])
            .map((e) => Assignment.fromJson(e as Map<String, dynamic>))
            .toList();
        return RoomListResult(rooms: rooms, pendingAssignments: pending);
      });

  Future<Room> create({
    required String name,
    String topic = '',
    String? sessionKey,
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/rooms',
          data: {
            'name': name,
            'topic': topic,
            // 建立者 session：Hub 以此認定管理員（可移出成員）
            'session_key': ?sessionKey,
          },
        );
        return Room.fromJson(res.data!);
      });

  Future<RoomDetail> detail(String roomId, {String? sessionKey}) =>
      unwrap(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/api/rooms/$roomId',
          options: Options(headers: {'X-Session-Key': ?sessionKey}),
        );
        return RoomDetail(
          room: Room.fromJson(res.data!['room'] as Map<String, dynamic>),
          participants: ((res.data!['participants'] as List?) ?? const [])
              .map((e) => Participant.fromJson(e as Map<String, dynamic>))
              .toList(),
          youAreAdmin: (res.data!['you_are_admin'] as bool?) ?? false,
        );
      });

  /// 管理員移出成員（被移出的 session 無法重新加入該房）。
  Future<void> kick(
    String roomId, {
    required String targetId,
    required String participantId,
  }) =>
      unwrap(() => _dio.post(
            '/api/rooms/$roomId/participants/$targetId/kick',
            options: Options(headers: {'X-Participant-Id': participantId}),
          ));

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
