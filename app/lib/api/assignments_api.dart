import 'package:dio/dio.dart';

import '../models/assignment.dart';
import 'api_client.dart';

class AssignmentsApi {
  AssignmentsApi(this._dio);

  final Dio _dio;

  Future<String> create(
    String roomId, {
    required String targetSessionKey,
    String note = '',
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/rooms/$roomId/assignments',
          data: {'target_session_key': targetSessionKey, 'note': note},
        );
        return res.data!['id'] as String;
      });

  /// 房間視角的指派列表（含所有狀態，UI 檢視用）。
  Future<List<Assignment>> listForRoom(String roomId) => unwrap(() async {
        final res = await _dio
            .get<Map<String, dynamic>>('/api/rooms/$roomId/assignments');
        return ((res.data?['assignments'] as List?) ?? const [])
            .map((e) => Assignment.fromJson(e as Map<String, dynamic>))
            .toList();
      });

  /// session 視角的待處理指派（含 room_name / room_topic）。
  Future<List<Assignment>> listForSession(String sessionKey) =>
      unwrap(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/api/assignments',
          queryParameters: {'session_key': sessionKey},
        );
        return ((res.data?['assignments'] as List?) ?? const [])
            .map((e) => Assignment.fromJson(e as Map<String, dynamic>))
            .toList();
      });

  /// 處理一筆指派：accept=true 標為 accepted，false 標為 declined。
  Future<void> resolve(String assignmentId, {required bool accept}) =>
      unwrap(() => _dio.post(
            '/api/assignments/$assignmentId/resolve',
            data: {'status': accept ? 'accepted' : 'declined'},
          ));
}
