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
  });

  final List<Room> rooms;

  /// 帶 session_key 查詢時，Hub 一併回傳指派給該 session 的 pending 邀請。
  final List<Assignment> pendingAssignments;
}

class RoomDetail {
  const RoomDetail({
    required this.room,
    required this.participants,
    this.youAreAdmin = false,
    this.limits = const ServerLimits(),
  });

  final Room room;
  final List<Participant> participants;

  /// 帶 X-Session-Key 查詢且與建立者相符時為 true（可移出成員）。
  final bool youAreAdmin;

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
        return RoomListResult(rooms: rooms, pendingAssignments: pending);
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

  Future<void> archive(String roomId) =>
      unwrap(() => _dio.post('/api/rooms/$roomId/archive'));

  Future<void> unarchive(String roomId) =>
      unwrap(() => _dio.post('/api/rooms/$roomId/unarchive'));

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
