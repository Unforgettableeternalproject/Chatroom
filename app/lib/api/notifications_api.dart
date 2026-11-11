import 'package:dio/dio.dart';

import '../models/app_notification.dart';
import 'api_client.dart';

/// 通知中心。身分走 `X-Session-Key` 標頭（同追蹤收件匣）。
class NotificationsApi {
  NotificationsApi(this._dio);

  final Dio _dio;

  Options _h(String sessionKey) =>
      Options(headers: {'X-Session-Key': sessionKey});

  /// [beforeId] 是上一頁最後一筆的 id（整數）。
  Future<NotificationPage> list({
    required String sessionKey,
    bool unreadOnly = false,
    int limit = 30,
    int? beforeId,
  }) =>
      unwrap(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/api/notifications',
          queryParameters: {
            'unread_only': unreadOnly,
            'limit': limit,
            'before_id': ?beforeId,
          },
          options: _h(sessionKey),
        );
        final raw = res.data?['notifications'] as List<dynamic>? ?? const [];
        return NotificationPage(
          unreadCount: (res.data?['unread_count'] as int?) ?? 0,
          items: [
            for (final n in raw)
              AppNotification.fromJson(n as Map<String, dynamic>),
          ],
        );
      });

  /// 標已讀。[ids] 必須是整數（送字串 Hub 回 422）；與 [all] 擇一，
  /// 兩者都空不送請求（Hub 會回 400）。
  Future<void> markRead({
    required String sessionKey,
    List<int> ids = const [],
    bool all = false,
  }) async {
    if (!all && ids.isEmpty) return;
    await unwrap(() => _dio.post(
          '/api/notifications/read',
          data: all ? {'all': true} : {'ids': ids},
          options: _h(sessionKey),
        ));
  }
}
