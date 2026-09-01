import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/board_api.dart';
import '../models/board.dart';
import 'app_providers.dart';
import 'messages_providers.dart';

/// Board 的狀態層。
///
/// **刻意全部定義在這裡而不是 `app_providers.dart`**：Board 是一整條獨立的
/// 功能線，provider 收在自己的檔案裡，這條線就不需要動到任何既有檔案。
///
/// 形狀照專案既有慣例——**非 family 的 [Notifier] 持有「房間 id → 快取」的
/// map**（同 `HighlightedMembers`），家族化的部分交給函式型 provider。
/// Riverpod 3 沒有 family 版的 AsyncNotifier 基底類別，而繞過它的寫法會
/// 讓這支檔案變成全專案唯一的特例。

final boardApiProvider = Provider((ref) => BoardApi(ref.watch(dioProvider)));

/// 每個房間的 board 快取。
///
/// 拉取一律走**增量**：帶著上次的水位問 Hub，只拿變動的那幾列
/// （見 `docs/BOARD_DESIGN.md` §5）。需求要「鼓勵 agent 經常調查 board
/// 狀態」，而每次都全量拉一整塊板會讓「經常調查」變成一件該避免的事——
/// 同一個理由對 App 一樣成立，只是吃掉的是流量而不是 context。
class BoardCache extends Notifier<Map<String, BoardSnapshot>> {
  @override
  Map<String, BoardSnapshot> build() => const {};

  BoardSnapshot snapshotOf(String roomId) =>
      state[roomId] ?? const BoardSnapshot();

  /// 套用一次增量，回傳合併後的快取。
  BoardSnapshot apply(String roomId, BoardDelta delta) {
    final merged = snapshotOf(roomId).merge(delta);
    state = {...state, roomId: merged};
    return merged;
  }

  /// 離開房間時丟掉。留著只會讓下次進來時用一個過期的水位去要增量，
  /// 而 Hub 不會回傳那段期間已經被刪掉的列——那些卡會一直在。
  void forget(String roomId) {
    if (!state.containsKey(roomId)) return;
    state = {...state}..remove(roomId);
  }
}

final boardCacheProvider =
    NotifierProvider<BoardCache, Map<String, BoardSnapshot>>(BoardCache.new);

/// 一個房間的 board。invalidate 它＝拉一次增量並合併。
///
/// 由 `/updates` 或 WebSocket 捎回的 `board_seq` 觸發：那邊只給水位，
/// 內容要自己來拿；水位沒動就不必 invalidate。
final boardProvider =
    FutureProvider.autoDispose.family<BoardSnapshot, String>((ref, roomId) async {
  // 房間是讀取邊界，board 也算房內內容 ⇒ 要房內身分。
  final pid = (await ref.watch(identityProvider(roomId).future)).participantId;
  final cache = ref.read(boardCacheProvider.notifier);
  // 這裡用 read 不用 watch：watch 自己的輸出會讓每次合併都觸發一次重拉。
  final known = cache.snapshotOf(roomId).boardSeq;
  final delta = await ref
      .watch(boardApiProvider)
      .fetch(roomId, afterBoardSeq: known, participantId: pid);
  return cache.apply(roomId, delta);
});

/// board 上的動作。每一個都在成功之後 invalidate [boardProvider]，
/// 讓變更以「Hub 說了算」的形式回到畫面上，而不是本機先猜一份。
class BoardActions {
  BoardActions(this._ref, this.roomId);

  final Ref _ref;
  final String roomId;

  BoardApi get _api => _ref.read(boardApiProvider);

  Future<String?> _pid() async =>
      (await _ref.read(identityProvider(roomId).future)).participantId;

  void _reload() => _ref.invalidate(boardProvider(roomId));

  /// 認領一張 Task。
  ///
  /// **領不到是正常結果**（別人先領走了），Hub 那端是條件式 UPDATE，併發時
  /// 本來就只有一個人會成功。呼叫端要把 409 當成一次結果而不是錯誤畫面。
  ///
  /// 回傳的 `reclaimed` 表示這張是自己上一世領走的——UI 要講出來，
  /// 領的人才知道該先去讀那張卡的描述而不是從頭開始。
  Future<BoardClaimResult?> claim(String taskId) async {
    final pid = await _pid();
    if (pid == null) return null;
    final result = await _api.claim(taskId, participantId: pid);
    _reload();
    return result;
  }

  Future<void> release(String taskId) async {
    final pid = await _pid();
    if (pid == null) return;
    await _api.release(taskId, participantId: pid);
    _reload();
  }

  /// 推 Task 的狀態。轉移不合法時丟 [ConflictException]，其 `allowed`
  /// 會說出從現在這裡還能去哪——呼叫端拿它畫按鈕，不要自己複製轉移表。
  Future<void> setTaskStatus(String taskId, String status) async {
    final pid = await _pid();
    if (pid == null) return;
    await _api.setTaskStatus(taskId, participantId: pid, status: status);
    _reload();
  }

  Future<void> completeTask(String taskId) async {
    final pid = await _pid();
    if (pid == null) return;
    await _api.completeTask(taskId, participantId: pid);
    _reload();
  }

  Future<void> completeChecklist(String checklistId) async {
    final pid = await _pid();
    if (pid == null) return;
    await _api.completeChecklist(checklistId, participantId: pid);
    _reload();
  }

  Future<String?> addObjective(String title, {String description = ''}) async {
    final pid = await _pid();
    if (pid == null) return null;
    final id = await _api.addObjective(roomId,
        participantId: pid, title: title, description: description);
    _reload();
    return id;
  }

  Future<String?> addChecklist(String objectiveId, String title,
      {String description = ''}) async {
    final pid = await _pid();
    if (pid == null) return null;
    final id = await _api.addChecklist(objectiveId,
        participantId: pid, title: title, description: description);
    _reload();
    return id;
  }

  Future<String?> addTask(
    String checklistId,
    String title, {
    String description = '',
    String priority = 'normal',
    int? sourceSeq,
    String? assigneeParticipantId,
  }) async {
    final pid = await _pid();
    if (pid == null) return null;
    final id = await _api.addTask(
      checklistId,
      participantId: pid,
      title: title,
      description: description,
      priority: priority,
      sourceSeq: sourceSeq,
      assigneeParticipantId: assigneeParticipantId,
    );
    _reload();
    return id;
  }

  /// Objective 的三段。[verify] 只有人類成員能按（Hub 回 403 `human_only`），
  /// 所以呼叫它的按鈕在 agent 的畫面上不該出現——不是按了才失敗。
  Future<void> reviewObjective(String id) async =>
      _objective(id, (api, pid) => api.reviewObjective(id, participantId: pid));

  Future<void> verifyObjective(String id) async =>
      _objective(id, (api, pid) => api.verifyObjective(id, participantId: pid));

  Future<void> completeObjective(String id) async => _objective(
      id, (api, pid) => api.completeObjective(id, participantId: pid));

  Future<void> reopenObjective(String id) async =>
      _objective(id, (api, pid) => api.reopenObjective(id, participantId: pid));

  Future<void> _objective(
      String id, Future<void> Function(BoardApi, String) run) async {
    final pid = await _pid();
    if (pid == null) return;
    await run(_api, pid);
    _reload();
  }

  Future<void> deleteTask(String taskId) async {
    final pid = await _pid();
    if (pid == null) return;
    await _api.deleteTask(taskId, participantId: pid);
    _reload();
  }
}

final boardActionsProvider = Provider.family<BoardActions, String>(
    (ref, roomId) => BoardActions(ref, roomId));

/// 這個房間有幾張孤兒 Task（持有者已經不在房裡）。
///
/// 拉成獨立 provider 是因為它要畫在**進 board 之前**看得到的地方：
/// 一張看起來有人在做、實際上沒有的卡，價值全在於有人注意到它。
final orphanedTaskCountProvider =
    Provider.autoDispose.family<int, String>((ref, roomId) {
  final snap = ref.watch(boardProvider(roomId)).value;
  if (snap == null) return 0;
  return snap.tasks.values.where((t) => t.isOrphaned).length;
});

/// 我這把 session 上一世領走、還掛在那裡的 Task。
///
/// **不自動認回**——agent 重啟多半是上一輪出事了，自動把一份它已經完全沒有
/// 記憶的工作扛回身上，board 會顯示「有人在做」而實際上沒有。
final reclaimableTasksProvider =
    Provider.autoDispose.family<List<ReclaimableTask>, String>((ref, roomId) =>
        ref.watch(boardProvider(roomId)).value?.reclaimable ?? const []);
