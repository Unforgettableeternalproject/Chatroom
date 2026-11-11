import 'dart:async';

/// 主持人操作的「理由」。
///
/// 理由不逐支 API 往下傳，而是掛在 Zone 上：`runWithHostReason` 裡面發出的
/// 寫入請求（POST／PUT／PATCH／DELETE），由 `createApiDio` 的 interceptor
/// 在**主持人模式開啟**時補進 body 的 `reason`（DELETE 走 query `reason`）。
/// 非主持人模式、理由為空、GET 一律不送。
///
/// 範圍只限那一段 async 呼叫鏈：動作做完 Zone 就不在了，不會漏到下一個請求。
const Symbol _kReasonKey = #hostActionReason;

/// 在帶著 [reason] 的 Zone 裡執行 [body]。[reason] 空白就原樣執行。
Future<T> runWithHostReason<T>(String? reason, Future<T> Function() body) {
  final r = reason?.trim() ?? '';
  if (r.isEmpty) return body();
  return runZoned(body, zoneValues: {_kReasonKey: r});
}

/// 目前 Zone 帶的理由；沒有則 null。
String? currentHostReason() {
  final v = Zone.current[_kReasonKey];
  return v is String && v.isNotEmpty ? v : null;
}
