import 'agent_run.dart';
import 'message.dart';

/// 對 system 訊息時，`createdAt` 與 run 結束時間最多差多少。
const Duration kRunSystemMatchTolerance = Duration(seconds: 60);

/// 時間窗兩端的寬限：兩邊的時間戳是不同時刻寫的（訊息寫入 vs. run 狀態轉移）。
const Duration kRunWindowSlack = Duration(seconds: 10);

/// 回報卡點下去時，訊息列表該跳去哪一則。
///
/// **Hub 沒有把 run id 蓋在訊息上**：訊息只有 `sender_id`／`sender_name`
/// 快照與 `system_event`，而 run 帶進房的成員結束後不進名冊
/// （`participant.run_id` 反查不到），所以只能用結構化欄位加時間窗對：
///
/// - **有 agent 的 run**（[AgentRun.agentName] 非 null）：該 agent 在這個房、
///   這一輪執行期間發的**最後一則 chat 訊息**。名字來自 `participant.run_id`
///   反查、訊息上的 `senderName` 是當時的快照，兩者同源；名字池會重用，所以
///   再用 `claimedAt／startedAt ~ endedAt` 的時間窗擋掉同名的舊輪次。
/// - **沒有 agent 的 run**（push 等）：房裡代表它的是
///   `_announce_run` 發的 system 訊息，`system_event` 是 `run_<狀態>`
///   （done／failed／cancelled／handoff）。同狀態可能有很多則，取
///   `createdAt` 離 run 結束時間最近的那一則，超過 [kRunSystemMatchTolerance]
///   就當對不上。
///
/// 全程**不比對內文**。回傳 seq；對不上回 null（呼叫端就只開報告、不跳）。
int? resolveRunMessageSeq(AgentRun run, Iterable<Message> messages) =>
    runIdMessageSeq(run, messages) ?? _windowMessageSeq(run, messages);

/// 以訊息上的 `run_id` 精確對應：該 run 的 agent 發言取最後一則，沒有就取
/// 該 run 的 system 訊息（最後一則）。feed 裡沒有任何帶此 run_id 的訊息回 null。
int? runIdMessageSeq(AgentRun run, Iterable<Message> messages) {
  int? chat;
  int? sys;
  for (final m in messages) {
    if (m.deleted || m.runId != run.id) continue;
    if (m.isSystem) {
      if (sys == null || m.seq > sys) sys = m.seq;
    } else if (chat == null || m.seq > chat) {
      chat = m.seq;
    }
  }
  return chat ?? sys;
}

/// 回報卡的完整解析：已載入 feed 的 `run_id` → Hub 的 `last_message`
/// → 時間窗比對。任何一步失敗都往下退；全都對不上回 null（呼叫端安靜）。
///
/// [fetchLastSeq] 丟任何例外（404 `run_message_not_found`、舊版 Hub 沒有此
/// endpoint、網路）都視為「Hub 答不出來」。
Future<int?> resolveRunMessageSeqRemote(
  AgentRun run,
  Iterable<Message> messages, {
  required Future<int> Function(String runId) fetchLastSeq,
}) async {
  final exact = runIdMessageSeq(run, messages);
  if (exact != null) return exact;
  try {
    return await fetchLastSeq(run.id);
  } catch (_) {
    return _windowMessageSeq(run, messages);
  }
}

int? _windowMessageSeq(AgentRun run, Iterable<Message> messages) {
  final end = _t(run.endedAt) ?? _t(run.updatedAt);
  final name = run.agentName;
  if (name != null && name.isNotEmpty) {
    final start = _t(run.claimedAt) ?? _t(run.startedAt) ?? _t(run.createdAt);
    int? best;
    for (final m in messages) {
      if (m.isSystem || m.deleted || m.senderName != name) continue;
      final at = _t(m.createdAt);
      if (at == null) continue;
      if (start != null && at.isBefore(start.subtract(kRunWindowSlack))) {
        continue;
      }
      if (end != null && at.isAfter(end.add(kRunWindowSlack))) continue;
      if (best == null || m.seq > best) best = m.seq;
    }
    return best;
  }

  if (end == null) return null;
  final event = 'run_${run.status}';
  int? best;
  Duration? bestGap;
  for (final m in messages) {
    if (!m.isSystem || m.deleted || m.systemEvent != event) continue;
    final at = _t(m.createdAt);
    if (at == null) continue;
    final gap = at.difference(end).abs();
    if (gap > kRunSystemMatchTolerance) continue;
    if (bestGap == null || gap < bestGap) {
      best = m.seq;
      bestGap = gap;
    }
  }
  return best;
}

/// 這一輪的時間窗起點；用來判斷「已載入的訊息有沒有涵蓋到這一輪」。
DateTime? runWindowStart(AgentRun run) =>
    _t(run.claimedAt) ??
    _t(run.startedAt) ??
    _t(run.createdAt) ??
    _t(run.endedAt) ??
    _t(run.updatedAt);

DateTime? _t(String? iso) =>
    (iso == null || iso.isEmpty) ? null : DateTime.tryParse(iso)?.toUtc();
