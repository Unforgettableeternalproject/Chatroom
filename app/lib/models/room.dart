import 'package:flutter/foundation.dart';

@immutable
class Room {
  const Room({
    required this.id,
    required this.name,
    required this.topic,
    required this.status,
    required this.createdAt,
    this.kind = 'chat',
    this.visibility = 'public',
    this.style = 'verbose',
    this.styleInstructions = '',
    this.youAreAdmin = false,
    this.memberCount = 0,
    this.lastSeq = 0,
    this.lastActivityAt,
    this.archivedAt,
    this.workspaceKey,
    this.workspaceServed = false,
  });

  final String id;
  final String name;
  final String topic;
  final String status; // active | archived
  final String createdAt;

  /// chat（一般對話）/ ops（遠端派工的工作房，REMOTE-OPS-PLAN §4.1）。
  ///
  /// ops 房**不自動封存、不進 purge**，而且只有人類憑證建得了。
  ///
  /// 舊版 Hub 不回這個欄位——那時一律當成 `chat`，因為那正是這個欄位存在
  /// 之前所有房間的實際行為（migration 補欄的預設值也是它）。猜成 ops 會讓
  /// 升級前的每一間房都掛上「不會自動封存」的說明，而那句話是假的。
  final String kind;

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

  /// 我是不是這個房間的建立者（Hub 比對 session_key 後給的）。
  ///
  /// 列表上要顯示「刪除」這種管理員動作就得先知道這件事；建立者的
  /// session key 不會外流，所以只能由 Hub 回答。舊版 Hub 不回這個欄位，
  /// 那時一律當成不是——把必然失敗的按鈕擺出來跟不給一樣糟。
  final bool youAreAdmin;
  final int memberCount;

  /// 房間目前的最大 seq（= next_seq - 1；server list_rooms 附帶）。
  final int lastSeq;
  final String? lastActivityAt;
  final String? archivedAt;

  /// 這間工作房綁定的工作區 key。**綁了就不能改**（Hub 對第二次綁定回
  /// 409 `workspace_already_bound`），所以畫面上要先確認再送。
  ///
  /// null ＝還沒綁（也涵蓋舊版 Hub 不回這個欄位的情況）。缺鍵猜一個 key
  /// 出來的話，畫面會說「只能派工到 X」而 Hub 其實誰都收——那句話是假的。
  final String? workspaceKey;

  /// 現在有沒有執行器在服務 [workspaceKey]。
  ///
  /// 舊版 Hub 不回這個欄位一律 false：派工入口要靠它，而把入口畫出來卻
  /// 沒有人領單，等於一顆按下去只會排隊到天亮的按鈕。
  final bool workspaceServed;

  bool get isArchived => status == 'archived';

  /// 工作房。派工入口與執行儀表板只在這種房出現——Hub 對非 ops 房的建單
  /// 一律 409 `room_not_ops`，入口畫出來就是一顆必定失敗的按鈕。
  bool get isOps => kind == 'ops';

  /// 這間房現在派得出工嗎。**兩個條件缺一不可**：是工作房（非 ops 房的
  /// 建單是 409 `room_not_ops`），而且綁定的工作區現在有執行器在服務
  /// （沒綁是 409 `workspace_not_bound`，綁了沒人服務則是一筆沒有人會領
  /// 的單）。派工入口的判準只有這一份——散在各個畫面裡就是幾份會各自漂移
  /// 的真相。
  bool get canDispatchRuns => isOps && workspaceServed;

  /// 綁好了沒。空字串與 null 都是「還沒綁」——Hub 不會回空字串當 key，
  /// 但畫面不能因為多一個空白就說出「只能派工到「」」這種話。
  bool get hasWorkspace => (workspaceKey ?? '').isNotEmpty;

  bool get isPrivate => visibility == 'private';

  bool get isCustomStyle => style == 'custom';

  factory Room.fromJson(Map<String, dynamic> json) => Room(
        id: json['id'] as String,
        name: json['name'] as String,
        topic: (json['topic'] as String?) ?? '',
        status: (json['status'] as String?) ?? 'active',
        createdAt: (json['created_at'] as String?) ?? '',
        kind: (json['kind'] as String?) ?? 'chat',
        visibility: (json['visibility'] as String?) ?? 'public',
        style: (json['style'] as String?) ?? 'verbose',
        styleInstructions: (json['style_instructions'] as String?) ?? '',
        youAreAdmin: (json['you_are_admin'] as bool?) ?? false,
        memberCount: (json['member_count'] as int?) ?? 0,
        lastSeq: (json['last_seq'] as int?) ?? 0,
        lastActivityAt: json['last_activity_at'] as String?,
        archivedAt: json['archived_at'] as String?,
        workspaceKey: _workspaceKey(json['workspace_key']),
        workspaceServed: (json['workspace_served'] as bool?) ?? false,
      );

  Room copyWith({
    String? status,
    int? memberCount,
    String? visibility,
    String? style,
    String? styleInstructions,
    bool? youAreAdmin,
    String? workspaceKey,
    bool? workspaceServed,
  }) =>
      Room(
        id: id,
        name: name,
        topic: topic,
        status: status ?? this.status,
        createdAt: createdAt,
        kind: kind,
        visibility: visibility ?? this.visibility,
        style: style ?? this.style,
        styleInstructions: styleInstructions ?? this.styleInstructions,
        youAreAdmin: youAreAdmin ?? this.youAreAdmin,
        memberCount: memberCount ?? this.memberCount,
        lastSeq: lastSeq,
        lastActivityAt: lastActivityAt,
        archivedAt: archivedAt,
        workspaceKey: workspaceKey ?? this.workspaceKey,
        workspaceServed: workspaceServed ?? this.workspaceServed,
      );

  @override
  bool operator ==(Object other) => other is Room && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// 缺鍵、null 與空字串一律收成 null：只有真的綁了才算綁了。
String? _workspaceKey(dynamic v) {
  final s = v is String ? v.trim() : '';
  return s.isEmpty ? null : s;
}
