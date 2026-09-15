import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/models/participant.dart';
import 'package:chatroom_app/screens/board/supervisor_track_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// Supervisor 的追蹤介面：**依人分堆**，而板是依工作分堆。
///
/// 對人用 `participant_id` 而不是 `actor_key`——Hub 刻意不外流成員的
/// session_key，UI 手上沒有 actor_key。副作用剛好是對的：換一個 session
/// 就是新的 participant，上一世領的卡不算在他頭上（同名不同 session＝
/// 獨立個體，艾斯維爾 2026-09-03）。
Participant _p(String id, {String name = '某人', String status = 'active'}) =>
    Participant(
      id: id,
      kind: 'claude',
      displayName: name,
      role: 'agent',
      status: status,
      joinedAt: '2026-09-03T00:00:00+00:00',
    );

BoardSnapshot _board(List<Map<String, dynamic>> tasks) =>
    const BoardSnapshot().merge(BoardDelta.fromJson({
      'board_seq': 1,
      'full': true,
      'board_id': 'b1',
      'objectives': [
        {'id': 'o1', 'title': '週期'},
      ],
      'checklists': [
        {'id': 'c1', 'objective_id': 'o1', 'title': '階段'},
      ],
      'tasks': [
        for (final t in tasks) {'checklist_id': 'c1', ...t},
      ],
    }));

void main() {
  test('認領中的卡算在持有者頭上', () {
    final loads = workloadsByMember(
      _board([
        {
          'id': 't1',
          'title': '在做',
          'status': 'in_progress',
          'claim_participant_id': 'p1',
          'claim_state': 'held',
        },
      ]),
      [_p('p1')],
    );
    expect(loads['p1']!.active.single.title, '在做');
  });

  test('🔴 卡住的卡單獨一堆——與「在做」混在一起的話，'
      'supervisor 要看的正好是被藏起來的那一堆', () {
    final loads = workloadsByMember(
      _board([
        {
          'id': 't1',
          'title': '卡住了',
          'status': 'blocked',
          'claim_participant_id': 'p1',
          'claim_state': 'held',
        },
      ]),
      [_p('p1')],
    );
    expect(loads['p1']!.blocked, hasLength(1));
    expect(loads['p1']!.active, isEmpty);
  });

  test('指派但還沒認領＝「有人請他做」，不是「他在做」', () {
    final loads = workloadsByMember(
      _board([
        {
          'id': 't1',
          'title': '被指派',
          'status': 'todo',
          'assignee_participant_id': 'p1',
        },
      ]),
      [_p('p1')],
    );
    expect(loads['p1']!.suggested, hasLength(1));
    expect(loads['p1']!.active, isEmpty);
  });

  test('已經有人領走的卡，指派就沒有意義了——不再算進建議那堆', () {
    final loads = workloadsByMember(
      _board([
        {
          'id': 't1',
          'title': '別人領走了',
          'status': 'in_progress',
          'assignee_participant_id': 'p1',
          'claim_participant_id': 'p2',
          'claim_state': 'held',
        },
      ]),
      [_p('p1'), _p('p2')],
    );
    expect(loads['p1']!.suggested, isEmpty);
    expect(loads['p2']!.active, hasLength(1));
  });

  test('🔴 孤兒卡自成一堆，不掛在任何現任成員頭上——'
      '那些卡看起來有人在做，實際上沒有', () {
    final loads = workloadsByMember(
      _board([
        {
          'id': 't1',
          'title': '沒人在做',
          'status': 'in_progress',
          'claim_participant_id': 'gone',
          'claim_state': 'orphaned',
        },
      ]),
      [_p('p1')],
    );
    expect(loads['p1']!.isEmpty, isTrue);
    expect(loads['__orphaned__']!.active, hasLength(1));
  });

  test('完成的卡分開放——它不佔「在手上」的數字', () {
    final loads = workloadsByMember(
      _board([
        {
          'id': 't1',
          'title': '做完了',
          'status': 'done',
          'claim_participant_id': 'p1',
          'claim_state': 'held',
        },
      ]),
      [_p('p1')],
    );
    expect(loads['p1']!.done, hasLength(1));
    expect(loads['p1']!.openCount, 0);
  });
}
