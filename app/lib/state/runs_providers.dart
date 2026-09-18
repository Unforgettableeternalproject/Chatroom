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
  // **不在這裡截斷**：要看幾筆是各個畫面自己的事——側欄回報區要能往下載入
  // 更多，儀表板只要最近那幾筆。在來源截斷等於把「更多」變成做不到
  return sorted;
});

/// 側欄回報區現在打開的是哪一筆 run（`null` ＝沒有打開）。
///
/// 放在 state 層而不是卡片自己的 `setState`：面板畫在**訊息區上方**，與卡片
/// 不在同一棵子樹裡，兩邊要看同一個「現在是哪一筆」。存 id 不存 run 物件，
/// 這樣 10 秒輪詢換掉清單時面板讀到的還是最新那一份。
class SelectedRunIds extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() => const {};

  String? of(String roomId) => state[roomId];

  /// 點同一張＝收起來，點另一張＝換內容。
  void toggle(String roomId, String runId) =>
      state[roomId] == runId ? clear(roomId) : select(roomId, runId);

  void select(String roomId, String runId) =>
      state = {...state, roomId: runId};

  void clear(String roomId) {
    if (!state.containsKey(roomId)) return;
    state = {...state}..remove(roomId);
  }
}

final selectedRunIdProvider =
    NotifierProvider<SelectedRunIds, Map<String, String>>(SelectedRunIds.new);
