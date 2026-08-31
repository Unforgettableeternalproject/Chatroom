import 'package:dio/dio.dart';

import '../models/agent_session.dart';
import '../models/assignment.dart';
import 'api_client.dart';

class AssignmentsApi {
  AssignmentsApi(this._dio);

  final Dio _dio;

  Future<String> create(
    String roomId, {
    required String targetSessionKey,
    String note = '',
    String assignedName = '',
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/rooms/$roomId/assignments',
          data: {
            'target_session_key': targetSessionKey,
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
  Future<List<AgentSession>> scanSessions({bool includeHuman = false}) =>
      unwrap(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/api/sessions',
          queryParameters: {if (includeHuman) 'include_human': true},
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
  }) =>
      unwrap(() async {
        final nonEmptyLabel = label?.isNotEmpty == true ? label : null;
        // 讀不到主機名時**不送**，而不是送空字串：Hub 的 upsert 只在非空值
        // 時覆寫，送空的等於主動把一個已知的主機名洗成未知
        final nonEmptyHost = host?.isNotEmpty == true ? host : null;
        final res = await _dio.get<Map<String, dynamic>>(
          '/api/assignments',
          queryParameters: {
            'session_key': sessionKey,
            'kind': ?kind,
            'label': ?nonEmptyLabel,
            'host': ?nonEmptyHost,
          },
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
