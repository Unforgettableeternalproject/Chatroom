import 'package:chatroom_app/models/board.dart';
import 'package:flutter_test/flutter_test.dart';

/// 卡片上「誰在做這張」的名字要從哪裡來。
///
/// v2 之後名字的權威是板成員表（`members[]`，依 `claim_actor_key` 查），
/// 因為同一個人在不同房可能叫不同名字，板上要統一成最早進入的那個。
/// 卡上的 `claim_name` 降為**快照**——但它不能被丟掉：舊 Hub 與 v1 路徑
/// 都不回 `members[]`，那時它是唯一的答案。
BoardDelta _delta({List<Map<String, dynamic>> members = const []}) =>
    BoardDelta.fromJson({
      'board_seq': 1,
      'board_id': 'b1',
      'full': true,
      'members': members,
      'tasks': [
        {
          'id': 't1',
          'room_id': 'r1',
          'checklist_id': 'c1',
          'title': '卡',
          'status': 'in_progress',
          'claim_state': 'held',
          'claim_name': '卡片探針',
          'claim_actor_key': 'claude-probe',
          'deleted': false,
          'board_seq': 1,
          'created_at': '2026-09-02T00:00:00Z',
        },
      ],
    });

void main() {
  test('claim_actor_key 讀得出來——比對同一個人只能用它', () {
    final snap = const BoardSnapshot().merge(_delta());
    expect(snap.tasks['t1']!.claimActorKey, 'claude-probe');
  });

  test('有 members 時查得到板上的名字與別名', () {
    final snap = const BoardSnapshot().merge(_delta(members: [
      {
        'actor_key': 'claude-probe',
        'display_name': '諾薇亞',
        'actor_kind': 'claude',
        'aliases': [
          {'name': '卡片探針', 'room_id': 'r1', 'room_name': '實作房'},
        ],
      },
    ]));
    final holder = snap.memberOf(snap.tasks['t1']!.claimActorKey);
    expect(holder!.displayName, '諾薇亞');
    expect(holder.aliases.single.roomName, '實作房');
  });

  test('沒有 members 時查不到，呼叫端要退回 claim_name 快照', () {
    // v1 路徑（從房間進來）與舊 Hub 都不回 members[]。
    // 這裡若不是 null 而是丟例外或空物件，卡片會變成「（不明）」——
    // 而正確答案明明就在 claim_name 裡
    final snap = const BoardSnapshot().merge(_delta());
    expect(snap.memberOf('claude-probe'), isNull);
    expect(snap.tasks['t1']!.claimName, '卡片探針');
  });
}
