import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/errors/api_exception.dart';
import 'api_client.dart';

/// Hub 上「進行中」的 agent run 數量（排隊／已認領／執行中／額度受限）。
@immutable
class HubActiveRuns {
  const HubActiveRuns(this.count);

  final int count;

  bool get busy => count > 0;
}

/// 更新本機 Hub 之前，問 Hub「還有沒有進行中的 run」。
///
/// 只算 agent_run；聊天、任務板、連線都不算。
class HubActiveRunsApi {
  HubActiveRunsApi(this._dio);

  final Dio _dio;

  /// 進行中的狀態（與 Hub `_RUN_IN_PROGRESS` 一致）。
  static const statuses = ['queued', 'claimed', 'running', 'limited'];

  /// 查一次。回 `null`＝無法確認（**不是**「沒有」）。
  ///
  /// 先打新端點；舊 Hub 沒有它（404）才退回逐房查。
  Future<HubActiveRuns?> check() async {
    try {
      return await fetchGlobal();
    } on NotFoundException {
      // 舊版 Hub：沒有全域端點，逐房查
    } on Object {
      return null;
    }
    try {
      return await fetchByRooms();
    } on Object {
      return null;
    }
  }

  /// `GET /api/ops/active-runs`。
  Future<HubActiveRuns> fetchGlobal() => unwrap(() async {
        final res =
            await _dio.get<Map<String, dynamic>>('/api/ops/active-runs');
        final n = res.data?['count'];
        if (n is! int) throw const FormatException('count');
        return HubActiveRuns(n);
      });

  /// 退路：用主持人視角列出全部房（含封存），逐房查 `/runs`。
  ///
  /// Hub 沒有認出主持人視角（`host_view` 不是 true）時，列表只含看得到的房，
  /// 數出來的「0」不可信，丟例外讓呼叫端當成無法確認。
  Future<HubActiveRuns> fetchByRooms() => unwrap(() async {
        const hostHeaders = {'X-Host-View': '1'};
        final roomIds = <String>[];
        for (final status in const ['active', 'archived']) {
          final res = await _dio.get<Map<String, dynamic>>(
            '/api/rooms',
            queryParameters: {'status': status},
            options: Options(headers: hostHeaders),
          );
          if (res.data?['host_view'] != true) {
            throw const FormatException('host_view');
          }
          for (final r in (res.data?['rooms'] as List?) ?? const []) {
            roomIds.add('${(r as Map)['id']}');
          }
        }
        var total = 0;
        for (final id in roomIds) {
          final res = await _dio.get<Map<String, dynamic>>(
            '/api/rooms/$id/runs',
            queryParameters: {'status': statuses.join(',')},
            options: Options(headers: hostHeaders),
          );
          final runs = res.data?['runs'];
          if (runs is! List) throw const FormatException('runs');
          total += runs.length;
        }
        return HubActiveRuns(total);
      });
}
