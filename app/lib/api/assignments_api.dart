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
}
