/// 通知中心的一則通知（`GET /api/notifications`）。
///
/// 所有欄位都給預設：Hub 之後多加的 kind 或少回的欄位不該讓整頁解析失敗。
class AppNotification {
  const AppNotification({
    required this.id,
    this.kind = '',
    this.roomId = '',
    this.roomName = '',
    this.boardId = '',
    this.boardName = '',
    this.itemKind = '',
    this.itemId = '',
    this.itemTitle = '',
    this.actorName = '',
    this.actorKind = '',
    this.reason = '',
    this.summary = '',
    this.count = 1,
    this.createdAt,
    this.updatedAt,
    this.readAt,
    this.forHost = false,
  });

  /// Hub 的整數 id，新的比舊的大。分頁游標（`before_id`）與標已讀都用它。
  final int id;

  /// 前綴分類：`watch_*`、`item_*`、`stage_*`、`scratchpad_*`、`host_*`、
  /// `run_*`。未知 kind 照 [summary] 顯示。
  final String kind;
  final String roomId;
  final String roomName;
  final String boardId;
  final String boardName;
  final String itemKind;
  final String itemId;
  final String itemTitle;
  final String actorName;

  /// `human` / `host` / `agent` / `system`。
  final String actorKind;
  final String reason;
  final String summary;

  /// 合併了幾次相同的事。`count > 1` 時 [summary] 已含「（共 N 次）」，
  /// 畫面不要再另外標一次。
  final int count;
  final String? createdAt;

  /// 最後一次更新（合併進來的新事件會更新它，id 不變）。
  final String? updatedAt;

  /// 列表顯示的時間：有更新時間就用它。
  String? get displayTime =>
      (updatedAt ?? '').isNotEmpty ? updatedAt : createdAt;
  final String? readAt;

  /// 這則是「以主持人身分收到」的。
  final bool forHost;

  bool get unread => (readAt ?? '').isEmpty;

  AppNotification withReadAt(String at) => AppNotification(
        id: id,
        kind: kind,
        roomId: roomId,
        roomName: roomName,
        boardId: boardId,
        boardName: boardName,
        itemKind: itemKind,
        itemId: itemId,
        itemTitle: itemTitle,
        actorName: actorName,
        actorKind: actorKind,
        reason: reason,
        summary: summary,
        count: count,
        createdAt: createdAt,
        updatedAt: updatedAt,
        readAt: at,
        forHost: forHost,
      );
  bool get byHost => actorKind == 'host';

  /// 點這則要去哪：有任務板就到板（任務類帶上那張卡），否則到房間；
  /// 都沒有就 null（只標已讀）。
  String? get targetRoute {
    if (boardId.isNotEmpty) {
      final task = itemKind == 'task' && itemId.isNotEmpty
          ? '?task=${Uri.encodeQueryComponent(itemId)}'
          : '';
      return '/boards/$boardId$task';
    }
    if (roomId.isNotEmpty) return '/rooms/$roomId';
    return null;
  }

  /// 來源房間／任務板的名字，有哪個印哪個。
  String get sourceLabel => [
        if (roomName.isNotEmpty) roomName,
        if (boardName.isNotEmpty) boardName,
      ].join(' · ');

  factory AppNotification.fromJson(Map<String, dynamic> json) {
    String s(String k) => (json[k] as String?) ?? '';
    final rawCount = json['count'];
    return AppNotification(
      id: _asInt(json['id']),
      kind: s('kind'),
      roomId: s('room_id'),
      roomName: s('room_name'),
      boardId: s('board_id'),
      boardName: s('board_name'),
      itemKind: s('item_kind'),
      itemId: s('item_id'),
      itemTitle: s('item_title'),
      actorName: s('actor_name'),
      actorKind: s('actor_kind'),
      reason: s('reason'),
      summary: s('summary'),
      count: rawCount is int && rawCount > 0 ? rawCount : 1,
      createdAt: json['created_at'] as String?,
      updatedAt: json['updated_at'] as String?,
      readAt: json['read_at'] as String?,
      forHost: (json['for_host'] as bool?) ?? false,
    );
  }
}

int _asInt(Object? v) => v is int ? v : int.tryParse('$v') ?? 0;

/// 一頁通知與目前的未讀總數。
class NotificationPage {
  const NotificationPage({required this.unreadCount, required this.items});

  final int unreadCount;
  final List<AppNotification> items;
}
