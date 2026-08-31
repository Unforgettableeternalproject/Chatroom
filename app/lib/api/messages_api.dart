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

class UpdatesResult {
  const UpdatesResult({
    required this.messages,
    required this.youWereMentioned,
    required this.lastSeq,
  });

  final List<Message> messages;
  final bool youWereMentioned;
  final int lastSeq;
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
  ///
  /// [participantId] 是房內身分。房間是讀取邊界——非成員讀不到房內內容，
  /// 所以每一次讀都要帶。舊版 Hub 忽略這個標頭，帶了不會有副作用，
  /// 因此可以先於 Hub 升級上線。
  Future<MessagePage> read(
    String roomId, {
    int? afterSeq,
    int? beforeSeq,
    int limit = 100,
    bool pinnedOnly = false,
    String? participantId,
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
          options: Options(headers: {'X-Participant-Id': ?participantId}),
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

  /// long-poll：有 MAX(seq, update_seq) > after_seq 的訊息立即返回，
  /// 否則掛起到 timeout 秒（Hub 上限 55）。WS 之外的補訊備援通道。
  /// 帶 participantId 時回應才會計算 you_were_mentioned。
  Future<UpdatesResult> updates(
    String roomId, {
    int afterSeq = 0,
    double timeout = 25.0,
    String? participantId,
  }) =>
      unwrap(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/api/rooms/$roomId/updates',
          queryParameters: {'after_seq': afterSeq, 'timeout': timeout},
          options: Options(
            headers: {'X-Participant-Id': ?participantId},
            // dio 全域 receiveTimeout 30s 貼著 long-poll 上限，個別放寬
            receiveTimeout: Duration(seconds: timeout.ceil() + 10),
          ),
        );
        return UpdatesResult(
          messages: ((res.data?['messages'] as List?) ?? const [])
              .map((e) => Message.fromJson(e as Map<String, dynamic>))
              .toList(),
          youWereMentioned:
              (res.data?['you_were_mentioned'] as bool?) ?? false,
          lastSeq: (res.data?['last_seq'] as int?) ?? afterSeq,
        );
      });

  Future<PostResult> post(
    String roomId, {
    required String participantId,
    required String content,
    List<String> mentions = const [],
    String? replyTo,
    List<String> attachmentIds = const [],
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/rooms/$roomId/messages',
          data: {
            'content': content,
            'mentions': mentions,
            'reply_to': ?replyTo,
            // 空陣列不送：舊版 Hub 沒有這個欄位，多送會被 pydantic 擋掉
            if (attachmentIds.isNotEmpty) 'attachment_ids': attachmentIds,
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

  /// 軟刪除（撤回）。**本人或聊天室建立者**才做得到——Hub 端會驗身分，
  /// 沒帶 `X-Participant-Id` 一律 401，所以這個參數不是選填。
  Future<void> delete(String messageId, {required String participantId}) =>
      unwrap(() => _dio.delete(
            '/api/messages/$messageId',
            options: Options(headers: {'X-Participant-Id': participantId}),
          ));
}
