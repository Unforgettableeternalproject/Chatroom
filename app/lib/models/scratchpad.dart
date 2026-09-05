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
    this.tags = const [],
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

  /// 這個段落被標成什麼（Bug／新功能／…）。
  ///
  /// **schema 寬、行為窄**：欄位是陣列，但行為是單選——之後要改多選時不必
  /// 動資料，反過來（存單一值）有一半機率要遷移。畫面要的那一個用 [tag]。
  ///
  /// 標在段落不標在板：一份想法板裡的觀察性質各不相同（兩則 bug、三則新
  /// 功能、一則權限設計），標在板上等於一份板只有一個標籤，標不出任何東西。
  final List<String> tags;

  final List<ScratchpadNote> notes;
  final String? updatedAt;

  /// 單選語意下的那一個標籤。**沒標時是 `null`**——`null` 與空字串要分得出
  /// 來，不然「沒有標籤」與「標了一個空的」在畫面上會長得一樣。
  String? get tag => tags.isEmpty ? null : tags.first;

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
        tags: [
          for (final t in (json['tags'] as List<dynamic>? ?? const []))
            if (t is String && t.isNotEmpty) t,
        ],
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
    this.iAmHuman = false,
  });

  final String id;
  final String boardId;
  final String title;

  /// **結構**的版本（段落的增刪與順序），不是某一段內容的版本。
  /// 重排與新增帶它，改某一段帶那一段自己的 `rev`。
  final int rev;

  final List<ScratchpadBlock> blocks;
  final bool canEdit;

  /// 我是不是人類成員。**伺服器算的**，不從 kind 字串自己推。
  ///
  /// 只有人類排得動段落——排序會改變別人那段話的上下文，Hub 把它歸成
  /// 與改寫同一類（`human_only`，實測 2026-09-03）。
  ///
  /// ⚠️ 預設 **false**：讀不到就當不能排。反過來的話 agent 會看到拖曳
  /// 把手，拖完才拿 403——**而那時順序在畫面上已經變了**，它會以為成功。
  final bool iAmHuman;

  /// 段落排得動嗎。兩個條件都要：板上可寫，而且我是人類。
  bool get canReorder => canEdit && iAmHuman && blocks.length > 1;

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
    iAmHuman: (json['i_am_human'] as bool?) ?? false,
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

  /// Hub 實際會寫進來的（`app.py` 4321 與 6839／6872）：
  /// `task_done` / `task_cancelled` / `task_reopened` /
  /// `delivery_degraded` / `delivery_restored`。
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
    // ⚠️ 這兩個的 item_title 是**板名**，不是卡名（Hub 寫 item_kind='board'）。
    // 套上面那個 `t` 的話會變成「「某某板」完成了」那種句子
    'delivery_degraded' =>
      '${itemTitle.isEmpty ? '你追蹤的板' : '「$itemTitle」'} '
          '不再有聊天室，通知改為只能自己回來看',
    'delivery_restored' =>
      '${itemTitle.isEmpty ? '你追蹤的板' : '「$itemTitle」'} '
          '又有聊天室了，會重新叫醒你',
    _ => '$t 有變動（$eventType）',
  };
}

/// 這一則註解，現在這個人能不能把它標成已處理。
///
/// Hub 的守門是「**這一段的作者，或人類成員**」（`app.py:6593`），而那與
/// 段落的 `can_edit` 是同一條。所以這裡直接用伺服器算好的兩個布林值，
/// **不自己重算那個條件**——自己算的話兩邊的規則會漂移，而漂移的那一半
/// 沒有人在看：畫面給了按鈕，按下去 403。
///
/// ⚠️ 判準是 [blockCanEdit] 不是想法板層級的可寫。只看後者的話，agent 會在
/// 人類寫的段落上看到一顆「處理掉」（@審核用Codex-2 2026-09-03）。
bool canResolveNote({
  required bool padCanEdit,
  required bool blockCanEdit,
}) =>
    padCanEdit && blockCanEdit;
