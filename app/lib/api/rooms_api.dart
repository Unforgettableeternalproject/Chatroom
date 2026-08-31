import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/assignment.dart';
import '../models/participant.dart';
import '../core/util/local_host.dart';
import '../models/room.dart';
import 'api_client.dart';

class RoomListResult {
  const RoomListResult({
    required this.rooms,
    this.pendingAssignments = const [],
    this.youAreHost = false,
    this.hostView = false,
  });

  final List<Room> rooms;

  /// 帶 session_key 查詢時，Hub 一併回傳指派給該 session 的 pending 邀請。
  final List<Assignment> pendingAssignments;

  /// 手上這把 token 是不是 Hub 的主 token。決定「主持人模式」開關要不要
  /// 出現——**與開關現在是開是關無關**（那是 [hostView]）。合成一個的話，
  /// 開關會在被打開之後才出現，而使用者永遠找不到它。
  final bool youAreHost;

  /// 這份列表是不是用主持人視角撈的（＝含所有人的私人房）。
  /// UI 要看得出自己正在看哪一種列表：同一份清單兩種含意而畫面長一樣，
  /// 最容易讓人把別人的私人房當成自己的。
  final bool hostView;
}

/// 按下封存之後實際發生的事。
@immutable
class ArchiveResult {
  const ArchiveResult({
    required this.archived,
    this.alreadyPending = false,
    this.request,
  });

  /// 房是不是真的封了。false 表示只是掛上一筆請求。
  final bool archived;

  /// 這個房已經有人提過了，拿回的是既有那筆。訊息要講得不一樣——
  /// 「已送出」與「已經有人提過了，還在等」是兩件事
  final bool alreadyPending;

  final ArchiveRequest? request;
}

/// 成員提出、等建立者拍板的封存請求。
///
/// **對所有成員可見**——提議者要看得到自己提的還在等，其他人才不會重複提。
/// 只有核准／婉拒的按鈕由 `youAreAdmin` 決定。
@immutable
class ArchiveRequest {
  const ArchiveRequest({
    required this.id,
    required this.requesterId,
    required this.requesterName,
    required this.reason,
    required this.status,
  });

  final String id;
  final String requesterId;
  final String requesterName;
  final String reason;

  /// pending / approved / rejected / cancelled / superseded。
  /// detail 只會回 pending 那筆，但型別不假設——狀態是 Hub 的契約。
  final String status;

  factory ArchiveRequest.fromJson(Map<String, dynamic> json) => ArchiveRequest(
        id: json['id'] as String,
        requesterId: (json['requester_id'] as String?) ?? '',
        requesterName: (json['requester_name'] as String?) ?? '',
        reason: (json['reason'] as String?) ?? '',
        status: (json['status'] as String?) ?? 'pending',
      );
}

class RoomDetail {
  const RoomDetail({
    required this.room,
    required this.participants,
    this.youAreAdmin = false,
    this.archiveRequest,
    this.limits = const ServerLimits(),
  });

  final Room room;
  final List<Participant> participants;

  /// 帶 X-Session-Key 查詢且與建立者相符時為 true（可移出成員）。
  final bool youAreAdmin;

  /// 目前掛著的封存請求，沒有就是 null。舊版 Hub 不回這個欄位——
  /// null 在兩種情況下都是「沒有待處理的提議」，UI 行為一致。
  final ArchiveRequest? archiveRequest;

  /// 伺服器實際生效的設定。UI 的倒數要以它為準——寫死一個數字的話，
  /// 伺服器改了設定就會顯示一個假的倒數，看起來像壞掉但其實只是在猜。
  final ServerLimits limits;
}

/// Hub 端實際生效的幾個門檻值。
@immutable
class ServerLimits {
  const ServerLimits({
    this.idleTimeout = const Duration(minutes: 10),
    this.archiveGrace = const Duration(seconds: 60),
    this.maxAttachmentBytes = 25 * 1024 * 1024,
  });

  final Duration idleTimeout;
  final Duration archiveGrace;
  final int maxAttachmentBytes;

  /// 舊版 Hub 不回這一段，那時就用預設值——它們是 Hub 的預設值，
  /// 猜錯的機會最小。
  factory ServerLimits.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const ServerLimits();
    double? secs(String key) => (json[key] as num?)?.toDouble();
    return ServerLimits(
      idleTimeout: Duration(
          milliseconds: ((secs('idle_timeout_seconds') ?? 600) * 1000).round()),
      archiveGrace: Duration(
          milliseconds: ((secs('archive_grace_seconds') ?? 60) * 1000).round()),
      maxAttachmentBytes:
          (json['max_attachment_bytes'] as int?) ?? 25 * 1024 * 1024,
    );
  }
}

class JoinResult {
  const JoinResult({
    required this.participantId,
    required this.displayName,
    required this.rejoined,
    this.joinMessageId,
  });
  final String participantId;
  final String displayName;
  final bool rejoined;

  /// 這次加入所產生的那則 join system 訊息 id。
  ///
  /// Hub 在**回應送出之前**就 post 了它，所以它可能已經躺在暖 feed 裡，
  /// 被「首批快照只立基準線」當成歷史吃掉——那樣同一台機器上的 agent 就
  /// 不會知道這個人進來了。有了精確的 id，client 能只補投「就是這一筆」。
  /// 冪等 rejoin 為 null（那次沒有產生新的加入訊息）。
  final String? joinMessageId;
}

class HealthResult {
  const HealthResult({required this.ok, required this.version, this.build});
  final bool ok;
  final String version;

  /// Hub 的 build 資訊（`{version, commit, built_at, source}`）。
  /// 舊版 Hub 不回這一段——那時是 null，而 null **不等於相符**。
  final Map<String, dynamic>? build;
}

class RoomsApi {
  RoomsApi(this._dio);

  final Dio _dio;

  Future<HealthResult> health() => unwrap(() async {
        final res = await _dio.get<Map<String, dynamic>>('/api/health');
        return HealthResult(
          ok: (res.data?['ok'] as bool?) ?? false,
          version: (res.data?['version'] as String?) ?? '?',
          build: res.data?['build'] as Map<String, dynamic>?,
        );
      });

  Future<RoomListResult> list({
    String status = 'active',
    String? sessionKey,
    String label = '',
  }) =>
      unwrap(() async {
        final hasKey = sessionKey != null && sessionKey.isNotEmpty;
        final res = await _dio.get<Map<String, dynamic>>(
          '/api/rooms',
          queryParameters: {
            'status': status,
            if (hasKey) 'session_key': sessionKey,
            // kind=human 讓 Hub 把我登記成人類——邀請 UI 才分得出
            // 「這是一個人」還是「這是一個 agent」
            if (hasKey) 'kind': 'human',
            if (hasKey && label.isNotEmpty) 'label': label,
            // 自報主機名：指派 UI 要靠它分出「這台機器上的 agent」
            if (hasKey && localHostName.isNotEmpty) 'host': localHostName,
          },
        );
        final rooms = ((res.data?['rooms'] as List?) ?? const [])
            .map((e) => Room.fromJson(e as Map<String, dynamic>))
            .toList();
        final pending = ((res.data?['pending_assignments'] as List?) ??
                const [])
            .map((e) => Assignment.fromJson(e as Map<String, dynamic>))
            .toList();
        return RoomListResult(
          rooms: rooms,
          pendingAssignments: pending,
          youAreHost: (res.data?['you_are_host'] as bool?) ?? false,
          hostView: (res.data?['host_view'] as bool?) ?? false,
        );
      });

  Future<Room> create({
    required String name,
    String topic = '',
    String? sessionKey,
    String visibility = 'public',
    String style = 'verbose',
    String styleInstructions = '',
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/rooms',
          data: {
            'name': name,
            'topic': topic,
            // 建立者 session：Hub 以此認定管理員
            //（可移出成員、可改鎖定狀態與說話方式）
            'session_key': ?sessionKey,
            'visibility': visibility,
            'style': style,
            'style_instructions': styleInstructions,
          },
        );
        return Room.fromJson(res.data!);
      });

  /// 鎖定／解鎖對話。只有建立者做得到。
  ///
  /// 兩個標頭都帶：建立者可能還沒加入自己的房（那時只有 session key），
  /// 也可能已經在房裡（那時 participant id 一樣過得了門檻）。
  Future<String> setVisibility(
    String roomId, {
    required String visibility,
    String? sessionKey,
    String? participantId,
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/rooms/$roomId/visibility',
          data: {'visibility': visibility},
          options: Options(headers: {
            'X-Session-Key': ?sessionKey,
            'X-Participant-Id': ?participantId,
          }),
        );
        return (res.data?['visibility'] as String?) ?? visibility;
      });

  /// 永久刪除聊天室。只有建立者做得到，**不可復原**。
  ///
  /// 回傳各表刪掉幾筆，讓 UI 有東西可以講（「刪掉了 42 則訊息」比
  /// 「已刪除」誠實得多）。
  Future<Map<String, int>> deleteRoom(
    String roomId, {
    String? sessionKey,
    String? participantId,
  }) =>
      unwrap(() async {
        final res = await _dio.delete<Map<String, dynamic>>(
          '/api/rooms/$roomId',
          options: Options(headers: {
            'X-Session-Key': ?sessionKey,
            'X-Participant-Id': ?participantId,
          }),
        );
        final raw = (res.data?['deleted'] as Map?) ?? const {};
        return raw.map((k, v) => MapEntry('$k', (v as num?)?.toInt() ?? 0));
      });

  /// 變更房內 agent 的說話方式。只有建立者做得到。
  ///
  /// 標頭與 [setVisibility] 同一套理由：建立者可能還沒加入自己的房。
  /// 回傳 Hub 實際落庫的那組值——custom 以外的風格 instructions 一律被
  /// 清成空字串，讓 UI 直接照回傳更新，不必自己複製那條規則。
  Future<({String style, String instructions})> setStyle(
    String roomId, {
    required String style,
    String instructions = '',
    String? sessionKey,
    String? participantId,
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/rooms/$roomId/style',
          data: {'style': style, 'style_instructions': instructions},
          options: Options(headers: {
            'X-Session-Key': ?sessionKey,
            'X-Participant-Id': ?participantId,
          }),
        );
        return (
          style: (res.data?['style'] as String?) ?? style,
          instructions: (res.data?['style_instructions'] as String?) ?? '',
        );
      });

  /// [participantId] 是房內身分。房間是讀取邊界——房間詳情要成員才讀得到；
  /// 建立者另可用 session key 進來（他要能看自己開的房）。舊版 Hub 忽略
  /// 這個標頭，所以帶了也能對舊 Hub 跑。
  Future<RoomDetail> detail(String roomId,
          {String? sessionKey, String? participantId}) =>
      unwrap(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/api/rooms/$roomId',
          options: Options(headers: {
            'X-Session-Key': ?sessionKey,
            'X-Participant-Id': ?participantId,
          }),
        );
        return RoomDetail(
          room: Room.fromJson(res.data!['room'] as Map<String, dynamic>),
          participants: ((res.data!['participants'] as List?) ?? const [])
              .map((e) => Participant.fromJson(e as Map<String, dynamic>))
              .toList(),
          youAreAdmin: (res.data!['you_are_admin'] as bool?) ?? false,
          archiveRequest: res.data!['archive_request'] == null
              ? null
              : ArchiveRequest.fromJson(
                  res.data!['archive_request'] as Map<String, dynamic>),
          limits: ServerLimits.fromJson(
              res.data!['server'] as Map<String, dynamic>?),
        );
      });

  /// 管理員移出成員（被移出的 session 無法重新加入該房）。
  Future<void> kick(
    String roomId, {
    required String targetId,
    required String participantId,
  }) =>
      unwrap(() => _dio.post(
            '/api/rooms/$roomId/participants/$targetId/kick',
            options: Options(headers: {'X-Participant-Id': participantId}),
          ));

  /// 手動封存。Hub 端要求**建立者或此刻仍在房裡的成員**（08-31 收緊），
  /// 所以身分標頭是必要的，不是可選的加強——不帶就是 401
  /// `participant_header_required`，而那句話講的是程式錯，會讓沒權限的人
  /// 看到一則跟自己毫無關係的訊息。
  ///
  /// 兩個標頭都帶：建立者可能還沒 join 自己的房（只有 session key），
  /// 一般成員則只有 participant id。與 [deleteRoom]／[setVisibility] 同一套。
  ///
  /// **一個入口兩種結果**：建立者按了房就封了；成員按了是提出請求。
  /// 由 [ArchiveResult.archived] 分辨——client 不自己判斷權限，那是 Hub
  /// 的事（`youAreAdmin` 決定畫面長怎樣，不決定會發生什麼）。
  Future<ArchiveResult> archive(
    String roomId, {
    String? sessionKey,
    String? participantId,
    String reason = '',
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/rooms/$roomId/archive',
          data: {'reason': reason},
          options: Options(headers: {
            'X-Session-Key': ?sessionKey,
            'X-Participant-Id': ?participantId,
          }),
        );
        final data = res.data ?? const {};
        return ArchiveResult(
          // 舊版 Hub 不回 archived，而它的行為是「直接封存」——缺值時當
          // true 才與那個行為一致。當成 false 會讓 App 顯示一則假的
          // 「已送出請求」，而房其實已經封了
          archived: (data['archived'] as bool?) ?? true,
          alreadyPending: (data['already_pending'] as bool?) ?? false,
          request: data['request'] == null
              ? null
              : ArchiveRequest.fromJson(
                  data['request'] as Map<String, dynamic>),
        );
      });

  /// Hub 主持人把一個房間的管理權收到自己身上。
  ///
  /// 與「移交」不同：那個是現任管理員交給房內的另一個人類成員，這個是
  /// 主持人**接管**——他多半不在那個房裡，而需要接管的房正是「沒有現任
  /// 管理員可以交出」的那些。
  ///
  /// [sessionKey] 是管理權要綁上去的身分（自己的 deviceKey）。Hub 不接受
  /// 省略它：管理權要綁在一把具體的身分上，不能綁在「這次請求」上。
  Future<bool> claimAdmin(
    String roomId, {
    required String sessionKey,
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/rooms/$roomId/admin/claim',
          options: Options(headers: {'X-Session-Key': sessionKey}),
        );
        // changed=false ＝ 本來就是你的。呼叫端據此決定要不要講話
        return (res.data?['changed'] as bool?) ?? true;
      });

  /// 建立者拍板：核准就封存，婉拒留紀錄。
  Future<void> resolveArchiveRequest(
    String requestId, {
    required bool approve,
    String reason = '',
    String? sessionKey,
    String? participantId,
  }) =>
      unwrap(() => _dio.post(
            '/api/archive-requests/$requestId/resolve',
            data: {'approve': approve, 'reason': reason},
            options: Options(headers: {
              'X-Session-Key': ?sessionKey,
              'X-Participant-Id': ?participantId,
            }),
          ));

  /// 提議者收回自己的提議。**限本人**——建立者要表達「不要封」是婉拒，
  /// 那會留下紀錄。
  Future<void> cancelArchiveRequest(
    String requestId, {
    required String participantId,
  }) =>
      unwrap(() => _dio.delete(
            '/api/archive-requests/$requestId',
            options: Options(headers: {'X-Participant-Id': participantId}),
          ));

  /// 解除封存。門檻比 [archive] 寬一格（不要求 active——房被封存時
  /// sweeper 已經把 agent 掃成 removed），但一樣要證明身分。
  Future<void> unarchive(
    String roomId, {
    String? sessionKey,
    String? participantId,
  }) =>
      unwrap(() => _dio.post(
            '/api/rooms/$roomId/unarchive',
            options: Options(headers: {
              'X-Session-Key': ?sessionKey,
              'X-Participant-Id': ?participantId,
            }),
          ));

  Future<JoinResult> join(
    String roomId, {
    required String kind,
    required String sessionKey,
    required String role,
    String? preferredName,
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/rooms/$roomId/join',
          data: {
            'kind': kind,
            'session_key': sessionKey,
            // ⚠️ role 不可遺漏：JoinRequest 預設 'agent'，
            // 人類漏送會在閒置 10 分鐘後被 sweeper 掃掉（P3-07 條件 5）。
            'role': role,
            if (preferredName != null && preferredName.isNotEmpty)
              'preferred_name': preferredName,
          },
        );
        return JoinResult(
          participantId: res.data!['participant_id'] as String,
          displayName: res.data!['display_name'] as String,
          rejoined: (res.data!['rejoined'] as bool?) ?? false,
          joinMessageId: res.data!['join_message_id'] as String?,
        );
      });

  Future<void> leave(String roomId, {required String participantId}) =>
      unwrap(() => _dio.post(
            '/api/rooms/$roomId/leave',
            options: Options(headers: {'X-Participant-Id': participantId}),
          ));

  Future<void> heartbeat(String roomId, {required String participantId}) =>
      unwrap(() => _dio.post(
            '/api/rooms/$roomId/heartbeat',
            options: Options(headers: {'X-Participant-Id': participantId}),
          ));
}
