import 'package:dio/dio.dart';

import '../models/message.dart';
import 'api_client.dart';

class MessagePage {
  const MessagePage({
    required this.messages,
    required this.hasMore,
    this.nextAfterSeq,
    this.nextBeforeSeq,
  });

  final List<Message> messages;
  final bool hasMore;
  final int? nextAfterSeq;
  final int? nextBeforeSeq;
}

class PostResult {
  const PostResult({required this.id, required this.seq});
  final String id;
  final int seq;
}

class MessagesApi {
  MessagesApi(this._dio);

  final Dio _dio;

  /// after_seq 正向翻頁（補訊）、before_seq 反向翻頁（載入歷史），兩者互斥。
  Future<MessagePage> read(
    String roomId, {
    int? afterSeq,
    int? beforeSeq,
    int limit = 100,
    bool pinnedOnly = false,
  }) =>
      unwrap(() async {
        assert(afterSeq == null || beforeSeq == null,
            'after_seq 與 before_seq 不可同時使用');
        final res = await _dio.get<Map<String, dynamic>>(
          '/api/rooms/$roomId/messages',
          queryParameters: {
            'after_seq': ?afterSeq,
            'before_seq': ?beforeSeq,
            'limit': limit,
            if (pinnedOnly) 'pinned_only': true,
          },
        );
        return MessagePage(
          messages: ((res.data?['messages'] as List?) ?? const [])
              .map((e) => Message.fromJson(e as Map<String, dynamic>))
              .toList(),
          hasMore: (res.data?['has_more'] as bool?) ?? false,
          nextAfterSeq: res.data?['next_after_seq'] as int?,
          nextBeforeSeq: res.data?['next_before_seq'] as int?,
        );
      });

  Future<PostResult> post(
    String roomId, {
    required String participantId,
    required String content,
    List<String> mentions = const [],
    String? replyTo,
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/rooms/$roomId/messages',
          data: {
            'content': content,
            'mentions': mentions,
            'reply_to': ?replyTo,
          },
          options: Options(headers: {'X-Participant-Id': participantId}),
        );
        return PostResult(
          id: res.data!['id'] as String,
          seq: res.data!['seq'] as int,
        );
      });

  Future<void> pin(String messageId, {required String participantId}) =>
      unwrap(() => _dio.post(
            '/api/messages/$messageId/pin',
            options: Options(headers: {'X-Participant-Id': participantId}),
          ));

  Future<void> unpin(String messageId, {required String participantId}) =>
      unwrap(() => _dio.delete(
            '/api/messages/$messageId/pin',
            options: Options(headers: {'X-Participant-Id': participantId}),
          ));

  /// 人類管控用的軟刪除；server 端不驗 participant，靠 API token。
  Future<void> delete(String messageId) =>
      unwrap(() => _dio.delete('/api/messages/$messageId'));
}
