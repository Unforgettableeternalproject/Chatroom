import 'package:dio/dio.dart';

import '../models/agent_session.dart';
import '../models/assignment.dart';
import 'api_client.dart';

class AssignmentsApi {
  AssignmentsApi(this._dio);

  final Dio _dio;

  Future<String> create(
    String roomId, {
    required String targetSessionKey,
    String note = '',
    String assignedName = '',
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/rooms/$roomId/assignments',
          data: {
            'target_session_key': targetSessionKey,
            'note': note,
            'assigned_name': assignedName,
          },
        );
        return res.data!['id'] as String;
      });

  /// 掃描 Hub 見過且仍存活的 agent session（指派對象清單）。
  Future<List<AgentSession>> scanSessions() => unwrap(() async {
        final res = await _dio.get<Map<String, dynamic>>('/api/sessions');
        return ((res.data?['sessions'] as List?) ?? const [])
            .map((e) => AgentSession.fromJson(e as Map<String, dynamic>))
            .toList();
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
  Future<List<Assignment>> listForSession(
    String sessionKey, {
    String? kind,
    String? label,
  }) =>
      unwrap(() async {
        final nonEmptyLabel = label?.isNotEmpty == true ? label : null;
        final res = await _dio.get<Map<String, dynamic>>(
          '/api/assignments',
          queryParameters: {
            'session_key': sessionKey,
            'kind': ?kind,
            'label': ?nonEmptyLabel,
          },
        );
        return ((res.data?['assignments'] as List?) ?? const [])
            .map((e) => Assignment.fromJson(e as Map<String, dynamic>))
            .toList();
      });

  /// 指派方收回一筆還沒被處理的指派。與 [resolve] 是相反方向的動作——
  /// 那是被指派方回應，這是指派方反悔——所以狀態也分開（cancelled）。
  Future<void> cancel(String assignmentId) =>
      unwrap(() => _dio.delete('/api/assignments/$assignmentId'));

  /// 處理一筆指派：accept=true 標為 accepted，false 標為 declined。
  Future<void> resolve(String assignmentId, {required bool accept}) =>
      unwrap(() => _dio.post(
            '/api/assignments/$assignmentId/resolve',
            data: {'status': accept ? 'accepted' : 'declined'},
          ));
}
