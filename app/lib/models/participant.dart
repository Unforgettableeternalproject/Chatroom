import 'package:flutter/foundation.dart';

@immutable
class Participant {
  const Participant({
    required this.id,
    required this.kind,
    required this.displayName,
    required this.role,
    required this.status,
    required this.joinedAt,
    this.lastSeenAt,
    this.sessionKey,
    this.previousName,
    this.aliasIds = const [],
    this.distinctHint,
    this.ephemeral = false,
    this.parentId,
    this.isAdmin = false,
    this.isHost = false,
  });

  final String id;
  final String kind; // claude | codex | human | other
  final String displayName;
  final String role; // agent | human
  final String status; // active | left | removed
  final String joinedAt;
  final String? lastSeenAt;

  /// GET /api/rooms/{id} 的 participants 不含 session_key（隱私縱深），
  /// 僅在部分回應存在，指派快選靠不到它時就靠本機累積。
  final String? sessionKey;

  /// 同一 session 換名重進時，Hub 附註的上一個名字（成員列表顯示「原：X」）。
  final String? previousName;

  /// 同一 session 的舊 participant id（歷史訊息的 kind 對照用）。
  final List<String> aliasIds;

  /// 房內重名時的消歧提示（人類=來源 IP、agent=session 尾碼），無重名時為 null。
  final String? distinctHint;

  /// 臨時成員（subagent）：某個 agent 派出的子代理，工作結束就會消失。
  /// 它的**存在**對所有人可見（巢狀顯示在父層底下），只有進出通知限父層。
  final bool ephemeral;

  /// 依附的父成員 id；一般成員為 null。
  final String? parentId;

  /// 這個房的建立者（管理員）。
  final bool isAdmin;

  /// Hub 的主持人：拿 `.env` 主 token 進來的那個人。
  ///
  /// 與 [isAdmin] **是兩件事**——admin 是「這個房是他開的」，host 是
  /// 「這台 Hub 是他的」。一個人可以只是其中一種，所以兩個標籤各自顯示，
  /// 不可以合併成一顆「管理員」badge。
  final bool isHost;

  bool get isActive => status == 'active';
  bool get isHuman => role == 'human';

  /// 成員列上該不該掛 HOST 標籤。
  ///
  /// **不等於 [isHost]**：agent 走 bridge，用的就是 `.env` 那把主 token，
  /// 而修正之前的 Hub 只看 token 就記 host ⇒ 資料庫裡已經有一批被標成
  /// 主持人的 agent，改 Hub 救不回那些既有的列。主持人是一個人。
  bool get showsHostBadge => isHost && isHuman;

  factory Participant.fromJson(Map<String, dynamic> json) => Participant(
        id: json['id'] as String,
        kind: (json['kind'] as String?) ?? 'other',
        displayName: (json['display_name'] as String?) ?? '?',
        role: (json['role'] as String?) ?? 'agent',
        status: (json['status'] as String?) ?? 'active',
        joinedAt: (json['joined_at'] as String?) ?? '',
        lastSeenAt: json['last_seen_at'] as String?,
        sessionKey: json['session_key'] as String?,
        previousName: json['previous_name'] as String?,
        aliasIds: ((json['alias_ids'] as List?) ?? const [])
            .map((e) => e as String)
            .toList(),
        distinctHint: json['distinct_hint'] as String?,
        // 舊 Hub 不回這兩個欄位——預設值就是「一般成員」，也就是這個功能
        // 存在之前的實際語意
        ephemeral: (json['ephemeral'] as bool?) ?? false,
        parentId: json['parent_id'] as String?,
        isAdmin: (json['is_admin'] as bool?) ?? false,
        // 舊 Hub 不回 is_host——false＝不知道。在別人的名字旁邊掛一個他
        // 沒有的身分，比留白糟得多
        isHost: (json['is_host'] as bool?) ?? false,
      );

  @override
  bool operator ==(Object other) =>
      other is Participant &&
      other.id == id &&
      other.status == status &&
      other.lastSeenAt == lastSeenAt &&
      other.parentId == parentId &&
      other.isAdmin == isAdmin &&
      other.isHost == isHost;

  @override
  int get hashCode =>
      Object.hash(id, status, lastSeenAt, parentId, isAdmin, isHost);
}
