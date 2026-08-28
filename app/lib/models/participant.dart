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

  bool get isActive => status == 'active';
  bool get isHuman => role == 'human';

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
      );

  @override
  bool operator ==(Object other) =>
      other is Participant &&
      other.id == id &&
      other.status == status &&
      other.lastSeenAt == lastSeenAt;

  @override
  int get hashCode => Object.hash(id, status, lastSeenAt);
}
