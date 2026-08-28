import 'package:flutter/foundation.dart';

@immutable
class Room {
  const Room({
    required this.id,
    required this.name,
    required this.topic,
    required this.status,
    required this.createdAt,
    this.memberCount = 0,
    this.lastSeq = 0,
    this.lastActivityAt,
    this.archivedAt,
  });

  final String id;
  final String name;
  final String topic;
  final String status; // active | archived
  final String createdAt;
  final int memberCount;

  /// 房間目前的最大 seq（= next_seq - 1；server list_rooms 附帶）。
  final int lastSeq;
  final String? lastActivityAt;
  final String? archivedAt;

  bool get isArchived => status == 'archived';

  factory Room.fromJson(Map<String, dynamic> json) => Room(
        id: json['id'] as String,
        name: json['name'] as String,
        topic: (json['topic'] as String?) ?? '',
        status: (json['status'] as String?) ?? 'active',
        createdAt: (json['created_at'] as String?) ?? '',
        memberCount: (json['member_count'] as int?) ?? 0,
        lastSeq: (json['last_seq'] as int?) ?? 0,
        lastActivityAt: json['last_activity_at'] as String?,
        archivedAt: json['archived_at'] as String?,
      );

  Room copyWith({String? status, int? memberCount}) => Room(
        id: id,
        name: name,
        topic: topic,
        status: status ?? this.status,
        createdAt: createdAt,
        memberCount: memberCount ?? this.memberCount,
        lastSeq: lastSeq,
        lastActivityAt: lastActivityAt,
        archivedAt: archivedAt,
      );

  @override
  bool operator ==(Object other) => other is Room && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
