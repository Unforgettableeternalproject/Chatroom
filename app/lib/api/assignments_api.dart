import 'package:dio/dio.dart';

import '../models/agent_session.dart';
import '../models/assignment.dart';
import 'api_client.dart';

class AssignmentsApi {
  AssignmentsApi(this._dio);

  final Dio _dio;

  /// 兩條路擇一指定目標。
  ///
  /// [targetSessionKey] 是正典。[targetParticipantId] 給 UI 用——成員的
  /// session_key **刻意不外流**（它同時是指派目標），App 手上只有
  /// participant_id，由 Hub 內部換。沒有這條路的話，「請一個因閒置被移出
  /// 的 agent 重新加入」在畫面上根本做不出來。
  Future<String> create(
    String roomId, {
    String targetSessionKey = '',
    String targetParticipantId = '',
    String note = '',
    String assignedName = '',
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/rooms/$roomId/assignments',
          data: {
            if (targetSessionKey.isNotEmpty)
              'target_session_key': targetSessionKey,
            if (targetParticipantId.isNotEmpty)
              'target_participant_id': targetParticipantId,
            'note': note,
            'assigned_name': assignedName,
          },
        );
        return res.data!['id'] as String;
      });

  /// 掃描 Hub 見過且仍存活的 session（指派/邀請對象清單）。
  ///
  /// [includeHuman] 打開時連人類也列出來——邀請人類進房用的是同一份名錄，
  /// 因為那本來就是同一件事：把一個 session 請進一個房間。
  /// [excludeRoom] 給房間 id 時，**已經是該房 active 成員的 session 不列出**。
  /// 指派是「請一個還沒在場的人進來」——把已經在場的列進候選，使用者會指派
  /// 他一次，然後得到一個什麼都沒發生的結果（join 是冪等的），而清單本身
  /// 不表態的話那個錯誤要等指派送出去才發現。
  Future<List<AgentSession>> scanSessions({
    bool includeHuman = false,
    String excludeRoom = '',
  }) =>
      unwrap(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/api/sessions',
          queryParameters: {
            if (includeHuman) 'include_human': true,
            if (excludeRoom.isNotEmpty) 'exclude_room': excludeRoom,
          },
        );
        return ((res.data?['sessions'] as List?) ?? const [])
            .map((e) => AgentSession.fromJson(e as Map<String, dynamic>))
            .toList();
      });

  /// 房間視角的指派列表（含所有狀態，UI 檢視用）。
  ///
  /// 帶房內身分：房間是讀取邊界，指派列表也算房內內容。舊版 Hub 忽略這個
  /// 標頭，所以可以先於 Hub 升級上線。
  Future<List<Assignment>> listForRoom(String roomId,
          {String? participantId}) =>
      unwrap(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/api/rooms/$roomId/assignments',
          options: Options(headers: {'X-Participant-Id': ?participantId}),
        );
        return ((res.data?['assignments'] as List?) ?? const [])
            .map((e) => Assignment.fromJson(e as Map<String, dynamic>))
            .toList();
      });

  /// session 視角的待處理指派（含 room_name / room_topic）。
  /// session 視角的待處理指派。
  ///
  /// ⚠️ **這個呼叫有副作用**：Hub 會把這把 key 登記進 session 名錄
  /// （`_touch_session`）。那是刻意的——Codex 不會自己 join，不登記就沒有
  /// 指派目標，整條喚醒鏈是死的。
  ///
  /// 所以 [host] **要帶**：指派 UI 用它把「我這台機器上的 agent」與別人的
  /// 分開，而空的 host 會被歸進「其他裝置」（那條規則本身是對的——把別人
  /// 機器上的 agent 指派進私人房，等於把房裡的內容送出去）。不帶的話使用者
  /// 看得到自己的 agent，但在他不會展開的那一區。
  ///
  /// host 是**識別用不是授權用**：自報的值不可信，信任邊界仍然是 token。
  Future<List<Assignment>> listForSession(
    String sessionKey, {
    String? kind,
    String? label,
    String? host,
    bool labelFallback = false,
  }) =>
      unwrap(() async {
        final nonEmptyLabel = label?.isNotEmpty == true ? label : null;
        // 讀不到主機名時**不送**，而不是送空字串：Hub 的 upsert 只在非空值
        // 時覆寫，送空的等於主動把一個已知的主機名洗成未知
        final nonEmptyHost = host?.isNotEmpty == true ? host : null;
        final res = await _dio.get<Map<String, dynamic>>(
          '/api/assignments',
          queryParameters: {
            // kind／label／host 是向 session 名錄自報的資訊，不是憑證，
            // 留在 query（87ec8297 搬的只有 session_key）
            'kind': ?kind,
            'label': ?nonEmptyLabel,
            'host': ?nonEmptyHost,
            // 這個名字是不是「探索到的」。App 掃 writer lock 發現一個 thread
            // 時，它**不知道那個 agent 叫什麼**——帶著自己編的尾碼覆寫，會把
            // 使用者用 CHATROOM_DEFAULT_NAME 設好的身分每 10 秒洗掉一次
            if (labelFallback) 'label_fallback': true,
          },
          // 憑證走 header（Hub `f2f9c1e` 起 query 改選填、header 優先）
          options: Options(headers: {'X-Session-Key': sessionKey}),
        );
        return ((res.data?['assignments'] as List?) ?? const [])
            .map((e) => Assignment.fromJson(e as Map<String, dynamic>))
            .toList();
      });

  /// 指派方收回一筆還沒被處理的指派。與 [resolve] 是相反方向的動作——
  /// 那是被指派方回應，這是指派方反悔——所以狀態也分開（cancelled）。
  ///
  /// 收回是**房內的管理動作**，Hub 端要求建立者或成員身分：房主還沒 join
  /// 自己的房時只有 session key 可自報，所以兩種都送得出去。
  Future<void> cancel(
    String assignmentId, {
    required String sessionKey,
    String? participantId,
  }) =>
      unwrap(() => _dio.delete(
            '/api/assignments/$assignmentId',
            options: Options(headers: {
              'X-Session-Key': sessionKey,
              'X-Participant-Id': ?participantId,
            }),
          ));

  /// 處理一筆指派：accept=true 標為 accepted，false 標為 declined。
  ///
  /// 只有**被指派的那把 session key** 做得到（Hub 端驗）——指派是寄給一把
  /// key 的，回應它的資格也是同一把。這動作發生在進房之前，所以身分只能
  /// 用 session key 自報，沒有 participant 可用。
  Future<void> resolve(
    String assignmentId, {
    required bool accept,
    required String sessionKey,
  }) =>
      unwrap(() => _dio.post(
            '/api/assignments/$assignmentId/resolve',
            data: {'status': accept ? 'accepted' : 'declined'},
            options: Options(headers: {'X-Session-Key': sessionKey}),
          ));
}
