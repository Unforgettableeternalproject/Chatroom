import 'package:dio/dio.dart';

import '../models/agent_run.dart';
import 'api_client.dart';

/// 遠端派工（Remote Ops）的 REST。契約見 `docs/REMOTE-OPS-PLAN.md` §4。
///
/// 這一層**只認人類憑證那一半**：建 run、取消、下執行器命令在 Hub 都綁
/// 人類憑證（§6.4），App 本來就是人在用的。執行器那半（register／heartbeat／
/// claim／report）不在這裡——App 不是執行器，放進來只會多一組永遠拿 403
/// 的方法。
class RunsApi {
  RunsApi(this._dio);

  final Dio _dio;

  /// 房內身分。派工與取消都要 Hub 認得出「你是這間房的人類成員」。
  ///
  /// [hostView] 為 true 時**這一個請求**明示帶 `X-Host-View: 1`，不動全域的
  /// `hostViewProvider`。給的是「沒有房內身分、但確實是主機在操作自己那台」
  /// 的路徑用——Hub 端仍會驗這把 token 是不是主 token，帶了不代表過得了。
  static Options _auth(
    String? participantId, [
    String? sessionKey,
    bool hostView = false,
  ]) =>
      Options(
        headers: {
          'X-Participant-Id': ?participantId,
          'X-Session-Key': ?sessionKey,
          if (hostView) 'X-Host-View': '1',
        },
      );

  /// 建一筆派工。
  ///
  /// 會被退回的情況（`ApiException` 的 code，**契約**）：
  /// - 409 `room_not_ops`：這不是工作房。
  /// - 409 `project_not_served`：沒有執行器服務這個 project。
  /// - 409 `run_ref_already_active`：同一個目標已經有一筆還沒結束的。
  /// - 429 `run_daily_quota_exceeded` / `run_queue_cap_exceeded`：配額。
  ///   **429 不是 409**：處置是「等一下再來」，不是「換個做法」。
  Future<AgentRun> create(
    String roomId, {
    required String kind,
    required String project,
    required String ref,
    String brief = '',
    String boardId = '',
    int priority = 0,
    String? participantId,
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/rooms/$roomId/runs',
          data: {
            'kind': kind,
            'project': project,
            'ref': ref,
            'brief': brief,
            'board_id': boardId,
            'priority': priority,
          },
          options: _auth(participantId),
        );
        return AgentRun.fromJson(
            Map<String, dynamic>.from(res.data!['run'] as Map));
      });

  /// 房內的派工佇列。[statuses] 空的時候回全部。
  Future<List<AgentRun>> list(
    String roomId, {
    List<String> statuses = const [],
    String? participantId,
  }) =>
      unwrap(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/api/rooms/$roomId/runs',
          queryParameters: {
            if (statuses.isNotEmpty) 'status': statuses.join(','),
          },
          options: _auth(participantId),
        );
        return [
          for (final r in (res.data?['runs'] as List?) ?? const [])
            AgentRun.fromJson(Map<String, dynamic>.from(r as Map)),
        ];
      });

  /// 單筆派工與它的稽核串。
  Future<AgentRunDetail> get(String runId, {String? participantId}) =>
      unwrap(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/api/runs/$runId',
          options: _auth(participantId),
        );
        return AgentRunDetail.fromJson(res.data ?? const {});
      });

  /// 取消一筆派工。
  ///
  /// 回傳的布林就是 Hub 的 `cancelled`：**true ＝真的停了（queued）**，
  /// false ＝請求已送出，等執行器在下一次 heartbeat 收到再殺進程。畫面要把
  /// 這兩件事講成不同的話——說成「已取消」而機器上還在寫檔是騙人的。
  Future<bool> cancel(String runId,
          {String? participantId, String? sessionKey}) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/runs/$runId/cancel',
          options: _auth(participantId, sessionKey),
        );
        return (res.data?['cancelled'] as bool?) ?? false;
      });

  /// 請一筆派工收尾（軟停止）。
  ///
  /// 與 [cancel] 的分別是**誰來收場**：取消是執行器殺進程，收尾是讓 agent
  /// 自己把目前這一步做完、寫完收工摘要再結束。狀態一樣不動，所以畫面要講
  /// 的是「已要求收尾」——說成「已停止」而它還在寫檔是騙人的。
  Future<void> softStop(String runId,
          {String? participantId, String? sessionKey}) =>
      unwrap(() async {
        await _dio.post<Map<String, dynamic>>(
          '/api/runs/$runId/soft-stop',
          options: _auth(participantId, sessionKey),
        );
      });

  /// 房間的執行儀表板（§4.4）。輪詢的就是這一支。
  Future<RoomRunnerBoard> dashboard(String roomId, {String? participantId}) =>
      unwrap(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/api/rooms/$roomId/runner',
          options: _auth(participantId),
        );
        return RoomRunnerBoard.fromJson(res.data ?? const {});
      });

  /// 對執行器下命令：pause / resume / restart / drain / reload（§5.7）。
  ///
  /// `reload`＝重讀本機 `config.json`（執行器分頁改完設定後送），不打斷
  /// 正在跑的 run。
  ///
  /// **命令是存下來等 heartbeat 取的，不是即時推送**——按下去之後畫面要說
  /// 「已送出，執行器下次回報時生效」，不能說「已暫停」。
  ///
  /// Hub 要求這支帶 `X-Participant-Id`（且是該服務 ops 房的人類 active 成員），
  /// 缺就是 401 `participant_header_required`；唯一的豁免是主持人視角
  /// （`X-Host-View: 1` ＋ 主 token）。主機頁那條路徑沒有房內身分，所以要
  /// [hostView]＝true 明示帶標頭——**這一個請求**帶，不動全域開關。
  Future<void> command(
    String runnerId, {
    required String command,
    String roomId = '',
    String? participantId,
    String? sessionKey,
    bool hostView = false,
  }) =>
      unwrap(() async {
        await _dio.post<Map<String, dynamic>>(
          '/api/runners/$runnerId/commands',
          data: {'command': command, 'room_id': roomId},
          options: _auth(participantId, sessionKey, hostView),
        );
      });
}
