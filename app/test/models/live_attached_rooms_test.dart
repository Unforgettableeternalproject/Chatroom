import 'package:chatroom_app/models/board.dart';
import 'package:flutter_test/flutter_test.dart';

/// 1c920235（J4 判準）的 App 半邊。決策 2026-09-07 裁 B：
/// **一個數字不能回答兩個問題**，所以拆欄位——
///
/// - `attached_room_count` 維持歷史語意：**掛過哪些房**（封存的也算）
/// - `live_attached_room_count`：**還有人在用嗎**（只算 active 房）
///
/// ⚠️ App 這側原本也有同一個病：`liveRooms` 只濾掉 `detached`，**不看房
/// 有沒有封存**，而它同時被兩種問題共用——「掛著哪些房」（正確）與
/// 「通知有沒有落點」（錯的：封存房收不到通知，c81f757a 的 Server 半邊
/// 就是在投遞前把它們濾掉）。
///
/// 症狀：一塊板掛著兩間房、兩間都封存了，追蹤按鈕仍然亮著，而通知永遠
/// 不會來——**「可以追但收不到」比「不能追」糟得多**，前者要等到卡完成
/// 才發現，那時人已經在等了。
BoardSnapshot _snap(List<Map<String, dynamic>> rooms, {int? liveCount}) =>
    const BoardSnapshot().merge(BoardDelta.fromJson({
      'board_seq': 10,
      'full': true,
      'board_id': 'b1',
      'attached_rooms': rooms,
      'live_attached_room_count': ?liveCount,
    }));

void main() {
  _libraryNaming();

  group('activeRooms 與 liveRooms 是兩個問題', () {
    test('🔴 封存的房仍然掛著，但它不是「還在用」', () {
      final snap = _snap([
        {'id': 'r1', 'name': '舊房', 'status': 'archived'},
      ]);
      expect(snap.liveRooms, hasLength(1), reason: '它確實還掛著');
      expect(snap.activeRooms, isEmpty, reason: '但通知送不進去');
    });

    test('detached 的房兩邊都不算——它已經不掛在這塊板上了', () {
      final snap = _snap([
        {'id': 'r1', 'name': '解除了', 'status': 'active', 'detached': true},
      ]);
      expect(snap.liveRooms, isEmpty);
      expect(snap.activeRooms, isEmpty);
    });

    test('active 房兩邊都算', () {
      final snap = _snap([
        {'id': 'r1', 'name': '開發 09/07', 'status': 'active'},
      ]);
      expect(snap.liveRooms, hasLength(1));
      expect(snap.activeRooms, hasLength(1));
    });
  });

  group('Hub 算的那個數字是權威', () {
    test('Hub 回了就聽 Hub 的——本地推算只是舊版的退路', () {
      // 自己推算等於在猜 Hub 的規則，而規則漂移的那一半沒有人在看
      // （同 `deliveryMode` 的既有處置）
      final snap = _snap([
        {'id': 'r1', 'name': '房', 'status': 'active'},
      ], liveCount: 0);
      expect(snap.liveAttachedRooms, 0, reason: 'Hub 說 0 就是 0');
    });

    test('舊 Hub 不回這個欄位時，退回本地推算', () {
      final snap = _snap([
        {'id': 'r1', 'name': '開著', 'status': 'active'},
        {'id': 'r2', 'name': '封存了', 'status': 'archived'},
      ]);
      expect(snap.liveAttachedRooms, 1);
    });

    test('增量不帶這個欄位時，不可以把已知的值洗成 0', () {
      // 🔴 這是 merge 最常見的失手：缺席被當成「變成 0」。
      // 那會讓追蹤按鈕在一次無關的增量之後突然變灰
      final full = _snap([
        {'id': 'r1', 'name': '房', 'status': 'active'},
      ], liveCount: 3);
      final after = full.merge(BoardDelta.fromJson({'board_seq': 11}));
      expect(after.liveAttachedRooms, 3);
    });
  });
}

/// 清單（Library）那半：**同一個值兩個名字**。
///
/// Hub `d03c2a5` 起 `live_attached_room_count`（09/07 決策定的正典）與
/// `live_room_count`（先前就在的舊名）並存、值相同，舊名預計下一個 kit
/// 週期收掉。
///
/// ⚠️ 先讀正典再退回舊名。反過來寫的話，舊名被收掉的那一天這個數字會
/// **靜靜變成 0**——而 0 是一個合法的值（「一間活著的房都沒有」），
/// 沒有任何地方會報錯，畫面只會說這塊板沒有人在用。
void _libraryNaming() {
  group('清單的 live 計數：兩個名字並存期', () {
    BoardSummary parse(Map<String, dynamic> json) =>
        BoardSummary.fromJson({'id': 'b1', ...json});

    test('兩個都在時取正典', () {
      expect(
          parse({'live_attached_room_count': 2, 'live_room_count': 2})
              .liveRoomCount,
          2);
    });

    test('🔴 只有正典時也要讀得到——舊名收掉那天不能變成 0', () {
      expect(parse({'live_attached_room_count': 3}).liveRoomCount, 3);
    });

    test('只有舊名時（還沒換版的 Hub）照樣讀得到', () {
      expect(parse({'live_room_count': 1}).liveRoomCount, 1);
    });

    test('兩個都沒有才是 0', () {
      expect(parse(const {}).liveRoomCount, 0);
    });
  });
}
