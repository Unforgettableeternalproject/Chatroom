import 'package:dio/dio.dart';

import '../models/board.dart';
import 'api_client.dart';

/// Board REST。契約見 `docs/BOARD_DESIGN.md` §6。
///
/// 子資源路徑不帶 room_id（`/api/board/tasks/{id}`）是刻意的：id 是全域唯一
/// 的 uuid，room 從那一列自己查得到，讓 client 同時傳兩個只是給它一次傳錯的
/// 機會。既有的 `/api/messages/{id}/pin` 就是這個形狀。
class BoardApi {
  BoardApi(this._dio);

  final Dio _dio;

  /// 板軸的卡片操作要嘛帶房內身分、要嘛帶 session key。
  ///
  /// **兩條路都要在**：從聊天室進來的人手上有 participant_id，從 Board
  /// Library 進來的人沒有房，只有 session key。Hub 的 `_actor_from_headers`
  /// 優先讀 session_key、participant_id 當退路——所以這裡有什麼就帶什麼，
  /// 房軸照舊送 participant_id，語意不變。
  ///
  /// 少了 session key 那條的後果不是「某個動作失敗」，是**整塊板從 Library
  /// 進去只能看**——而那正是艾斯維爾指出的「Board 沒有綁房間就必定唯讀」。
  static Options _auth(String? participantId, String? sessionKey) => Options(
        headers: {
          'X-Participant-Id': ?participantId,
          'X-Session-Key': ?sessionKey,
        },
      );

  /// 讀 board。[afterBoardSeq] 為 0 時 Hub 回全量（`full: true`）。
  ///
  /// 回應含軟刪除的列（`deleted: true`）作為 tombstone，
  /// 交給 [BoardSnapshot.merge] 處理。
  Future<BoardDelta> fetch(
    String roomId, {
    int afterBoardSeq = 0,
    String? participantId,
  }) =>
      unwrap(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/api/rooms/$roomId/board',
          queryParameters: {'after_board_seq': afterBoardSeq},
          options: Options(headers: {
            'X-Participant-Id': ?participantId,
          }),
        );
        return BoardDelta.fromJson(res.data ?? const {});
      });

  Future<String> addObjective(
    String roomId, {
    String? participantId,
    String? sessionKey,
    required String title,
    String description = '',
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/rooms/$roomId/board/objectives',
          data: {'title': title, 'description': description},
          options: _auth(participantId, sessionKey),
        );
        return res.data!['id'] as String;
      });

  Future<String> addChecklist(
    String objectiveId, {
    String? participantId,
    String? sessionKey,
    required String title,
    String description = '',
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/board/objectives/$objectiveId/checklists',
          data: {'title': title, 'description': description},
          options: _auth(participantId, sessionKey),
        );
        return res.data!['id'] as String;
      });

  /// 記一件事，不指定掛在哪裡——Hub 會把「未分類」那兩層備妥再掛上去。
  ///
  /// **`sourceSeq` 是這條路徑存在的理由**：一張卡最後總會變成一句沒有上下文
  /// 的話，而決定它的討論還在聊天室裡。從一則訊息長出一張卡時，那個 seq 是
  /// 回去的路——board UI 上建的卡拿不到它，因為那裡沒有「來源訊息」這個東西。
  Future<String> addLooseTask(
    String roomId, {
    String? participantId,
    String? sessionKey,
    required String title,
    String description = '',
    String priority = 'normal',
    int? sourceSeq,
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/rooms/$roomId/board/tasks',
          data: {
            'title': title,
            'description': description,
            'priority': priority,
            'source_seq': ?sourceSeq,
          },
          options: _auth(participantId, sessionKey),
        );
        return res.data!['id'] as String;
      });

  Future<String> addTask(
    String checklistId, {
    String? participantId,
    String? sessionKey,
    required String title,
    String description = '',
    String priority = 'normal',
    int? sourceSeq,
    String? assigneeParticipantId,
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/board/checklists/$checklistId/tasks',
          data: {
            'title': title,
            'description': description,
            'priority': priority,
            'source_seq': ?sourceSeq,
            'assignee_participant_id': ?assigneeParticipantId,
          },
          options: _auth(participantId, sessionKey),
        );
        return res.data!['id'] as String;
      });

  /// 改欄位。**改不到 `status`**——狀態轉移一律走 [setTaskStatus]。
  ///
  /// Hub 的 PATCH model 是 `extra="forbid"`，多塞 `status` 會回 422 而不是
  /// 安靜忽略（那正是它該有的行為：一個欄位兩條寫入路徑，遲早有一條漏掉
  /// 守門檢查）。
  Future<void> updateTask(
    String taskId, {
    String? participantId,
    String? sessionKey,
    String? title,
    String? description,
    String? priority,
    String? assigneeParticipantId,
  }) =>
      unwrap(() async {
        await _dio.patch<Map<String, dynamic>>(
          '/api/board/tasks/$taskId',
          data: {
            'title': ?title,
            'description': ?description,
            'priority': ?priority,
            'assignee_participant_id': ?assigneeParticipantId,
          },
          options: _auth(participantId, sessionKey),
        );
      });

  /// 推 Task 的狀態（todo / in_progress / blocked / done / cancelled）。
  ///
  /// 轉移不合法時 Hub 回 409 `invalid_transition`，並在
  /// [ConflictException.allowed] 裡告訴你從現在這個狀態還能去哪——
  /// **拿它畫按鈕，不要在 App 這側複製一份轉移表**：那份副本會與 Hub 各自
  /// 演化，而畫面上多一顆按不動的按鈕不會有任何地方報錯。
  Future<void> setTaskStatus(
    String taskId, {
    String? participantId,
    String? sessionKey,
    required String status,
  }) =>
      unwrap(() async {
        await _dio.post<Map<String, dynamic>>(
          '/api/board/tasks/$taskId/status',
          data: {'status': status},
          options: _auth(participantId, sessionKey),
        );
      });

  /// 推 Checklist 的狀態（open / done / cancelled）。
  Future<void> setChecklistStatus(
    String checklistId, {
    String? participantId,
    String? sessionKey,
    required String status,
  }) =>
      unwrap(() async {
        await _dio.post<Map<String, dynamic>>(
          '/api/board/checklists/$checklistId/status',
          data: {'status': status},
          options: _auth(participantId, sessionKey),
        );
      });

  /// 認領一張 Task。
  ///
  /// ⚠️ **會失敗，而且失敗是正常結果**——Hub 端是條件式 UPDATE（CAS），
  /// 併發時只有一個人會成功，其餘拿到 409 `task_already_claimed`。
  /// 呼叫端要處理 [ApiException]，不要當成錯誤畫面。
  ///
  /// 回應的 `reclaimed` 為 true 表示這張是**自己上一世**領走的。
  Future<BoardClaimResult> claim(
    String taskId, {
    String? participantId,
    String? sessionKey,
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/board/tasks/$taskId/claim',
          options: _auth(participantId, sessionKey),
        );
        return BoardClaimResult(
          reclaimed: (res.data?['reclaimed'] as bool?) ?? false,
        );
      });

  Future<void> release(String taskId, {String? participantId, String? sessionKey}) =>
      unwrap(() async {
        await _dio.post<Map<String, dynamic>>(
          '/api/board/tasks/$taskId/release',
          options: _auth(participantId, sessionKey),
        );
      });

  /// 完成 ＝ 推到 `done`，不是另一條路徑。Hub 那側也是同一個端點——
  /// 「完成」在使用者眼裡就是改狀態，多一條路只是多一個會漏掉守門的地方。
  Future<void> completeTask(String taskId,
          {String? participantId, String? sessionKey}) =>
      setTaskStatus(taskId,
          participantId: participantId,
          sessionKey: sessionKey,
          status: 'done');

  Future<void> completeChecklist(String checklistId,
          {String? participantId, String? sessionKey}) =>
      setChecklistStatus(checklistId,
          participantId: participantId,
          sessionKey: sessionKey,
          status: 'done');

  /// Objective 的三段：送審 → 確認 → 完成。
  ///
  /// [verify] 只有人類成員能呼叫（Hub 回 403 `human_only`）——「確認無誤」
  /// 在這個專案的實際意義是跑測試、看畫面、判斷有沒有踩到坑。
  Future<void> reviewObjective(String objectiveId,
          {String? participantId, String? sessionKey}) =>
      _objectiveAction(objectiveId, 'review', participantId, sessionKey);

  Future<void> verifyObjective(String objectiveId,
          {String? participantId, String? sessionKey}) =>
      _objectiveAction(objectiveId, 'verify', participantId, sessionKey);

  Future<void> completeObjective(String objectiveId,
          {String? participantId, String? sessionKey}) =>
      _objectiveAction(objectiveId, 'complete', participantId, sessionKey);

  Future<void> reopenObjective(String objectiveId,
          {String? participantId, String? sessionKey}) =>
      _objectiveAction(objectiveId, 'reopen', participantId, sessionKey);

  Future<void> cancelObjective(String objectiveId,
          {String? participantId, String? sessionKey}) =>
      _objectiveAction(objectiveId, 'cancel', participantId, sessionKey);

  Future<void> _objectiveAction(
    String id,
    String action,
    String? pid,
    String? sessionKey,
  ) =>
      unwrap(() async {
        await _dio.post<Map<String, dynamic>>(
          '/api/board/objectives/$id/$action',
          options: _auth(pid, sessionKey),
        );
      });

  Future<void> deleteTask(String taskId, {String? participantId, String? sessionKey}) =>
      unwrap(() async {
        await _dio.delete<Map<String, dynamic>>(
          '/api/board/tasks/$taskId',
          options: _auth(participantId, sessionKey),
        );
      });

  Future<void> deleteChecklist(String id, {String? participantId, String? sessionKey}) =>
      unwrap(() async {
        await _dio.delete<Map<String, dynamic>>(
          '/api/board/checklists/$id',
          options: _auth(participantId, sessionKey),
        );
      });

  Future<void> deleteObjective(String id, {String? participantId, String? sessionKey}) =>
      unwrap(() async {
        await _dio.delete<Map<String, dynamic>>(
          '/api/board/objectives/$id',
          options: _auth(participantId, sessionKey),
        );
      });

  /// 設定或取消**這間房**的 supervisor。限房間管理者。
  ///
  /// 指的是誰用 `targetParticipantId` 講——**不是 session_key**。那個值
  /// Hub 刻意不外流（隱私），所以 UI 手上從來就沒有它：端點只收 session_key
  /// 的那段期間，這支方法沒有任何呼叫端，指派選單也就做不出來，而症狀是
  /// 「介面上沒有指派入口」，看起來像忘了做（艾斯維爾 2026-09-03）。
  ///
  /// 傳 null／空字串＝取消指派。
  Future<void> setSupervisor(
    String roomId, {
    String? participantId,
    String? sessionKey,
    String? targetParticipantId,
  }) =>
      unwrap(() async {
        await _dio.post<Map<String, dynamic>>(
          '/api/rooms/$roomId/board/supervisor',
          data: {
            'session_key': '',
            'participant_id': targetParticipantId ?? '',
          },
          options: _auth(participantId, sessionKey),
        );
      });

  /// 請這個人接手這張卡（N-4）。
  ///
  /// 🔴 **同一支端點兩種結果**：管理員（Hub 主持人／板 owner／卡所在房的
  /// 建立者）直接寫上去，其他人生出一筆待對方回應的請求。
  ///
  /// ⚠️ **不要在呼叫前自己判斷「我算不算管理員」再挑端點。** 那個判準在
  /// server，複製到 client 就是第二份會漂移的真相——而漂移的那一半沒有人
  /// 在看。按下去，看 [TaskAssignOutcome.assigned] 說發生了什麼
  /// （@開發Novia (Hub) 2026-09-04）。
  Future<TaskAssignOutcome> assignTask(
    String taskId, {
    String? participantId,
    String? sessionKey,
    /// 空字串 ＝ **取消指派**（照 `BoardSupervisorSet` 的既有慣例：
    /// 空是「卸任」，不是「這個欄位沒填」）。
    ///
    /// ⚠️ 取消是**管理動作**——一般人按下去會 403 `not_assign_admin`。
    /// 讓任何人都清得掉的話，指派等於沒有效力
    /// （@開發Novia (Hub) 2026-09-04）。
    required String targetParticipantId,
    String note = '',
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/board/tasks/$taskId/assign',
          data: {
            'target_participant_id': targetParticipantId,
            'target_session_key': '',
            'note': note,
          },
          options: _auth(participantId, sessionKey),
        );
        final d = res.data ?? const {};
        final req = d['request'] as Map<String, dynamic>?;
        return TaskAssignOutcome(
          assigned: (d['assigned'] as bool?) ?? false,
          cleared: (d['cleared'] as bool?) ?? false,
          alreadyPending: (d['already_pending'] as bool?) ?? false,
          request: req == null ? null : TaskRequest.fromJson(req),
        );
      });

  /// 回答一筆請求。**只有被指名的人答得動**——少了那道門，「需要對方
  /// 同意」等於沒有。
  Future<void> resolveTaskRequest(
    String requestId, {
    String? participantId,
    String? sessionKey,
    required bool accept,
  }) =>
      unwrap(() async {
        await _dio.post<Map<String, dynamic>>(
          '/api/board/task-requests/$requestId/resolve',
          data: {'accept': accept},
          options: _auth(participantId, sessionKey),
        );
      });
}

/// 按下「請他接手」之後**實際發生了什麼**。
///
/// 兩種結果不是錯誤與成功，是兩條都正常的路：直接指派了，或送出了一筆
/// 商量。畫面要說得出是哪一種——說錯的話，提議者會以為事情已經定了。
class TaskAssignOutcome {
  const TaskAssignOutcome({
    this.assigned = false,
    this.cleared = false,
    this.alreadyPending = false,
    this.request,
  });

  /// 直接寫到卡上了（提出者是管理員）。
  final bool assigned;

  /// 取消掉了。**`assigned` 也是 false，但那是兩件相反的事**——
  /// 只看 `assigned` 的話，取消成功會被畫成「送出了一筆請求」。
  final bool cleared;

  /// 這筆請求**早就存在**。不是失敗——同一張卡對同一個人重按，
  /// Hub 回原本那筆而不是再生一筆。
  final bool alreadyPending;

  /// 生出來（或早就存在）的那筆請求。[assigned] 為真時是 null。
  final TaskRequest? request;
}

class BoardClaimResult {
  const BoardClaimResult({this.reclaimed = false});

  /// 這張卡是同一把 session_key 上一世領走的。UI 要講出來——agent 或人
  /// 才知道該先去讀那張卡的描述，而不是從頭開始。
  final bool reclaimed;
}

/// Board Library（v2）。
///
/// 與 [BoardApi] 分開是因為它們的**軸不一樣**：BoardApi 目前以 room 為入口
/// （v2 換軸後會改成 board_id），這支從一開始就只認 board_id，沒有 room 的
/// 概念——Board Library 裡沒有 room participant 可言，Hub 直接從已認證的
/// session 解析 actor_key（`BOARD_DESIGN.md` §8）。
class BoardsApi {
  BoardsApi(this._dio);

  final Dio _dio;

  /// 在板上直接開一個週期。**板軸的建立入口**，權限看 `board_member`。
  ///
  /// 房軸那支（`/api/rooms/{rid}/board/objectives`）需要房內身分，所以從
  /// Board Library 進來的人用不了它。少了這條，Library 上開的新板要先掛
  /// 一間房才長得出第一條週期——而「先建板、之後再決定掛去哪」正是 v2
  /// 的正常路徑。
  Future<String> addObjective(
    String boardId, {
    required String sessionKey,
    required String title,
    String description = '',
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/boards/$boardId/objectives',
          data: {'title': title, 'description': description},
          options: Options(headers: {'X-Session-Key': sessionKey}),
        );
        return (res.data?['id'] as String?) ?? '';
      });

  /// 幫這塊板註冊自訂的想法板標籤。
  ///
  /// **註冊與「自由輸入」是兩件事**：註冊是一次明確的動作，之後段落仍然
  /// 從選單挑。選單內容變成「預設 ∪ 這塊板自訂的」，不是一個空白輸入框
  /// ——不然 bug／Bug／BUG／錯誤 會一起長出來，而那不會報錯，只會讓分堆
  /// 慢慢失效。
  Future<BoardTagsResult> addTags(
    String boardId, {
    required String sessionKey,
    required List<String> tags,
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/boards/$boardId/tags',
          data: {'tags': tags},
          options: Options(headers: {'X-Session-Key': sessionKey}),
        );
        return BoardTagsResult.fromJson(res.data ?? const {});
      });

  /// 撤掉一個板自訂標籤。**預設集合刪不掉**（422 `tag_is_default`）。
  ///
  /// 🔴 還有段落在用時 Hub 回 409 `tag_in_use`，並附上 `block_ids` 與
  /// `pad_ids`。那兩份清單是這個做法的重點：擋下來而已是把問題換個地方
  /// 放，**擋下來並指得出是哪幾則**才給得出出口——否則標籤用過一次就
  /// 永久鎖死。呼叫端要把它們畫出來。
  Future<BoardTagsResult> removeTag(
    String boardId,
    String tag, {
    required String sessionKey,
  }) =>
      unwrap(() async {
        final res = await _dio.delete<Map<String, dynamic>>(
          '/api/boards/$boardId/tags/${Uri.encodeComponent(tag)}',
          options: Options(headers: {'X-Session-Key': sessionKey}),
        );
        return BoardTagsResult.fromJson(res.data ?? const {});
      });

  /// Board Library 清單。
  ///
  /// [status] 為 `active` / `archived`。**Board 的封存與 room 的封存是兩件
  /// 事**：封存的房裡照樣可以寫它掛著的 Board，反過來也一樣。
  ///
  /// ⚠️ [sessionKey] 走 **`X-Session-Key` header，不是 query**。
  /// `/api/rooms` 收的是 query（`?session_key=`），照那邊複製過來會拿 400
  /// `session_key_required`，而那句話讀起來像身分壞了，其實只是放錯位置。
  /// Board Library 沒有 room participant，Hub 直接從這把 key 解析 actor_key。
  Future<BoardListResult> list({
    required String sessionKey,
    String status = 'active',
  }) =>
      unwrap(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/api/boards',
          queryParameters: {'status': status},
          options: Options(headers: {'X-Session-Key': sessionKey}),
        );
        final items = (res.data?['boards'] as List?) ?? const [];
        return BoardListResult(
          boards: items
              .map((e) => BoardSummary.fromJson(e as Map<String, dynamic>))
              .toList(),
          youAreHost: (res.data?['you_are_host'] as bool?) ?? false,
          hostView: (res.data?['host_view'] as bool?) ?? false,
        );
      });

  /// 以 board_id 讀 delta。v2 的權威路徑。
  Future<BoardDelta> fetch(
    String boardId, {
    required String sessionKey,
    int afterBoardSeq = 0,
  }) =>
      unwrap(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/api/boards/$boardId',
          queryParameters: {'after_board_seq': afterBoardSeq},
          options: Options(headers: {'X-Session-Key': sessionKey}),
        );
        return BoardDelta.fromJson(res.data ?? const {});
      });

  /// 建 Board。帶 [originRoomId] 時該房自動掛接，建立者成為 owner。
  Future<String> create({
    required String name,
    required String sessionKey,
    String? originRoomId,
    String visibility = 'public',
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/boards',
          data: {
            'name': name,
            'origin_room_id': ?originRoomId,
            'visibility': visibility,
          },
          options: Options(headers: {'X-Session-Key': sessionKey}),
        );
        return (res.data?['id'] as String?) ?? '';
      });

  /// 把一間房掛上這塊 Board。
  /// [importMembers] 把該房**當下的** active participants 加為 board editor。
  ///
  /// 「當下的」是這個設計的重點：之後才加入那間房的人**不會**自動拿到權限。
  /// 房間成員資格若能持續推導出板的寫入權，掛接一塊板就等於把它的寫入權
  /// 發給那間房未來的所有人，而那不是掛接的人做過的決定。
  ///
  /// 不覆寫既有成員的角色（已經是 owner 的不會被降成 editor）。
  /// 掛接。回傳「已經掛著了嗎」與「匯入了誰」。
  ///
  /// ⚠️ `import_members` 是 **query**，不是 body。Hub 那端的簽名是
  /// `import_members: bool = False`（FastAPI 的原始型別預設收 query），
  /// 塞進 body 的話它讀到的永遠是預設值 `false`——**不會報錯**，
  /// 只是那個核取方塊靜靜地沒有任何效果（2026-09-02）。
  Future<AttachOutcome> attachRoom(
    String boardId,
    String roomId, {
    required String sessionKey,
    bool importMembers = false,
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/boards/$boardId/rooms/$roomId',
          queryParameters: {'import_members': importMembers},
          options: Options(headers: {'X-Session-Key': sessionKey}),
        );
        return AttachOutcome.fromJson(res.data ?? const {});
      });

  /// 解除掛接。**不刪 Board 的任何資料**——重新掛接看得到原狀態。
  Future<void> detachRoom(
    String boardId,
    String roomId, {
    required String sessionKey,
  }) =>
      unwrap(() async {
        await _dio.delete<Map<String, dynamic>>(
          '/api/boards/$boardId/rooms/$roomId',
          options: Options(headers: {'X-Session-Key': sessionKey}),
        );
      });

  /// 批次排序。
  ///
  /// **整批送、整批套用**：Hub 那端有一張卡不屬於這塊板就整批退回 404，
  /// 不會套用一半。部分成功會讓 client 拿到一個它無法解讀的順序——排序
  /// 本來就是整批語意，不是 N 次獨立更新。
  ///
  /// [ids] 是**排好之後的完整順序**，index 就是 order_index。
  Future<void> reorder(
    String boardId, {
    required String sessionKey,
    required String kind,
    required List<String> ids,
  }) =>
      unwrap(() async {
        await _dio.post<Map<String, dynamic>>(
          '/api/boards/$boardId/reorder',
          data: {
            'kind': kind,
            'items': [
              for (var i = 0; i < ids.length; i++)
                {'id': ids[i], 'order_index': i},
            ],
          },
          options: Options(headers: {'X-Session-Key': sessionKey}),
        );
      });

  // 【2026-09-05 移除】`setSupervisor`（board-scoped）連同
  // `POST /api/boards/{bid}/supervisor` 一起退場（server `3a5979b`）：
  // Supervisor 一律 per-room，指派走 `BoardApi.setSupervisor`（房軸那支）。
  //
  // ⚠️ 它 docstring 裡那條「display_name／actor_kind 一定要送，Hub 當快照
  // 存不會反查」**在房軸那支仍然成立**——Supervisor 可以不是板成員、也不在
  // 任何掛接房裡，不送就沒有任何地方查得回他的名字。

  /// 送一則判斷或建議。
  ///
  /// 回傳 `delivered`：目標**不在任何掛接房**時是 false。
  /// ⚠️ **這個值一定要讓送出的人看到。** 假裝送到了，他會以為對方已經知道
  /// 了——而那是他接下來所有判斷的前提。
  /// ⚠️ 欄位名是 `target_actor_key` / `text`，**不是** `to_actor_key` /
  /// `content`（後者是 delta 回來時的名字）。送出與讀回用的不是同一組名字，
  /// 這點實測過——猜的話拿 422，而 422 的訊息會說「這些欄位不被允許」，
  /// 讀起來像是自己送錯了東西。
  ///
  /// ⚠️ [targetActorKey] **不可以是空的**：Hub 的 `min_length=1`，空字串與
  /// 不帶都是 422。delta 那側雖然有「空 = 對整塊板講」的語意，但送出這側
  /// 目前**沒有廣播**——呼叫端必須指定收件者。
  Future<bool> sendDirective(
    String boardId, {
    required String sessionKey,
    required String text,
    String? targetActorKey,
    String? itemId,
    String? itemKind,
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/boards/$boardId/directives',
          data: {
            'text': text,
            'target_actor_key': targetActorKey ?? '',
            'item_id': ?itemId,
            'item_kind': ?itemKind,
          },
          options: Options(headers: {'X-Session-Key': sessionKey}),
        );
        return (res.data?['delivered'] as bool?) ?? false;
      });

  /// 把 owner 交給別人。**限現任 owner。**
  ///
  /// owner 是這塊板唯一不靠掛接關係的權限來源（`_board_role` 開頭就認它），
  /// 所以它是「這塊板還有沒有人管得動」的最後一道保險——交接要能做，
  /// 否則換一份工作、換一個 session 就把板鎖死了。
  Future<void> transferOwner(
    String boardId, {
    required String sessionKey,
    required String targetActorKey,
  }) =>
      unwrap(() async {
        await _dio.post<Map<String, dynamic>>(
          '/api/boards/$boardId/owner',
          data: {'target_actor_key': targetActorKey},
          options: Options(headers: {'X-Session-Key': sessionKey}),
        );
      });

  /// Hub 主持人把一塊**無主**的板接管到自己身上。限主持人模式
  /// （`X-Host-View` 由 api_client 依開關自動帶）。
  ///
  /// ⚠️ owner 還活著時 Hub 回 **409 `board_has_owner`**，detail 帶
  /// `owner_display_name` 與 `owner_last_seen_at`——**那兩個欄位要顯示出來**：
  /// 「A，20 分鐘前還在」與「審核Novia，昨天之後沒再出現」會讓人做出完全
  /// 不同的決定，而只說「這塊板有 owner」兩者長得一樣。
  ///
  /// 另外，判準是「owner 那把 key 現在活不活著」⇒ **agent 的板在它離線期間
  /// 就是無主狀態**。那是這個設計的必然性質，不是缺陷。
  Future<void> claimOwner(String boardId, {required String sessionKey}) =>
      unwrap(() async {
        await _dio.post<Map<String, dynamic>>(
          '/api/boards/$boardId/owner/claim',
          options: Options(headers: {'X-Session-Key': sessionKey}),
        );
      });
}
