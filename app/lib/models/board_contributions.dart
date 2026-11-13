import 'package:flutter/foundation.dart';

/// 任務板設定頁一次要的東西：板的名稱／描述／我的角色，加上貢獻紀錄
/// （`GET /api/boards/{id}/contributions`）。
///
/// 紀錄的來源是 Hub 的稽核串 `board_event`，更早的一段從卡片欄位回推
/// （[ContributionEntry.derived]）。沒有另一張事件表。
@immutable
class BoardContributions {
  const BoardContributions({
    required this.boardId,
    this.name = '',
    this.description = '',
    this.status = 'active',
    this.outcome = '',
    this.myRole = '',
    this.ownerName = '',
    this.digestIntervalSec,
    this.digestIntervalDefault = 900,
    this.entries = const [],
    this.total = 0,
    this.hasMore = false,
    this.stats = const [],
  });

  final String boardId;
  final String name;

  final String description;
  final String status;

  /// 結局：`''` / `completed` / `abandoned`。有結局就是已收尾，整頁唯讀。
  final String outcome;

  /// owner / editor / viewer。只有 owner 改得動名稱與描述。
  final String myRole;
  final String ownerName;

  /// 該板的 supervisor 摘要間隔（秒）。`null`＝用 Hub 預設。
  final int? digestIntervalSec;

  /// Hub 預設的摘要間隔（秒），舊 Hub 沒說時當 900。
  final int digestIntervalDefault;

  /// 這一頁的紀錄，新的在前。
  final List<ContributionEntry> entries;

  /// 紀錄總筆數（不受分頁影響）。
  final int total;
  final bool hasMore;

  /// 每人統計，依件數排。**整份紀錄算的**，不是這一頁。
  final List<ContributorStat> stats;

  bool get isOwner => myRole == 'owner';
  bool get isSettled => outcome.isNotEmpty;

  /// 接上一頁：紀錄累加，統計與中繼資料用新的。
  BoardContributions appendPage(BoardContributions next) => BoardContributions(
    boardId: boardId,
    name: next.name,
    description: next.description,
    status: next.status,
    outcome: next.outcome,
    myRole: next.myRole,
    ownerName: next.ownerName,
    digestIntervalSec: next.digestIntervalSec,
    digestIntervalDefault: next.digestIntervalDefault,
    entries: [...entries, ...next.entries],
    total: next.total,
    hasMore: next.hasMore,
    stats: next.stats,
  );

  factory BoardContributions.fromJson(Map<String, dynamic> json) {
    final board = (json['board'] as Map<String, dynamic>?) ?? const {};
    return BoardContributions(
      boardId: (json['board_id'] as String?) ?? '',
      name: (board['name'] as String?) ?? '',
      description: (board['description'] as String?) ?? '',
      status: (board['status'] as String?) ?? 'active',
      outcome: (board['outcome'] as String?) ?? '',
      myRole: (board['my_role'] as String?) ?? '',
      ownerName: (board['owner_name'] as String?) ?? '',
      digestIntervalSec: board['digest_interval_sec'] as int?,
      digestIntervalDefault: (board['digest_interval_default'] as int?) ?? 900,
      entries: [
        for (final e in (json['entries'] as List?) ?? const [])
          ContributionEntry.fromJson(e as Map<String, dynamic>),
      ],
      total: (json['total'] as int?) ?? 0,
      hasMore: (json['has_more'] as bool?) ?? false,
      stats: [
        for (final s in (json['stats'] as List?) ?? const [])
          ContributorStat.fromJson(s as Map<String, dynamic>),
      ],
    );
  }
}

/// 一筆「誰做了什麼」。
@immutable
class ContributionEntry {
  const ContributionEntry({
    required this.at,
    required this.action,
    this.actorName = '',
    this.actorKind = '',
    this.itemKind = '',
    this.itemId = '',
    this.title = '',
    this.derived = false,
  });

  final String at;

  /// objective_created / checklist_created / task_created / task_done /
  /// checklist_done / objective_review / objective_verified /
  /// objective_done / objective_reopened / released
  final String action;
  final String actorName;
  final String actorKind;
  final String itemKind;
  final String itemId;
  final String title;

  /// 稽核串裡沒有這筆，是從卡片欄位推出來的（只留最後一次）。
  final bool derived;

  factory ContributionEntry.fromJson(Map<String, dynamic> json) =>
      ContributionEntry(
        at: (json['at'] as String?) ?? '',
        action: (json['action'] as String?) ?? '',
        actorName: (json['actor_name'] as String?) ?? '',
        actorKind: (json['actor_kind'] as String?) ?? '',
        itemKind: (json['item_kind'] as String?) ?? '',
        itemId: (json['item_id'] as String?) ?? '',
        title: (json['title'] as String?) ?? '',
        derived: (json['derived'] as bool?) ?? false,
      );
}

/// 一個人在這塊板上的統計。
@immutable
class ContributorStat {
  const ContributorStat({
    required this.actorName,
    this.actorKind = '',
    this.total = 0,
    this.counts = const {},
    this.lastAt = '',
  });

  final String actorName;
  final String actorKind;
  final int total;

  /// 動作 → 件數（鍵同 [ContributionEntry.action]）。
  final Map<String, int> counts;
  final String lastAt;

  factory ContributorStat.fromJson(Map<String, dynamic> json) =>
      ContributorStat(
        actorName: (json['actor_name'] as String?) ?? '',
        actorKind: (json['actor_kind'] as String?) ?? '',
        total: (json['total'] as int?) ?? 0,
        counts: {
          for (final e
              in ((json['counts'] as Map<String, dynamic>?) ?? const {})
                  .entries)
            e.key: (e.value as int?) ?? 0,
        },
        lastAt: (json['last_at'] as String?) ?? '',
      );
}
