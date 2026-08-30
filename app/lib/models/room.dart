import 'package:flutter/foundation.dart';

@immutable
class Room {
  const Room({
    required this.id,
    required this.name,
    required this.topic,
    required this.status,
    required this.createdAt,
    this.visibility = 'public',
    this.style = 'verbose',
    this.styleInstructions = '',
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

  /// public | private。private＝對話鎖定：Hub 不會把它列給沒份的人，
  /// 也不接受沒有邀請的加入。
  ///
  /// 舊版 Hub 不回這個欄位——那時一律當成公開，因為那正是舊 Hub 的行為。
  /// 預設成 private 會讓所有房間在升級前的畫面上莫名其妙掛上鎖頭。
  final String visibility;

  /// verbose | concise | casual | custom——房內 agent 的說話方式。
  ///
  /// 舊版 Hub 不回這個欄位，那時一律當成 verbose：那正是這個設定存在之前
  /// 的實際行為，猜成別的會讓升級前後的語氣莫名其妙變了一次。
  final String style;

  /// style == 'custom' 時建立者寫下的指示原文；其餘風格為空。
  final String styleInstructions;
  final int memberCount;

  /// 房間目前的最大 seq（= next_seq - 1；server list_rooms 附帶）。
  final int lastSeq;
  final String? lastActivityAt;
  final String? archivedAt;

  bool get isArchived => status == 'archived';

  bool get isPrivate => visibility == 'private';

  bool get isCustomStyle => style == 'custom';

  factory Room.fromJson(Map<String, dynamic> json) => Room(
        id: json['id'] as String,
        name: json['name'] as String,
        topic: (json['topic'] as String?) ?? '',
        status: (json['status'] as String?) ?? 'active',
        createdAt: (json['created_at'] as String?) ?? '',
        visibility: (json['visibility'] as String?) ?? 'public',
        style: (json['style'] as String?) ?? 'verbose',
        styleInstructions: (json['style_instructions'] as String?) ?? '',
        memberCount: (json['member_count'] as int?) ?? 0,
        lastSeq: (json['last_seq'] as int?) ?? 0,
        lastActivityAt: json['last_activity_at'] as String?,
        archivedAt: json['archived_at'] as String?,
      );

  Room copyWith({
    String? status,
    int? memberCount,
    String? visibility,
    String? style,
    String? styleInstructions,
  }) =>
      Room(
        id: id,
        name: name,
        topic: topic,
        status: status ?? this.status,
        createdAt: createdAt,
        visibility: visibility ?? this.visibility,
        style: style ?? this.style,
        styleInstructions: styleInstructions ?? this.styleInstructions,
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
