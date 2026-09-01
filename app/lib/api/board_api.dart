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
    required String participantId,
    required String title,
    String description = '',
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/rooms/$roomId/board/objectives',
          data: {'title': title, 'description': description},
          options: Options(headers: {'X-Participant-Id': participantId}),
        );
        return res.data!['id'] as String;
      });

  Future<String> addChecklist(
    String objectiveId, {
    required String participantId,
    required String title,
    String description = '',
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/board/objectives/$objectiveId/checklists',
          data: {'title': title, 'description': description},
          options: Options(headers: {'X-Participant-Id': participantId}),
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
    required String participantId,
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
          options: Options(headers: {'X-Participant-Id': participantId}),
        );
        return res.data!['id'] as String;
      });

  Future<String> addTask(
    String checklistId, {
    required String participantId,
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
          options: Options(headers: {'X-Participant-Id': participantId}),
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
    required String participantId,
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
          options: Options(headers: {'X-Participant-Id': participantId}),
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
    required String participantId,
    required String status,
  }) =>
      unwrap(() async {
        await _dio.post<Map<String, dynamic>>(
          '/api/board/tasks/$taskId/status',
          data: {'status': status},
          options: Options(headers: {'X-Participant-Id': participantId}),
        );
      });

  /// 推 Checklist 的狀態（open / done / cancelled）。
  Future<void> setChecklistStatus(
    String checklistId, {
    required String participantId,
    required String status,
  }) =>
      unwrap(() async {
        await _dio.post<Map<String, dynamic>>(
          '/api/board/checklists/$checklistId/status',
          data: {'status': status},
          options: Options(headers: {'X-Participant-Id': participantId}),
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
    required String participantId,
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/board/tasks/$taskId/claim',
          options: Options(headers: {'X-Participant-Id': participantId}),
        );
        return BoardClaimResult(
          reclaimed: (res.data?['reclaimed'] as bool?) ?? false,
        );
      });

  Future<void> release(String taskId, {required String participantId}) =>
      unwrap(() async {
        await _dio.post<Map<String, dynamic>>(
          '/api/board/tasks/$taskId/release',
          options: Options(headers: {'X-Participant-Id': participantId}),
        );
      });

  /// 完成 ＝ 推到 `done`，不是另一條路徑。Hub 那側也是同一個端點——
  /// 「完成」在使用者眼裡就是改狀態，多一條路只是多一個會漏掉守門的地方。
  Future<void> completeTask(String taskId,
          {required String participantId}) =>
      setTaskStatus(taskId, participantId: participantId, status: 'done');

  Future<void> completeChecklist(String checklistId,
          {required String participantId}) =>
      setChecklistStatus(checklistId,
          participantId: participantId, status: 'done');

  /// Objective 的三段：送審 → 確認 → 完成。
  ///
  /// [verify] 只有人類成員能呼叫（Hub 回 403 `human_only`）——「確認無誤」
  /// 在這個專案的實際意義是跑測試、看畫面、判斷有沒有踩到坑。
  Future<void> reviewObjective(String objectiveId,
          {required String participantId}) =>
      _objectiveAction(objectiveId, 'review', participantId);

  Future<void> verifyObjective(String objectiveId,
          {required String participantId}) =>
      _objectiveAction(objectiveId, 'verify', participantId);

  Future<void> completeObjective(String objectiveId,
          {required String participantId}) =>
      _objectiveAction(objectiveId, 'complete', participantId);

  Future<void> reopenObjective(String objectiveId,
          {required String participantId}) =>
      _objectiveAction(objectiveId, 'reopen', participantId);

  Future<void> cancelObjective(String objectiveId,
          {required String participantId}) =>
      _objectiveAction(objectiveId, 'cancel', participantId);

  Future<void> _objectiveAction(String id, String action, String pid) =>
      unwrap(() async {
        await _dio.post<Map<String, dynamic>>(
          '/api/board/objectives/$id/$action',
          options: Options(headers: {'X-Participant-Id': pid}),
        );
      });

  Future<void> deleteTask(String taskId, {required String participantId}) =>
      unwrap(() async {
        await _dio.delete<Map<String, dynamic>>(
          '/api/board/tasks/$taskId',
          options: Options(headers: {'X-Participant-Id': participantId}),
        );
      });

  Future<void> deleteChecklist(String id, {required String participantId}) =>
      unwrap(() async {
        await _dio.delete<Map<String, dynamic>>(
          '/api/board/checklists/$id',
          options: Options(headers: {'X-Participant-Id': participantId}),
        );
      });

  Future<void> deleteObjective(String id, {required String participantId}) =>
      unwrap(() async {
        await _dio.delete<Map<String, dynamic>>(
          '/api/board/objectives/$id',
          options: Options(headers: {'X-Participant-Id': participantId}),
        );
      });

  /// 設定或取消（傳空字串）Board 的 supervisor。限房間建立者。
  Future<void> setSupervisor(
    String roomId, {
    required String participantId,
    required String sessionKey,
  }) =>
      unwrap(() async {
        await _dio.post<Map<String, dynamic>>(
          '/api/rooms/$roomId/board/supervisor',
          data: {'session_key': sessionKey},
          options: Options(headers: {'X-Participant-Id': participantId}),
        );
      });
}

class BoardClaimResult {
  const BoardClaimResult({this.reclaimed = false});

  /// 這張卡是同一把 session_key 上一世領走的。UI 要講出來——agent 或人
  /// 才知道該先去讀那張卡的描述，而不是從頭開始。
  final bool reclaimed;
}
