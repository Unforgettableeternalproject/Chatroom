import 'package:flutter/foundation.dart';

/// 上板（release）：確認一個週期時，把這個週期改過的 repo 併進穩定分支。
///
/// 三個形狀都照 Hub 的回傳／收受原樣對映：
/// - [ReleaseCandidates] ← `GET /api/board/objectives/{id}/release/candidates`
/// - [ReleaseRequest] → `verify` 的 `release` 欄位、`POST .../release` 的 body
/// - [ReleaseSettings] 是工作區的設定，**唯讀**：要改它得去執行器分頁，
///   在這裡開一個第二處入口就是第二份會漂移的真相。

/// 候選清單裡的一個 repo。
@immutable
class ReleaseRepoCandidate {
  const ReleaseRepoCandidate({
    required this.name,
    this.stableBranch = '',
    this.stableBranchExists = false,
    this.branches = const [],
    this.lastBranch = '',
    this.commits = 0,
    this.currentBranch = '',
  });

  final String name;

  /// 空＝這個 repo 沒設穩定分支，**不能上板**（畫面上不可勾）。
  final String stableBranch;

  /// 本機或 origin 有沒有這條分支。沒有不代表不能上板（執行器會建），
  /// 但值得在畫面上講一句。
  final bool stableBranchExists;

  /// 來源分支的候選。使用者可以自己填別的。
  final List<String> branches;

  /// 預設選的來源分支（本週期最後動到的那條）。
  final String lastBranch;

  /// 本週期在這個 repo 上的 commit 數。
  final int commits;

  final String currentBranch;

  /// 沒設穩定分支就不給勾——Hub 那側也會擋（`release_repo_not_eligible`），
  /// 這裡擋是為了讓人當場看得出原因，不是按下去才知道。
  bool get eligible => stableBranch.isNotEmpty && stableBranchExists;

  /// 預設來源分支：`last_branch` 優先，沒有就退回目前分支，再沒有就候選第一條。
  String get defaultSource {
    if (lastBranch.isNotEmpty) return lastBranch;
    if (currentBranch.isNotEmpty) return currentBranch;
    return branches.isEmpty ? '' : branches.first;
  }

  factory ReleaseRepoCandidate.fromJson(Map<String, dynamic> json) =>
      ReleaseRepoCandidate(
        name: json['name']?.toString() ?? '',
        stableBranch: json['stable_branch']?.toString() ?? '',
        stableBranchExists: json['stable_branch_exists'] == true,
        branches: _stringList(json['branches']),
        lastBranch: json['last_branch']?.toString() ?? '',
        commits: _int(json['commits']),
        currentBranch: json['current_branch']?.toString() ?? '',
      );
}

/// 工作區的上板設定。對話框**只顯示**合併方式，改它的地方在執行器分頁。
@immutable
class ReleaseSettings {
  const ReleaseSettings({
    this.mergeMethod = 'merge',
    this.mergeMessage = '',
    this.tagMessage = '',
  });

  final String mergeMethod;
  final String mergeMessage;
  final String tagMessage;

  factory ReleaseSettings.fromJson(Object? json) {
    if (json is! Map) return const ReleaseSettings();
    final method = json['merge_method']?.toString() ?? '';
    return ReleaseSettings(
      mergeMethod: method.isEmpty ? 'merge' : method,
      mergeMessage: json['merge_message']?.toString() ?? '',
      tagMessage: json['tag_message']?.toString() ?? '',
    );
  }
}

/// `release/candidates` 的整包回應。
@immutable
class ReleaseCandidates {
  const ReleaseCandidates({
    this.workspaceKey = '',
    this.possible = false,
    this.reason = '',
    this.repos = const [],
    this.settings = const ReleaseSettings(),
  });

  final String workspaceKey;

  /// 至少一個 repo 設了穩定分支，而且這次的呼叫路徑允許上板。**false 就不
  /// 顯示上板區塊**——把一個一定會被 Hub 擋下來的開關畫出來，只是讓人多按
  /// 一次。
  final bool possible;

  /// [possible] 為 false 的原因，只在那時有意義；舊 Hub 不回就是空字串。
  ///
  /// - `board_axis`：從板分頁進來的，不是從工作房
  /// - `not_ops_room_member`：呼叫者所在的房不是掛著此板、綁了工作區的 ops 房
  /// - `workspace_not_bound`：那間房沒綁工作區
  ///
  /// 前兩種是**換個地方按就成立**，值得在對話框講一句；`workspace_not_bound`
  /// 講了也沒有下一步可做（要去綁工作區），維持原本的完全不畫。
  final String reason;

  final List<ReleaseRepoCandidate> repos;

  final ReleaseSettings settings;

  factory ReleaseCandidates.fromJson(Map<String, dynamic> json) {
    final raw = json['repos'];
    return ReleaseCandidates(
      workspaceKey: json['workspace_key']?.toString() ?? '',
      possible: json['possible'] == true,
      reason: json['reason']?.toString() ?? '',
      repos: [
        if (raw is List)
          for (final e in raw)
            if (e is Map) ReleaseRepoCandidate.fromJson(e.cast<String, dynamic>()),
      ],
      settings: ReleaseSettings.fromJson(json['release_settings']),
    );
  }
}

/// 送出去的那一份：要上板哪些 repo、各自從哪條分支併、要不要打 tag。
@immutable
class ReleaseRequest {
  const ReleaseRequest({required this.repos, this.tag = ''});

  final List<ReleaseRepoSelection> repos;

  /// 選填。空字串＝不打 tag。
  final String tag;

  bool get isEmpty => repos.isEmpty;

  Map<String, dynamic> toJson() => {
        'repos': [for (final r in repos) r.toJson()],
        'tag': tag,
      };
}

@immutable
class ReleaseRepoSelection {
  const ReleaseRepoSelection({required this.name, required this.sourceBranch});

  final String name;
  final String sourceBranch;

  Map<String, dynamic> toJson() => {
        'name': name,
        'source_branch': sourceBranch,
      };
}

List<String> _stringList(Object? value) {
  if (value is! List) return const [];
  return value.map((e) => e.toString()).toList();
}

int _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
