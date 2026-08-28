import 'package:flutter/foundation.dart';

@immutable
class Assignment {
  const Assignment({
    required this.id,
    required this.roomId,
    required this.targetSessionKey,
    required this.note,
    required this.status,
    required this.createdAt,
    this.resolvedAt,
  });

  final String id;
  final String roomId;
  final String targetSessionKey;
  final String note;
  final String status; // pending | accepted | declined | expired
  final String createdAt;
  final String? resolvedAt;

  factory Assignment.fromJson(Map<String, dynamic> json) => Assignment(
        id: json['id'] as String,
        roomId: (json['room_id'] as String?) ?? '',
        targetSessionKey: (json['target_session_key'] as String?) ?? '',
        note: (json['note'] as String?) ?? '',
        status: (json['status'] as String?) ?? 'pending',
        createdAt: (json['created_at'] as String?) ?? '',
        resolvedAt: json['resolved_at'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is Assignment && other.id == id && other.status == status;

  @override
  int get hashCode => Object.hash(id, status);
}
