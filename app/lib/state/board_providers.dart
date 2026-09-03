import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/board_api.dart';
import '../core/errors/api_exception.dart';
import '../models/board.dart';
import 'app_providers.dart';
import 'messages_providers.dart';
import 'rooms_providers.dart';

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

  /// roomId → boardId。**從回應學來的，不是問來的。**
  ///
  /// v2 起一塊 Board 可以掛在多間房，快取必須以 boardId 為 key——否則同一塊
  /// 板在兩間房裡各存一份，各自推各自的水位，看起來永遠像兩塊不同的板。
  ///
  /// 但要用 boardId 當 key，得先知道它是誰，而那件事只有 Hub 說得準。
  /// 解法是讓第一次拉取（沒有對應時走全量）自己把對應帶回來；之後就直接
  /// 以 boardId 算游標。**這樣不必為了解析多打一次 API。**
  final Map<String, String> _boardIdByRoom = {};

  String? boardIdOf(String roomId) => _boardIdByRoom[roomId];

  BoardSnapshot snapshotOf(String boardId) =>
      state[boardId] ?? const BoardSnapshot();

  /// 這個房間目前看到的板。還不知道對應時回空快照——**空快照的水位是 0，
  /// 也就是「下一次拉全量」**，正是這種情況該做的事。
  BoardSnapshot snapshotForRoom(String roomId) {
    final id = _boardIdByRoom[roomId];
    return id == null ? const BoardSnapshot() : snapshotOf(id);
  }

  /// 套用一次增量，回傳合併後的快取。
  ///
  /// [roomId] 有給時順便記下對應。舊 Hub 不回 `board_id`，那時退回以房為
  /// key——遷移期間兩種 Hub 並存，這裡不能假設一定拿得到。
  BoardSnapshot apply(String boardId, BoardDelta delta, {String? roomId}) {
    final key = delta.boardId.isNotEmpty ? delta.boardId : boardId;
    if (roomId != null && key.isNotEmpty) _boardIdByRoom[roomId] = key;
    final merged = snapshotOf(key).merge(delta);
    state = {...state, key: merged};
    return merged;
  }

  /// 丟掉一塊板的快取。留著只會讓下次用一個過期的水位去要增量，
  /// 而 Hub 不會回傳那段期間已經被刪掉的列——那些卡會一直在。
  void forget(String boardId) {
    if (!state.containsKey(boardId)) return;
    state = {...state}..remove(boardId);
  }

  /// 離開房間。
  ///
  /// ⚠️ **只解除對應，不丟板的快取**——那塊板可能還掛在別的房、或正開在
  /// Board Library 裡。跟著房一起丟掉的話，另一個畫面的水位會無聲地
  /// 倒退成 0（BOARD_DESIGN §10：離開 room 不丟 Board cache）。
  void forgetRoom(String roomId) => _boardIdByRoom.remove(roomId);
}

final boardCacheProvider =
    NotifierProvider<BoardCache, Map<String, BoardSnapshot>>(BoardCache.new);

/// WS 推來的 board 水位（這個房間的）。
///
/// 三層裡的第二層半——**只有水位，沒有內容**。[boardProvider] watch 它，
/// 數字一變就自然重建並拉增量，所以**畫面那側一行都不用改**。
///
/// ⚠️ 這條線曾經只存在於註解裡：`boardProvider` 的說明寫著「由 `/updates`
/// 或 WebSocket 捎回的 `board_seq` 觸發」，而那個觸發從來沒有被實作
/// （2026-09-01 查出，Hub 的 WS、App 的監聽、這裡的 invalidate 三層都缺）。
final boardSignalProvider =
    StreamProvider.autoDispose.family<int, String>((ref, roomId) {
  return ref
      .watch(realtimeServiceProvider)
      .boardChanged
      .where((e) => e.roomId == roomId)
      .map((e) => e.boardSeq);
});

/// 讀 board 該用哪一份身分。**規則本人在這裡，provider 只做接線。**
///
/// 回傳 `null` ＝「照常 join 拿一份新的」；非 null ＝「用本機這一份，不要
/// join」。判斷留在 provider 裡的話就只能連著整張 provider 圖一起測，而那
/// 份測試會脆到沒有人願意動它。
///
/// 封存房沒有本機身分時直接丟——那是真的讀不到，不是可以退而求其次的情況。
String? savedIdentityForBoard({required bool archived, required String? saved}) {
  if (!archived) return null;
  if (saved == null || saved.isEmpty) {
    throw const ArchivedWithoutIdentityException();
  }
  return saved;
}

/// 讀 board 用的房內身分。
///
/// 🔴 **封存房不能 join**：Hub 的 join 一開頭就 `_room_or_404`（不允許封存）
/// ⇒ 409 `room_archived`。而 [identityProvider] 無條件 join ⇒ 封存房的 board
/// 讀取必定失敗。
///
/// 但封存只禁止**寫入**，讀取端點自己寫明了「封存房照樣讀得到」。唯讀瀏覽
/// 需要的只是「我曾經是誰」，那份 id 就在本機設定裡——拿它去讀，不必也不能
/// 再 join 一次。
///
/// 沒有那份 id 表示從沒進過這個房間，封存之後也加不進去了。那是真的讀不到，
/// 錯誤要照實說，**不可以退回 join 讓它拿一個會誤導人的 409**。
final boardParticipantIdProvider =
    FutureProvider.autoDispose.family<String, String>((ref, roomId) async {
  // ⚠️ 一定要 await，**不能讀 `.value`**：房間詳情還在載入時 `.value` 是
  // null，那會把封存房判成 active 而去 join，拿一個 409 回來並被快取——
  // 也就是這個 provider 存在的理由本身。第一次進房正是它還在載入的時候
  final detail = await ref.watch(roomDetailProvider(roomId).future);
  final saved = savedIdentityForBoard(
    archived: detail.room.status == 'archived',
    saved: ref.read(settingsRepoProvider).participantId(roomId),
  );
  return saved ??
      (await ref.watch(identityProvider(roomId).future)).participantId;
});

/// 一個房間的 board。invalidate 它＝拉一次增量並合併。
final boardProvider =
    FutureProvider.autoDispose.family<BoardSnapshot, String>((ref, roomId) async {
  // WS 說板動了就重建自己 → 拉一次增量。**只 watch 水位不 watch 內容**：
  // 內容留在 GET /board 那條路上，WS 才不會變成 board 的第二個真相來源。
  //
  // 水位沒動時這個 watch 什麼都不做；自己動作之後 BoardActions 已經
  // invalidate 過一次，WS 那則隨後到會再拉一次增量——那次是空的，成本
  // 遠低於「漏掉別人的變更」。
  ref.watch(boardSignalProvider(roomId));

  // 房間是讀取邊界，board 也算房內內容 ⇒ 要房內身分。
  // 封存房走既有那份，不能 join——理由見 boardParticipantIdProvider
  final pid = await ref.watch(boardParticipantIdProvider(roomId).future);
  final cache = ref.read(boardCacheProvider.notifier);
  // 這裡用 read 不用 watch：watch 自己的輸出會讓每次合併都觸發一次重拉。
  //
  // 水位從**這個房間目前掛的那塊板**算，不是從房間算。同一塊板掛兩間房時
  // 以房為 key 會存成兩份、各推各的水位，畫面上看起來像兩塊不同的板。
  // ⚠️ `resumeFrom` 不是 `boardSeq`——手上一張卡都沒有時要從 0 要全量。
  // 差別在這裡的話症狀是**永遠空白且不報錯**（2026-09-03）
  final known = cache.snapshotForRoom(roomId).resumeFrom;
  final delta = await ref
      .watch(boardApiProvider)
      .fetch(roomId, afterBoardSeq: known, participantId: pid);
  return cache.apply(cache.boardIdOf(roomId) ?? roomId, delta, roomId: roomId);
});

/// 以 board_id 讀的板（v2 權威路徑，Board Library 與 `/boards/:id` 用）。
///
/// 與 [boardProvider] 共用同一份快取——**兩條路徑進到同一塊板時看到的必須
/// 是同一份**，否則從 Library 點進去與從房間點進去會顯示不同的水位。
final boardByIdProvider =
    FutureProvider.autoDispose.family<BoardSnapshot, String>((ref, boardId) async {
  final cache = ref.read(boardCacheProvider.notifier);
  // 外部變更要能叫醒這一頁。
  //
  // ⚠️ **這是半個解法，缺的那半在 Hub。** WS 的 board 事件是以 room 為軸
  // （`WsBoardEvent.roomId`），所以這裡只能訂閱這塊板**目前掛著的那些房**
  // ——已經知道對應之後才訂得到，而**一間房都沒掛的板完全沒有通道**。
  // 那種板從 Library 開著時，別人的變更不會推過來，畫面會停在舊快照。
  // 要真的補上需要 board_id 級的通知（審核用Codex 房內 #277 提出）。
  final watched = cache.snapshotOf(boardId).liveRooms.map((r) => r.id).toSet();
  for (final rid in watched) {
    ref.watch(boardSignalProvider(rid));
  }
  final known = cache.snapshotOf(boardId).resumeFrom;
  final delta = await ref.watch(boardsApiProvider).fetch(
        boardId,
        afterBoardSeq: known,
        sessionKey: ref.watch(appConfigProvider).deviceKey,
      );
  return cache.apply(boardId, delta);
});

/// board 上的動作。每一個都在成功之後 invalidate [boardProvider]，
/// 讓變更以「Hub 說了算」的形式回到畫面上，而不是本機先猜一份。
class BoardActions {
  /// 房軸：從某間聊天室進來，身分是那間房的 participant。
  BoardActions(this._ref, this.roomId) : boardId = null;

  /// 板軸：從 Board Library 進來，**沒有房**，身分是 session key。
  ///
  /// 這條路存在之前，`/boards/:id` 進去的板一律唯讀——判準是「你從哪條網址
  /// 進來」，跟板有沒有掛房、跟你是不是 owner 都無關。那正是艾斯維爾指出的
  /// 「Board 沒有綁房間就必定是唯讀」（2026-09-03）。
  BoardActions.forBoard(this._ref, String this.boardId) : roomId = null;

  final Ref _ref;
  final String? roomId;
  final String? boardId;

  BoardApi get _api => _ref.read(boardApiProvider);

  /// 房軸的身分。**板軸是 null，而那不是失敗**——那時身分走 [_sk]。
  Future<String?> _pid() async => roomId == null
      ? null
      : (await _ref.read(identityProvider(roomId!).future)).participantId;

  /// 板軸的身分。房軸不送，語意維持原樣（Hub 優先讀 session_key，
  /// 兩個都送會讓房軸的行為悄悄改變）。
  String? get _sk =>
      roomId == null ? _ref.read(appConfigProvider).deviceKey : null;

  /// 開得了新週期嗎。**兩條軸都可以。**
  ///
  /// ⚠️ 這個 getter 曾經回 `roomId != null`——因為以為板軸沒有建立入口。
  /// 實際上 `POST /api/boards/{bid}/objectives` 一直都在（`app.py:6042`），
  /// 那是今天第五次「以為 server 缺、其實早就有」。留著這個 getter 是為了
  /// 讓畫面仍有一個地方問這件事，不是為了擋。
  bool get canAddObjective => true;

  void _reload() => roomId != null
      ? _ref.invalidate(boardProvider(roomId!))
      : _ref.invalidate(boardByIdProvider(boardId!));

  /// 認領一張 Task。
  ///
  /// **領不到是正常結果**（別人先領走了），Hub 那端是條件式 UPDATE，併發時
  /// 本來就只有一個人會成功。呼叫端要把 409 當成一次結果而不是錯誤畫面。
  ///
  /// 回傳的 `reclaimed` 表示這張是自己上一世領走的——UI 要講出來，
  /// 領的人才知道該先去讀那張卡的描述而不是從頭開始。
  Future<BoardClaimResult?> claim(String taskId) async {
    final pid = await _pid();
    if (pid == null && _sk == null) return null;
    final result = await _api.claim(taskId, participantId: pid, sessionKey: _sk);
    _reload();
    return result;
  }

  Future<void> release(String taskId) async {
    final pid = await _pid();
    if (pid == null && _sk == null) return;
    await _api.release(taskId, participantId: pid, sessionKey: _sk);
    _reload();
  }

  /// 推 Task 的狀態。轉移不合法時丟 [ConflictException]，其 `allowed`
  /// 會說出從現在這裡還能去哪——呼叫端拿它畫按鈕，不要自己複製轉移表。
  Future<void> setTaskStatus(String taskId, String status) async {
    final pid = await _pid();
    if (pid == null && _sk == null) return;
    await _api.setTaskStatus(taskId, participantId: pid,
          sessionKey: _sk, status: status);
    _reload();
  }

  Future<void> completeTask(String taskId) async {
    final pid = await _pid();
    if (pid == null && _sk == null) return;
    await _api.completeTask(taskId, participantId: pid, sessionKey: _sk);
    _reload();
  }

  Future<void> completeChecklist(String checklistId) =>
      setChecklistStatus(checklistId, 'done');

  /// Checklist：open / done / cancelled。三態之間 Hub 都收，限制在人：
  /// 打回已完成的清單只有人類做得到，取消只有建立者或人類。
  Future<void> setChecklistStatus(String checklistId, String status) async {
    final pid = await _pid();
    if (pid == null && _sk == null) return;
    await _api.setChecklistStatus(checklistId,
        participantId: pid,
          sessionKey: _sk, status: status);
    _reload();
  }

  Future<String?> addObjective(String title, {String description = ''}) async {
    final pid = await _pid();
    if (pid == null && _sk == null) return null;
    // 兩條軸各有自己的建立端點：房軸 `/api/rooms/{rid}/board/objectives`
    // （要房內身分），板軸 `/api/boards/{bid}/objectives`（要 session key）
    final String id;
    if (roomId != null) {
      if (pid == null) return null;
      id = await _api.addObjective(roomId!,
          participantId: pid, title: title, description: description);
    } else {
      id = await _ref.read(boardsApiProvider).addObjective(
            boardId!,
            sessionKey: _sk!,
            title: title,
            description: description,
          );
    }
    _reload();
    return id;
  }

  Future<String?> addChecklist(String objectiveId, String title,
      {String description = ''}) async {
    final pid = await _pid();
    if (pid == null && _sk == null) return null;
    final id = await _api.addChecklist(objectiveId,
        participantId: pid,
          sessionKey: _sk, title: title, description: description);
    _reload();
    return id;
  }

  /// 從一則訊息記一件事。卡片會指回那則討論（[sourceSeq]），並落在
  /// 「未分類」——為了記一件事先蓋兩層，實務上的結果是根本不記。
  Future<String?> addLooseTask(
    String title, {
    String description = '',
    String priority = 'normal',
    int? sourceSeq,
  }) async {
    final pid = await _pid();
    if (pid == null && _sk == null) return null;
    if (roomId == null || pid == null) return null;
    final id = await _api.addLooseTask(
      roomId!,
      participantId: pid,
      title: title,
      description: description,
      priority: priority,
      sourceSeq: sourceSeq,
    );
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
    if (pid == null && _sk == null) return null;
    final id = await _api.addTask(
      checklistId,
      participantId: pid,
          sessionKey: _sk,
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
      _objective(id, (api, pid) => api.reviewObjective(id, participantId: pid, sessionKey: _sk));

  Future<void> verifyObjective(String id) async =>
      _objective(id, (api, pid) => api.verifyObjective(id, participantId: pid, sessionKey: _sk));

  Future<void> completeObjective(String id) async => _objective(
      id, (api, pid) => api.completeObjective(id, participantId: pid, sessionKey: _sk));

  Future<void> reopenObjective(String id) async =>
      _objective(id, (api, pid) => api.reopenObjective(id, participantId: pid, sessionKey: _sk));

  Future<void> _objective(
      String id, Future<void> Function(BoardApi, String?) run) async {
    final pid = await _pid();
    if (pid == null && _sk == null) return;
    await run(_api, pid);
    _reload();
  }

  Future<void> deleteTask(String taskId) async {
    final pid = await _pid();
    if (pid == null && _sk == null) return;
    await _api.deleteTask(taskId, participantId: pid, sessionKey: _sk);
    _reload();
  }
}

final boardActionsProvider = Provider.family<BoardActions, String>(
    (ref, roomId) => BoardActions(ref, roomId));

/// 板軸的動作（Board Library / `/boards/:id`）。與 [boardActionsProvider]
/// 是同一個類別的兩種身分來源，不是兩套邏輯。
final boardActionsByIdProvider = Provider.family<BoardActions, String>(
    (ref, boardId) => BoardActions.forBoard(ref, boardId));

/// 這個房間有幾張孤兒 Task（持有者已經不在房裡）。
///
/// 拉成獨立 provider 是因為它要畫在**進 board 之前**看得到的地方：
/// 一張看起來有人在做、實際上沒有的卡，價值全在於有人注意到它。
final orphanedTaskCountProvider =
    Provider.autoDispose.family<int, String>((ref, roomId) {
  final snap = ref.watch(boardProvider(roomId)).value;
  if (snap == null) return 0;
  // 母體是「畫面上看得到的」那些。拿整張 tasks map 的話，被取消的週期底下
  // 那些卡會永遠計進來——app bar 寫著 N 孤兒，進板一張也找不到
  return snap.visibleTasks.where((t) => t.isOrphaned).length;
});

/// 我這把 session 上一世領走、還掛在那裡的 Task。
///
/// **不自動認回**——agent 重啟多半是上一輪出事了，自動把一份它已經完全沒有
/// 記憶的工作扛回身上，board 會顯示「有人在做」而實際上沒有。
final reclaimableTasksProvider =
    Provider.autoDispose.family<List<ReclaimableTask>, String>((ref, roomId) =>
        ref.watch(boardProvider(roomId)).value?.reclaimable ?? const []);

// ─────────────────────────────────────────────────────────────────
// Board Library（v2）
// ─────────────────────────────────────────────────────────────────

final boardsApiProvider = Provider((ref) => BoardsApi(ref.watch(dioProvider)));

/// Board Library 清單，依狀態分（active / archived）。
///
/// ⚠️ **Hub 還沒有 `/api/boards` 之前這支會回 404**，畫面必須把它呈現成
/// 「這個功能還沒開」而不是一片空白——空清單與端點不存在看起來一模一樣，
/// 而那正是最難查的一種畫面。見 `boardLibraryUnavailable`。
final boardLibraryProvider =
    FutureProvider.autoDispose.family<List<BoardSummary>, String>(
  (ref, status) => ref.watch(boardsApiProvider).list(
        status: status,
        sessionKey: ref.watch(appConfigProvider).deviceKey,
      ),
);

/// 這個錯誤是不是「Hub 還沒實作 Board Library」而不是真的壞了。
///
/// 遷移期間兩種情況會同時存在於不同的 Hub，而使用者對它們該有的反應
/// 完全不同：前者是等，後者是修。
bool boardLibraryUnavailable(Object error) => error is NotFoundException;
