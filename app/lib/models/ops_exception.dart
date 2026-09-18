import 'package:flutter/foundation.dart';

/// 監控器的一筆派工例外（Hub `GET /api/ops/exceptions`）。
///
/// ⚠️ 這份清單是**四類已知例外**，不是「所有派工例外」：
/// 停滯／恢復、逾時、額度受限、執行器上下線。hook 擋下的工具呼叫與 MCP
/// 伺服器沒接上目前完全沒有事件源（執行器只在本機 log 擋下，不回寫 Hub），
/// 面板的文案要講得出這個範圍——看起來像全量覆蓋的清單，會讓人根據一份
/// 不完整的資料判斷「今天沒出事」。
@immutable
class OpsException {
  const OpsException({
    required this.id,
    required this.kind,
    required this.reason,
    required this.severity,
    required this.roomId,
    required this.roomName,
    required this.runId,
    required this.runKind,
    required this.runRef,
    required this.runnerId,
    required this.detail,
    required this.createdAt,
  });

  /// 事件 id（`agent_run_event.id` 或 `runner_event.id`）。本機游標記的是它。
  final String id;

  /// 分類：stalled / resumed / timeout / rate_limited /
  /// runner_offline / runner_online。**認這個不認 reason 字串**——reason 是
  /// 執行器講的原話（`wall_clock`、`rate_limit_backoff_30m`），會長出新的。
  final String kind;

  /// 原始 reason。畫在細節裡，讓人查得出是哪一條路徑。
  final String reason;

  /// warn / error / info。
  final String severity;

  final String roomId;
  final String roomName;

  /// 執行器上下線沒有對應的 run，此時是空字串。
  final String runId;
  final String runKind;
  final String runRef;
  final String runnerId;

  /// 事件的附加欄位（`stalled_seconds`、執行器的 `label` 等）。
  final Map<String, dynamic> detail;

  final String createdAt;

  bool get isError => severity == 'error';

  /// 要推系統通知的那幾種：已經需要人介入的。停滯／額度受限**不推**——
  /// 它們是已知會自動恢復的暫時狀態，推播只會製造疲勞。
  bool get notifiable => kind == 'runner_offline' || kind == 'timeout';

  /// 執行器的顯示名（掉線事件帶 label）；沒有就退回 id 尾碼。
  String get runnerLabel {
    final label = detail['label'];
    if (label is String && label.isNotEmpty) return label;
    if (runnerId.length > 8) return runnerId.substring(runnerId.length - 8);
    return runnerId;
  }

  /// 面板上的一句話。**中文在這裡生成，不從 Hub 拿**：Hub 回的是機器可讀
  /// 的分類，文案改一個字不該要求 Hub 一起改版。
  String get title {
    final target = runRef.isEmpty ? '(未指定)' : runRef;
    final head = runKind.isEmpty ? '派工' : '派工 $runKind／$target';
    switch (kind) {
      case 'stalled':
        final secs = detail['stalled_seconds'];
        return secs is int && secs > 0
            ? '$head 已 $secs 秒沒有輸出'
            : '$head 停滯';
      case 'resumed':
        return '$head 已恢復輸出';
      case 'timeout':
        return reason == 'soft_stop_timeout'
            ? '$head 收尾逾時，被強制終止'
            : '$head 逾時，被強制終止';
      case 'rate_limited':
        return '$head 受額度限制（$reason）';
      case 'runner_offline':
        return '執行器 $runnerLabel 已離線';
      case 'runner_online':
        return '執行器 $runnerLabel 已恢復連線';
      default:
        return '$head $reason';
    }
  }

  static OpsException fromJson(Map<String, dynamic> j) => OpsException(
        id: (j['id'] as String?) ?? '',
        kind: (j['kind'] as String?) ?? '',
        reason: (j['reason'] as String?) ?? '',
        severity: (j['severity'] as String?) ?? 'warn',
        roomId: (j['room_id'] as String?) ?? '',
        roomName: (j['room_name'] as String?) ?? '',
        runId: (j['run_id'] as String?) ?? '',
        runKind: (j['run_kind'] as String?) ?? '',
        runRef: (j['run_ref'] as String?) ?? '',
        runnerId: (j['runner_id'] as String?) ?? '',
        detail: j['detail'] is Map
            ? Map<String, dynamic>.from(j['detail'] as Map)
            : const {},
        createdAt: (j['created_at'] as String?) ?? '',
      );
}

/// 一次查詢的結果：清單 + 下一次的游標。
@immutable
class OpsExceptionPage {
  const OpsExceptionPage({required this.exceptions, required this.nextSince});

  final List<OpsException> exceptions;

  /// 下一次輪詢帶回去的游標。**空清單時 Hub 原樣回上一個游標**，
  /// 不是空字串——否則沒有新事件的那一輪會讓 client 退回從頭讀。
  final String nextSince;

  static OpsExceptionPage fromJson(Map<String, dynamic> j) => OpsExceptionPage(
        exceptions: [
          for (final e in (j['exceptions'] as List?) ?? const [])
            OpsException.fromJson(Map<String, dynamic>.from(e as Map)),
        ],
        nextSince: (j['next_since'] as String?) ?? '',
      );
}
