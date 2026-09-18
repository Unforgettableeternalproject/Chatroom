import 'package:dio/dio.dart';

import '../models/ops_exception.dart';
import 'api_client.dart';

/// 監控器：跨房的派工例外彙總。
///
/// **不放進 `RunsApi`**：那一層的每一支都以房為單位（`roomId` 必填），
/// 而這支的重點正是「我的哪一間房出事了」——跨房。
class OpsExceptionsApi {
  OpsExceptionsApi(this._dio);

  final Dio _dio;

  /// 撈例外。[since] 是上一次拿到的 `next_since`（事件 id 或時間都吃）。
  ///
  /// ⚠️ 憑證走 `X-Session-Key`：Hub 用它判定「這個人看得到哪些房」，
  /// 不帶的話只剩公開房——而工作房多半是私人的，畫面上會變成一片空白，
  /// 且與「現在沒有例外」長得一模一樣。
  Future<OpsExceptionPage> list({
    required String sessionKey,
    String since = '',
    int limit = 50,
  }) =>
      unwrap(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/api/ops/exceptions',
          queryParameters: {
            if (since.isNotEmpty) 'since': since,
            'limit': limit,
          },
          options: Options(headers: {'X-Session-Key': sessionKey}),
        );
        return OpsExceptionPage.fromJson(res.data ?? const {});
      });
}
