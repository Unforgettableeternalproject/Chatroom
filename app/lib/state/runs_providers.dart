import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/runs_api.dart';
import '../models/agent_run.dart';
import 'app_providers.dart';

/// 遠端派工的狀態層。
///
/// 形狀照 `board_providers` 的慣例——整條功能線收在自己的檔案裡，既有檔案
/// 不必為它改。
final runsApiProvider = Provider((ref) => RunsApi(ref.watch(dioProvider)));

/// 房間的執行儀表板。
///
/// **由畫面層週期 invalidate（10 秒）**，與指派列表同一個作法：run 的狀態
/// 變化刻意不進 `/updates` 的可觀測狀態（Hub 的註解說得很清楚：只加欄位不
/// 加返回條件＝加了一個不會被看見的欄位），所以這一格只能輪詢。
///
/// ⚠️ `autoDispose`：面板不在前景就不該繼續打。定時器也在畫面層——畫面走了
/// 定時器跟著走，而不是留一個沒有人在看的迴圈每 10 秒叫一次 Hub。
final roomRunnerBoardProvider = FutureProvider.autoDispose
    .family<RoomRunnerBoard, String>((ref, roomId) async {
  final api = ref.watch(runsApiProvider);
  final pid = ref.watch(settingsRepoProvider).participantId(roomId);
  return api.dashboard(roomId, participantId: pid);
});

/// 房內最近結束的派工（done / failed / cancelled / handoff）。
///
/// 與儀表板分開撈是因為 Hub 的 `GET /rooms/{id}/runner` 只回還在跑的那幾筆
/// ——「剛剛那筆怎麼了」在面板上沒有位置的話，人只能去訊息流裡翻。
final finishedRunsProvider =
    FutureProvider.autoDispose.family<List<AgentRun>, String>((ref, roomId) async {
  final api = ref.watch(runsApiProvider);
  final pid = ref.watch(settingsRepoProvider).participantId(roomId);
  final runs = await api.list(roomId,
      statuses: const ['done', 'failed', 'cancelled', 'handoff'],
      participantId: pid);
  // Hub 按 priority DESC + position ASC 排，對「最近結束的」不成立：
  // 位置講的是排隊順序，不是結束順序
  final sorted = [...runs]..sort((a, b) =>
      (b.endedAt ?? b.updatedAt).compareTo(a.endedAt ?? a.updatedAt));
  return sorted.take(5).toList();
});
