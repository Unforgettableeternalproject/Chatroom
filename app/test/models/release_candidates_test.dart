import 'package:chatroom_app/models/release.dart';
import 'package:flutter_test/flutter_test.dart';

/// `release/candidates` 的回傳形狀（契約 C4）。
///
/// 這一層要守住的是**缺欄位不等於 false 以外的東西**：Hub 少回一個
/// `stable_branch_exists`，畫面該說「不存在」而不是整個炸掉；而
/// `possible` 與「有沒有候選」是兩件事，對話框拿它決定要不要顯示上板區。
void main() {
  test('整包解析：workspace_key、possible、repos、release_settings', () {
    final c = ReleaseCandidates.fromJson(const {
      'workspace_key': 'chatroom',
      'possible': true,
      'repos': [
        {
          'name': 'Chatroom',
          'stable_branch': 'master',
          'stable_branch_exists': true,
          'branches': ['develop', 'feature/release'],
          'last_branch': 'develop',
          'commits': 3,
          'current_branch': 'develop',
        },
      ],
      'release_settings': {
        'merge_method': 'squash',
        'merge_message': 'release: {source}',
        'tag_message': '{objective}',
      },
    });

    expect(c.workspaceKey, 'chatroom');
    expect(c.possible, isTrue);
    expect(c.repos.single.name, 'Chatroom');
    expect(c.repos.single.stableBranch, 'master');
    expect(c.repos.single.stableBranchExists, isTrue);
    expect(c.repos.single.branches, ['develop', 'feature/release']);
    expect(c.repos.single.commits, 3);
    expect(c.settings.mergeMethod, 'squash');
    expect(c.settings.tagMessage, '{objective}');
  });

  test('🔴 沒設穩定分支的 repo 不可勾（eligible＝false）', () {
    final repo = ReleaseRepoCandidate.fromJson(const {
      'name': 'UEP',
      'stable_branch': '',
      'commits': 1,
    });
    expect(repo.eligible, isFalse);
    expect(repo.stableBranchExists, isFalse);
  });

  test('預設來源分支：last_branch 優先，其次目前分支，再其次候選第一條', () {
    expect(
        ReleaseRepoCandidate.fromJson(const {
          'name': 'A',
          'branches': ['develop', 'main'],
          'last_branch': 'feature/x',
          'current_branch': 'main',
        }).defaultSource,
        'feature/x');
    expect(
        ReleaseRepoCandidate.fromJson(const {
          'name': 'A',
          'branches': ['develop'],
          'current_branch': 'main',
        }).defaultSource,
        'main');
    expect(
        ReleaseRepoCandidate.fromJson(const {
          'name': 'A',
          'branches': ['develop'],
        }).defaultSource,
        'develop');
  });

  test('possible 為 false、repos 缺席都不炸', () {
    final c = ReleaseCandidates.fromJson(const {'workspace_key': 'x'});
    expect(c.possible, isFalse);
    expect(c.repos, isEmpty);
    // 沒有 release_settings 時是一組預設值，不是 null
    expect(c.settings.mergeMethod, 'merge');
  });

  test('possible 為 false 時帶回 reason', () {
    expect(
        ReleaseCandidates.fromJson(const {
          'possible': false,
          'reason': 'board_axis',
        }).reason,
        'board_axis');
    expect(
        ReleaseCandidates.fromJson(const {
          'possible': false,
          'reason': 'not_ops_room_member',
        }).reason,
        'not_ops_room_member');
  });

  test('🔴 舊 Hub 沒回 reason：空字串，不是 null', () {
    expect(ReleaseCandidates.fromJson(const {'possible': false}).reason, '');
  });

  test('送出去的 body：repos 用 name／source_branch，tag 一律帶（空＝不打）', () {
    final body = const ReleaseRequest(repos: [
      ReleaseRepoSelection(name: 'Chatroom', sourceBranch: 'develop'),
    ]).toJson();

    expect(body['repos'], [
      {'name': 'Chatroom', 'source_branch': 'develop'},
    ]);
    expect(body['tag'], '');
  });
}
