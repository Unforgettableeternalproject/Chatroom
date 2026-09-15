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
    test('detached 是狀態不是 tombstone：留在快取裡但不算「現在掛著」', () {
      final attached = const BoardSnapshot().merge(
        _delta({
          'full': true,
          'attached_rooms': [_room('a'), _room('b')],
        }),
      );
      expect(attached.liveRooms.map((r) => r.id), unorderedEquals(['a', 'b']));

      // 解除 b。**Hub 每次都全量重算這份**（`_attached_rooms()` 無條件
      // 查整張 `board_room`），所以這裡送的是**兩間都在**的新版本，
      // 不是「只送變動的那間」——後者是不會發生的輸入。
      //
      // **擋住「永遠留在清單上」的是 `liveRooms`**（它過濾 detached），
      // 不是把資料丟掉。
      //
      // 🔴 這裡本來還斷言 `attachedRooms` 不含 b——那多做了一層一樣的防護，
      // 代價是連歷史一起殺掉：`_showAttachedRooms` 整段「已解除」的標示
      // 因此永遠不會亮，四個 `r.detached` 全是死碼。Hub 也是刻意回這些房的
      // （`_attached_rooms()`：「已解除的房也回」）——兩邊都想留住它，
      // 中間這一行把它丟了（2026-09-04 寫房軸契約測試時發現）。
      //
      // 「解除了」與「從來沒掛過」對讀的人是兩件事。
      final after = attached.merge(
        _delta({
          'board_seq': 2,
          'attached_rooms': [_room('a'), _room('b', detached: true)],
        }),
      );
      expect(after.liveRooms.map((r) => r.id), ['a']);
      expect(after.attachedRooms['b']!.detached, isTrue);
    });

    test('增量不重送的房間要留著', () {
      final base = const BoardSnapshot().merge(
        _delta({'full': true, 'attached_rooms': [_room('a')]}),
      );
      final after = base.merge(_delta({'board_seq': 2}));
      expect(after.liveRooms.map((r) => r.id), ['a']);
    });
  });

  // 【2026-09-05 移除】「Supervisor 雙格式」那一組（v2 物件／v1 字串／空字串）
  // 連同它守的欄位一起退場：板回應頂層的 `supervisor` 兩側都已移除
  // （server `3a5979b`、App 這次），Supervisor 一律 per-room，走
  // `attached_rooms[].supervisor`。
  //
  // ⚠️ 那組測試不是被刪掉了事——它守的行為搬去了
  // `test/models/board_supervisor_test.dart`（`supervisesAnyRoom` /
  // `roomSupervisors`），而且守得比原本嚴：原本只驗解析得出來，新的那組驗
  // 的是「解除掛接的房不算」「departed 仍然算」「沒掛房＝正確空白」。

  group('Directive 稽核串', () {
    test('增量疊加，由新到舊', () {
      final base = const BoardSnapshot().merge(
        _delta({
          'full': true,
          'directives': [
            {'board_seq': 3, 'text': '先做遷移', 'from_name': '艾斯維爾'},
          ],
        }),
      );
      final after = base.merge(
        _delta({
          'board_seq': 5,
          'directives': [
            {'board_seq': 5, 'text': '這張卡先停', 'from_name': '艾斯維爾'},
          ],
        }),
      );
      // 沒有 id，board_seq 就是識別
      expect(after.sortedDirectives.map((d) => d.boardSeq), [5, 3]);
      expect(after.sortedDirectives.first.text, '這張卡先停');
    });

    test('has_more 只在全量回應時重設', () {
      final truncated = const BoardSnapshot().merge(
        _delta({
          'full': true,
          'directives': [
            {'board_seq': 1, 'text': 'x'},
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

  _realShapeTests();
}

/// Hub `c72c92d` 實測回來的真實形狀（8788，2026-09-02）。
///
/// 這一組是**照真貨寫的**，不是照契約猜的——欄位名打錯一個字就是靜默失效：
/// 畫面少一塊東西，不報錯。
void _realShapeTests() {
  group('delta 中繼資料（實測形狀）', () {
    BoardDelta real() => BoardDelta.fromJson({
      'board_id': 'a1460d0c',
      'name': 'UI 契約探針',
      'description': '',
      'status': 'active',
      'my_role': 'owner',
      'board_seq': 1,
      'full': true,
      'members': [
        {
          'actor_key': 'claude-ui-probe',
          'role': 'owner',
          'display_name': 'UI探針',
          'actor_kind': 'claude',
          'aliases': [],
        },
      ],
      'attached_rooms': [
        {
          'id': '4a90a3c6',
          'name': 'UI契約探針',
          'status': 'active',
          'detached': false,
        },
      ],
      'supervisor': null,
    });

    test('板名、狀態、角色都讀得出來', () {
      final snap = const BoardSnapshot().merge(real());
      expect(snap.name, 'UI 契約探針');
      expect(snap.status, 'active');
      expect(snap.myRole, 'owner');
      expect(snap.canEdit, isTrue);
      expect(snap.isArchived, isFalse);
    });

    test('members 以 actor_key 建索引，卡片靠它查名字', () {
      final snap = const BoardSnapshot().merge(real());
      expect(snap.memberOf('claude-ui-probe')?.displayName, 'UI探針');
      expect(snap.memberOf('claude-ui-probe')?.role, 'owner');
      expect(snap.memberOf(null), isNull);
      expect(snap.memberOf('nobody'), isNull);
    });

    test('增量不重送中繼資料時要保留，不可覆蓋成空', () {
      // 覆蓋成空的話，頁首會在第二次拉取後突然變成一塊無名的板，
      // 而且權限會從 owner 掉成「Hub 沒說」
      final base = const BoardSnapshot().merge(real());
      final after = base.merge(BoardDelta.fromJson({'board_seq': 2}));
      expect(after.name, 'UI 契約探針');
      expect(after.myRole, 'owner');
      expect(after.members.length, 1);
    });
  });

  group('可編輯性', () {
    test('viewer 是自己一種，不與「沒從聊天室進來」混為一談', () {
      // 前者要板的 owner 升你，後者從房間進去就解決了。
      // 講成同一句話的人會一直重試同一條路
      expect(
        boardEditability(archived: false, role: 'viewer'),
        BoardEditability.viewer,
      );
    });

    test('Hub 沒說角色時當可寫，不是預設鎖住', () {
      // 舊 Hub 不回 my_role。判成 viewer 會讓整塊板無故唯讀，
      // 而使用者找不到任何可以改的地方。真的沒權限時 Hub 會回 403，
      // 那是誠實的失敗；預設鎖住則是無聲的
      expect(
        boardEditability(archived: false, role: ''),
        BoardEditability.editable,
      );
    });

    test('封存壓過角色', () {
      expect(
        boardEditability(archived: true, role: 'owner'),
        BoardEditability.archived,
      );
    });
  });
}
