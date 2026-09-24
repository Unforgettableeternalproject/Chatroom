import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/models/board_contributions.dart';
import 'package:flutter_test/flutter_test.dart';

/// 任務板設定頁的資料形狀（Hub `GET /api/boards/{id}/contributions`），
/// 以及階段創建者的兩個欄位。
void main() {
  test('設定頁資料：中繼資料、紀錄與統計都讀得出來', () {
    final data = BoardContributions.fromJson({
      'board_id': 'b1',
      'board': {
        'name': '板',
        'description': '主題',
        'status': 'active',
        'my_role': 'owner',
        'owner_name': '艾斯維爾',
      },
      'entries': [
        {
          'at': '2026-09-24T00:00:00+00:00',
          'action': 'task_done',
          'actor_name': '諾薇亞',
          'actor_kind': 'claude',
          'title': '卡',
          'derived': true,
        },
      ],
      'total': 3,
      'has_more': true,
      'stats': [
        {
          'actor_name': '諾薇亞',
          'actor_kind': 'claude',
          'total': 2,
          'counts': {'task_created': 1, 'task_done': 1},
          'last_at': '2026-09-24T00:00:00+00:00',
        },
      ],
    });
    expect(data.isOwner, isTrue);
    expect(data.description, '主題');
    expect(data.entries.single.derived, isTrue);
    expect(data.stats.single.counts, {'task_created': 1, 'task_done': 1});
    expect(data.hasMore, isTrue);
  });

  test('接上一頁：紀錄累加，統計換成新的', () {
    const first = BoardContributions(
      boardId: 'b1',
      entries: [ContributionEntry(at: '2', action: 'task_done')],
      total: 2,
      hasMore: true,
    );
    final merged = first.appendPage(const BoardContributions(
      boardId: 'b1',
      entries: [ContributionEntry(at: '1', action: 'task_created')],
      total: 2,
      stats: [ContributorStat(actorName: 'A', total: 2)],
    ));
    expect(merged.entries.map((e) => e.action), ['task_done', 'task_created']);
    expect(merged.hasMore, isFalse);
    expect(merged.stats.single.total, 2);
  });

  test('階段帶著創建者；舊 Hub 沒送時是空字串，不補別的名字', () {
    final c = BoardChecklist.fromJson({
      'id': 'c1',
      'title': '階段',
      'created_by_name': '戴爾',
      'created_by_kind': 'human',
    });
    expect((c.createdByName, c.createdByKind), ('戴爾', 'human'));
    final old = BoardChecklist.fromJson({'id': 'c2', 'title': '舊'});
    expect((old.createdByName, old.createdByKind), ('', ''));
  });
}
