import 'package:flutter/foundation.dart';

/// Hub 掃描到的 agent session（GET /api/sessions）。
/// 指派畫面據此列出可指派對象，不必使用者手抄 session_key。
@immutable
class AgentSession {
  const AgentSession({
    required this.sessionKey,
    required this.kind,
    required this.label,
    required this.status,
    required this.lastSeenAt,
    required this.rooms,
    this.lastDisplayName,
  });

  final String sessionKey;
  final String kind; // claude | codex | other
  final String label; // bridge 自報的代稱，可能為空
  final String status; // active | idle
  final String lastSeenAt;

  /// 目前所在的房間（含房內顯示名稱）。
  final List<SessionRoom> rooms;

  /// 不在任何房內時，最近一次用過的房內名稱（辨識用）。
  final String? lastDisplayName;

  /// 給清單顯示的主名稱：代稱 > 房內名稱 > 歷史名稱 > key 尾碼。
  String get displayTitle {
    if (label.isNotEmpty) return label;
    if (rooms.isNotEmpty) return rooms.first.displayName;
    if (lastDisplayName != null && lastDisplayName!.isNotEmpty) {
      return lastDisplayName!;
    }
    final tail = sessionKey.length > 8
        ? sessionKey.substring(sessionKey.length - 8)
        : sessionKey;
    return '$kind-$tail';
  }

  factory AgentSession.fromJson(Map<String, dynamic> json) => AgentSession(
        sessionKey: (json['session_key'] as String?) ?? '',
        kind: (json['kind'] as String?) ?? 'other',
        label: (json['label'] as String?) ?? '',
        status: (json['status'] as String?) ?? 'idle',
        lastSeenAt: (json['last_seen_at'] as String?) ?? '',
        rooms: ((json['rooms'] as List?) ?? const [])
            .map((e) => SessionRoom.fromJson(e as Map<String, dynamic>))
            .toList(),
        lastDisplayName: json['last_display_name'] as String?,
      );
}

@immutable
class SessionRoom {
  const SessionRoom({
    required this.roomId,
    required this.roomName,
    required this.displayName,
  });

  final String roomId;
  final String roomName;
  final String displayName;

  factory SessionRoom.fromJson(Map<String, dynamic> json) => SessionRoom(
        roomId: (json['room_id'] as String?) ?? '',
        roomName: (json['room_name'] as String?) ?? '',
        displayName: (json['display_name'] as String?) ?? '',
      );
}
