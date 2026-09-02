import 'package:chatroom_app/models/board.dart';
import 'package:flutter_test/flutter_test.dart';

/// Board v2（獨立於 Chatroom）新增的 delta 欄位。
///
/// 契約定於房內 #41／#43。這裡測的都是**靜默失效**的形狀：欄位讀不到、
/// tombstone 沒處理、遷移期新舊格式只認一種——每一種都不會拋錯，
/// 只會讓畫面上少一塊東西，或多一塊早該消失的東西。

BoardDelta _delta(Map<String, dynamic> json) => BoardDelta.fromJson({
  'board_seq': 1,
  ...json,
});

Map<String, dynamic> _room(String id, {bool detached = false}) => {
  'id': id,
  'name': '房 $id',
  'status': 'active',
  'detached': detached,
};

void main() {
  group('掛接房間', () {
    test('detached 是 tombstone：收到就從快取移除', () {
      final attached = const BoardSnapshot().merge(
        _delta({
          'full': true,
          'attached_rooms': [_room('a'), _room('b')],
        }),
      );
      expect(attached.liveRooms.map((r) => r.id), unorderedEquals(['a', 'b']));

      // 解除 b。只把 detached 的當一般資料塞回去的話，b 會永遠留在清單上，
      // 而使用者要點下去才會發現它已經不在。
      final after = attached.merge(
        _delta({
          'board_seq': 2,
          'attached_rooms': [_room('b', detached: true)],
        }),
      );
      expect(after.liveRooms.map((r) => r.id), ['a']);
      expect(after.attachedRooms.containsKey('b'), isFalse);
    });

    test('增量不重送的房間要留著', () {
      final base = const BoardSnapshot().merge(
        _delta({'full': true, 'attached_rooms': [_room('a')]}),
      );
      final after = base.merge(_delta({'board_seq': 2}));
      expect(after.liveRooms.map((r) => r.id), ['a']);
    });
  });

  group('Supervisor 雙格式', () {
    test('v2 物件形式：actor_kind 讀得到', () {
      final snap = const BoardSnapshot().merge(
        _delta({
          'supervisor': {
            'actor_key': 'claude-abc',
            'display_name': '諾薇亞',
            'actor_kind': 'claude',
          },
        }),
      );
      expect(snap.supervisor!.actorKey, 'claude-abc');
      expect(snap.supervisor!.displayName, '諾薇亞');
      expect(snap.supervisor!.isHuman, isFalse);
    });

    // 遷移期間新舊 Hub 並存。只認物件形式的話，舊 Hub 那邊的 supervisor
    // 會靜默消失——畫面顯示「沒有人在收摘要」，而實際上有。
    test('v1 字串形式仍讀得到名字', () {
      final snap = const BoardSnapshot().merge(
        _delta({'supervisor': '艾斯維爾'}),
      );
      expect(snap.supervisor!.displayName, '艾斯維爾');
      expect(snap.supervisor!.actorKind, 'other');
    });

    test('空字串等於沒有指定，不是一個沒名字的人', () {
      final snap = const BoardSnapshot().merge(_delta({'supervisor': ''}));
      expect(snap.supervisor, isNull);
    });
  });

  group('Directive 稽核串', () {
    test('增量疊加，由新到舊', () {
      final base = const BoardSnapshot().merge(
        _delta({
          'full': true,
          'directives': [
            {'id': 'd1', 'board_seq': 3, 'content': '先做遷移'},
          ],
        }),
      );
      final after = base.merge(
        _delta({
          'board_seq': 5,
          'directives': [
            {'id': 'd2', 'board_seq': 5, 'content': '這張卡先停'},
          ],
        }),
      );
      expect(after.sortedDirectives.map((d) => d.id), ['d2', 'd1']);
    });

    test('has_more 只在全量回應時重設', () {
      final truncated = const BoardSnapshot().merge(
        _delta({
          'full': true,
          'directives': [
            {'id': 'd1', 'board_seq': 1},
          ],
          'directives_has_more': true,
        }),
      );
      expect(truncated.directivesHasMore, isTrue);

      // 增量沒有「還有更早的」這個概念。跟著增量歸零的話，畫面上那句
      // 「還有更早的紀錄」會在下一次拉取時無聲消失，而它其實還是真的。
      final after = truncated.merge(_delta({'board_seq': 2}));
      expect(after.directivesHasMore, isTrue);
    });
  });

  group('board_id', () {
    test('讀得到，且舊 Hub 不送時不會被清成空字串', () {
      final base = const BoardSnapshot().merge(
        _delta({'full': true, 'board_id': 'b-42'}),
      );
      expect(base.boardId, 'b-42');

      final after = base.merge(_delta({'board_seq': 2}));
      expect(after.boardId, 'b-42');
    });
  });

  group('Alias', () {
    test('別名帶得出它是哪個房來的', () {
      final actor = BoardActorRef.fromJson({
        'actor_key': 'claude-x',
        'display_name': '開發Novia (UI)',
        'actor_kind': 'claude',
        'aliases': [
          {'name': 'Novia', 'room_id': 'r-old', 'first_seen_at': '2026-08-29T00:00:00Z'},
        ],
      });
      expect(actor.aliases.single.name, 'Novia');
      expect(actor.aliases.single.roomId, 'r-old');
    });
  });

  group('Library 卡片', () {
    test('task_counts 是巢狀物件，攤平讀出來', () {
      final s = BoardSummary.fromJson({
        'id': 'b1',
        'name': 'Board V2',
        'status': 'archived',
        'attached_room_count': 3,
        'task_counts': {'total': 10, 'done': 4, 'claimed': 2},
        'my_role': 'editor',
      });
      expect(s.taskTotal, 10);
      expect(s.taskDone, 4);
      expect(s.taskClaimed, 2);
      expect(s.attachedRoomCount, 3);
      expect(s.isArchived, isTrue);
      expect(s.canEdit, isTrue);
    });

    test('Hub 沒說角色時當唯讀，不是預設可編輯', () {
      final s = BoardSummary.fromJson({'id': 'b1'});
      expect(s.canEdit, isFalse);
    });
  });
}
