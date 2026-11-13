import 'board.dart';

/// 「有沒有」三態：不限／有／沒有。
enum TriFilter { any, yes, no }

/// 任務板的卡片篩選條件。只在 App 端對已載入的快照過濾，不送 Hub。
///
/// 母體是 [BoardSnapshot.tasks] 全部載入的卡（板快照不分頁），所以不需要
/// Hub 參數。
class BoardTaskFilter {
  const BoardTaskFilter({
    this.keyword = '',
    this.status,
    this.dependency = TriFilter.any,
    this.claimed = TriFilter.any,
  });

  /// 比對標題與內容（不分大小寫）。
  final String keyword;

  /// 卡片狀態（`todo`／`in_progress`…）；null＝不限。
  final String? status;

  /// 有沒有依賴：看這張卡自己的 `dependsOn`（影響不算）。
  final TriFilter dependency;

  /// 有沒有人認領：持有中（held）才算已認領；孤兒卡（持有者已離場）
  /// 算未認領，因為它現在沒有人在做。
  final TriFilter claimed;

  bool get isActive =>
      keyword.trim().isNotEmpty ||
      status != null ||
      dependency != TriFilter.any ||
      claimed != TriFilter.any;

  BoardTaskFilter copyWith({
    String? keyword,
    String? Function()? status,
    TriFilter? dependency,
    TriFilter? claimed,
  }) =>
      BoardTaskFilter(
        keyword: keyword ?? this.keyword,
        status: status != null ? status() : this.status,
        dependency: dependency ?? this.dependency,
        claimed: claimed ?? this.claimed,
      );

  bool matches(BoardTask t) {
    final q = keyword.trim().toLowerCase();
    if (q.isNotEmpty &&
        !t.title.toLowerCase().contains(q) &&
        !t.description.toLowerCase().contains(q)) {
      return false;
    }
    if (status != null && t.status != status) return false;
    if (!_tri(dependency, t.dependsOn.isNotEmpty)) return false;
    if (!_tri(claimed, t.isHeld)) return false;
    return true;
  }

  List<BoardTask> apply(List<BoardTask> tasks) =>
      isActive ? [for (final t in tasks) if (matches(t)) t] : tasks;

  static bool _tri(TriFilter f, bool has) => switch (f) {
        TriFilter.any => true,
        TriFilter.yes => has,
        TriFilter.no => !has,
      };
}
