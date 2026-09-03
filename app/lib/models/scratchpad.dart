import 'package:flutter/foundation.dart';

/// 想法板：**一串有 id 的段落**，不是一份自由文字。
///
/// 那個形狀是被「agent 不得改寫人類的段落，只能註解」逼出來的
/// （艾斯維爾 2026-09-02）：作者身分要落在段落層級，否則「人類的段落」
/// 在資料上不存在，守門就實作不出來。
///
/// ⚠️ **不要為了方便把它攤成一個 textarea。** 人在自由文字裡會併段、拆段、
/// 調換、刪行，存回去時段落與 id 的對應已經不存在，只能重新推斷——而任何
/// 推斷都是猜的。猜錯的結果是某段的作者從人類變成 agent，**那正好解除它的
/// 保護**，且沒有任何一端會報錯。

/// 掛在某個段落上的註解。agent 對人類段落唯一能做的事。
@immutable
class ScratchpadNote {
  const ScratchpadNote({
    required this.id,
    this.blockId = '',
    this.content = '',
    this.authorName = '',
    this.authorActorKey = '',
    this.authorKind = '',
    this.resolvedAt,
    this.createdAt,
  });

  final String id;
  final String blockId;
  final String content;
  final String authorName;
  final String authorActorKey;
  final String authorKind;
  final String? resolvedAt;
  final String? createdAt;

  bool get resolved => (resolvedAt ?? '').isNotEmpty;

  factory ScratchpadNote.fromJson(Map<String, dynamic> json) => ScratchpadNote(
    id: (json['id'] as String?) ?? '',
    blockId: (json['block_id'] as String?) ?? '',
    content: (json['content'] as String?) ?? '',
    authorName: (json['author_name'] as String?) ?? '',
    authorActorKey: (json['author_actor_key'] as String?) ?? '',
    authorKind: (json['author_kind'] as String?) ?? '',
    resolvedAt: json['resolved_at'] as String?,
    createdAt: json['created_at'] as String?,
  );
}

/// 一個段落。
@immutable
class ScratchpadBlock {
  const ScratchpadBlock({
    required this.id,
    this.content = '',
    this.orderIndex = 0,
    this.rev = 1,
    this.authorActorKey = '',
    this.authorName = '',
    this.authorKind = '',
    this.canEdit = false,
    this.notes = const [],
    this.updatedAt,
  });

  final String id;
  final String content;
  final int orderIndex;

  /// 寫回去時要帶它。**跟內容一起回來**是刻意的——分兩支 API 拿的話，
  /// 中間那段時間就是一個看不見的競態窗口。
  final int rev;

  final String authorActorKey;
  final String authorName;
  final String authorKind;

  /// ⚠️ **伺服器算好的守門結果，不要自己推斷。** client 自己算的話兩邊的
  /// 規則會漂移，而漂移的那一半沒有人在看：畫面給了編輯框、送出時 403。
  final bool canEdit;

  final List<ScratchpadNote> notes;
  final String? updatedAt;

  bool get isHuman => authorKind == 'human';

  List<ScratchpadNote> get openNotes => [
    for (final n in notes)
      if (!n.resolved) n,
  ];

  factory ScratchpadBlock.fromJson(Map<String, dynamic> json) =>
      ScratchpadBlock(
        id: (json['id'] as String?) ?? '',
        content: (json['content'] as String?) ?? '',
        orderIndex: (json['order_index'] as int?) ?? 0,
        rev: (json['rev'] as int?) ?? 1,
        authorActorKey: (json['author_actor_key'] as String?) ?? '',
        authorName: (json['author_name'] as String?) ?? '',
        authorKind: (json['author_kind'] as String?) ?? '',
        canEdit: (json['can_edit'] as bool?) ?? false,
        updatedAt: json['updated_at'] as String?,
        notes: [
          for (final n in (json['notes'] as List<dynamic>? ?? const []))
            ScratchpadNote.fromJson(n as Map<String, dynamic>),
        ],
      );
}

/// 清單上的一張卡。**不含內容**——清單只需要知道有哪些。
@immutable
class ScratchpadSummary {
  const ScratchpadSummary({
    required this.id,
    this.title = '',
    this.rev = 1,
    this.blockCount = 0,
    this.unresolvedNotes = 0,
    this.updatedByName = '',
    this.updatedAt,
  });

  final String id;
  final String title;
  final int rev;
  final int blockCount;

  /// 還沒處理的註解數。**這個數字是唯一能讓人知道「有人對你的段落提了
  /// 意見」的線索**——不放在清單上的話，只能一份一份打開去發現，
  /// 而沒有人會那樣做。
  final int unresolvedNotes;

  final String updatedByName;
  final String? updatedAt;

  factory ScratchpadSummary.fromJson(Map<String, dynamic> json) =>
      ScratchpadSummary(
        id: (json['id'] as String?) ?? '',
        title: (json['title'] as String?) ?? '',
        rev: (json['rev'] as int?) ?? 1,
        blockCount: (json['block_count'] as int?) ?? 0,
        unresolvedNotes: (json['unresolved_notes'] as int?) ?? 0,
        updatedByName: (json['updated_by_name'] as String?) ?? '',
        updatedAt: json['updated_at'] as String?,
      );
}

/// 一份想法板的全文。
@immutable
class Scratchpad {
  const Scratchpad({
    required this.id,
    this.boardId = '',
    this.title = '',
    this.rev = 1,
    this.blocks = const [],
    this.canEdit = false,
  });

  final String id;
  final String boardId;
  final String title;

  /// **結構**的版本（段落的增刪與順序），不是某一段內容的版本。
  /// 重排與新增帶它，改某一段帶那一段自己的 `rev`。
  final int rev;

  final List<ScratchpadBlock> blocks;
  final bool canEdit;

  ScratchpadBlock? blockOf(String id) {
    for (final b in blocks) {
      if (b.id == id) return b;
    }
    return null;
  }

  factory Scratchpad.fromJson(Map<String, dynamic> json) => Scratchpad(
    id: (json['id'] as String?) ?? '',
    boardId: (json['board_id'] as String?) ?? '',
    title: (json['title'] as String?) ?? '',
    rev: (json['rev'] as int?) ?? 1,
    canEdit: (json['can_edit'] as bool?) ?? false,
    blocks: [
      for (final b in (json['blocks'] as List<dynamic>? ?? const []))
        ScratchpadBlock.fromJson(b as Map<String, dynamic>),
    ],
  );
}

/// 追蹤收件匣裡的一筆。**跨板**——「我在等的東西完成了嗎」不分板。
@immutable
class WatchNotice {
  const WatchNotice({
    required this.id,
    this.boardId = '',
    this.boardName = '',
    this.itemKind = '',
    this.itemId = '',
    this.itemTitle = '',
    this.eventType = '',
    this.actorName = '',
    this.createdAt,
    this.readAt,
  });

  final String id;
  final String boardId;
  final String boardName;
  final String itemKind;
  final String itemId;
  final String itemTitle;

  /// `task_done` / `task_cancelled` / `task_reopened` / `task_deleted`…
  ///
  /// **「你等的那張卡又打開了」跟完成一樣重要**——漏掉它等於讓人以為
  /// 可以動工了。
  final String eventType;

  final String actorName;
  final String? createdAt;
  final String? readAt;

  bool get unread => (readAt ?? '').isEmpty;

  factory WatchNotice.fromJson(Map<String, dynamic> json) => WatchNotice(
    id: (json['id'] as String?) ?? '',
    boardId: (json['board_id'] as String?) ?? '',
    boardName: (json['board_name'] as String?) ?? '',
    itemKind: (json['item_kind'] as String?) ?? '',
    itemId: (json['item_id'] as String?) ?? '',
    itemTitle: (json['item_title'] as String?) ?? '',
    eventType: (json['event_type'] as String?) ?? '',
    actorName: (json['actor_name'] as String?) ?? '',
    createdAt: json['created_at'] as String?,
    readAt: json['read_at'] as String?,
  );
}

/// 把 [eventType] 講成人看得懂的一句話。
///
/// ⚠️ 不認得的事件**照樣要說出來**，不要吞掉——收件匣裡少一筆，使用者不會
/// 知道少了，而他正在等的可能就是那一筆。所以 default 分支印出原始事件名，
/// 難看，但看得見。
String watchNoticeLabel(String eventType, String itemTitle) {
  final t = itemTitle.isEmpty ? '一張卡' : '「$itemTitle」';
  return switch (eventType) {
    'task_done' => '$t 完成了',
    'task_cancelled' => '$t 被取消了',
    'task_reopened' => '$t 又重新打開了',
    'task_deleted' => '$t 被刪掉了',
    'watch_delivery_degraded' => '你追蹤的板不再有聊天室，改為只能自己查看',
    _ => '$t 有變動（$eventType）',
  };
}
