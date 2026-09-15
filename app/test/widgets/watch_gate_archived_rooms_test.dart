import 'package:chatroom_app/models/board.dart';
import 'package:flutter_test/flutter_test.dart';

/// 追蹤（watch）的落點判準（1c920235 的 App 半邊）。
///
/// 🔴 判準原本是「還掛著的房」——那只濾掉 `detached`，**不看房有沒有
/// 封存**。於是一塊板掛著兩間都封存的房時，追蹤按鈕是亮的、追蹤也會成立，
/// 而通知永遠不會來（Hub 在投遞前就把封存房濾掉了，c81f757a）。
///
/// **「可以追但收不到」比「不能追」糟得多**：後者當場就知道，前者要等到
/// 事情發生、通知沒來才發現，而那時人已經在等了。
BoardSnapshot _snap(List<Map<String, dynamic>> rooms, {String status = 'active'}) =>
    const BoardSnapshot().merge(BoardDelta.fromJson({
      'board_seq': 10,
      'full': true,
      'board_id': 'b1',
      'status': status,
      'attached_rooms': rooms,
    }));

void main() {
  test('🔴 掛的房全封存了：說的是「都封存了」，不是「沒掛任何房」', () {
    final why = boardWatchBlockedReason(_snap([
      {'id': 'r1', 'name': '舊房', 'status': 'archived'},
    ]));
    // 兩種狀態的下一步不同：一間都沒掛要去掛一間，全封存了要開新的
    expect(why, contains('都已經封存'));
    expect(why, isNot(contains('還沒有掛接任何聊天室')));
  });

  test('一間都沒掛：維持原本那句', () {
    expect(boardWatchBlockedReason(_snap(const [])),
        contains('還沒有掛接任何聊天室'));
  });

  test('有 active 房時不擋——這次改的是判準，不是把追蹤關掉', () {
    expect(
        boardWatchBlockedReason(_snap([
          {'id': 'r1', 'name': '開發 09/07', 'status': 'active'},
          {'id': 'r2', 'name': '舊房', 'status': 'archived'},
        ])),
        isEmpty);
  });

  test('板自己封存了壓過一切——那時連「掛哪間房」都不必問', () {
    expect(
        boardWatchBlockedReason(_snap([
          {'id': 'r1', 'name': '開發 09/07', 'status': 'active'},
        ], status: 'archived')),
        contains('這塊板已經封存'));
  });

  test('Hub 說有活著的房就聽它的——本地推算只是退路', () {
    // 房清單這次沒送（增量），但 Hub 說有 2 間活著。推算會得到 0 而擋下
    // 追蹤，那是拿舊資料否定 Hub 剛講的話
    final snap = const BoardSnapshot().merge(BoardDelta.fromJson({
      'board_seq': 10,
      'full': true,
      'board_id': 'b1',
      'live_attached_room_count': 2,
    }));
    expect(boardWatchBlockedReason(snap), isEmpty);
  });
}
