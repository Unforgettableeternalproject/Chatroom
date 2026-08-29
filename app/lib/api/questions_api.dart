import 'package:dio/dio.dart';

import '../models/question.dart';
import 'api_client.dart';

class QuestionsApi {
  QuestionsApi(this._dio);

  final Dio _dio;

  /// 房內問題列表。``pendingOnly`` 為 false 時含已回答與已略過的。
  Future<List<Question>> listForRoom(
    String roomId, {
    bool pendingOnly = true,
    String? targetId,
  }) =>
      unwrap(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/api/rooms/$roomId/questions',
          queryParameters: {
            if (pendingOnly) 'status': 'pending',
            'target_id': ?targetId,
          },
        );
        return ((res.data?['questions'] as List?) ?? const [])
            .map((e) => Question.fromJson(e as Map<String, dynamic>))
            .toList();
      });

  /// 回答一題。``kind`` 為 option / free_text / skip。
  ///
  /// skip 是「不在這裡回答」的明確表態，與放著不管（逾時）不同——
  /// agent 收到 skip 會改用它原本的方式問，收到逾時則會繼續等。
  Future<void> answer(
    String questionId, {
    required String kind,
    String answer = '',
    required String participantId,
  }) =>
      unwrap(() async {
        await _dio.post<Map<String, dynamic>>(
          '/api/questions/$questionId/answer',
          data: {'kind': kind, 'answer': answer},
          options: Options(headers: {'X-Participant-Id': participantId}),
        );
      });
}
