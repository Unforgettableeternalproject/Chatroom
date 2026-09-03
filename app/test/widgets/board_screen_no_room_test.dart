import 'package:chatroom_app/models/board.dart';
import 'package:flutter_test/flutter_test.dart';

/// 從 Board Library（分頁）進來時**沒有房**。
///
/// 🔴 2026-09-03：從聊天室進去正常，從 BOARDS 分頁進去**整片灰**——不是空
/// 狀態畫面，是什麼都沒畫。成因是 `_closeoutActions` 這個 **Widget builder**
/// 第一行就 `_actions!`，而沒有房就沒有 actions ⇒ null 檢查在 build 裡炸開。
///
/// ⚠️ 那種失敗的形狀特別壞：**它不會告訴任何人是哪一行造成的**。畫面上
/// 什麼都沒有，而「板是空的」與「板畫不出來」在灰色裡長得一模一樣。
///
/// 這裡守的是那個判準本身——`noRoom` 是一個要**在畫面組裝前**就分辨出來的
/// 狀態，不是等到某個按鈕被按下才發現。
void main() {
  group('沒有房時的可編輯性', () {
    test('從 Library 進來＝noRoom，不是 editable', () {
      // editable 的話畫面會組裝出那些需要房內身分的元件，而它們拿不到
      expect(
        boardEditability(archived: false, hasRoom: false),
        BoardEditability.noRoom,
      );
    });

    test('noRoom 與 viewer 是兩種——修法不一樣', () {
      // viewer 要板的 owner 升你；noRoom 從房間進去就解決了。
      // 講成同一句話的人會一直重試同一條路
      expect(
        boardEditability(archived: false, hasRoom: true, role: 'viewer'),
        BoardEditability.viewer,
      );
    });

    test('封存壓過沒有房', () {
      expect(
        boardEditability(archived: true, hasRoom: false),
        BoardEditability.archived,
      );
    });
  });

  group('沒有房時仍然要畫得出板', () {
    test('板軸的快照本身不需要房——卡片都在', () {
      // 這條是「灰畫面」的反面證據：資料這一層與房無關，所以畫不出來
      // 一定是組裝那一層的問題，不是沒有資料
      final snap = const BoardSnapshot().merge(BoardDelta.fromJson({
        'board_seq': 186,
        'full': true,
        'board_id': 'b1',
        'objectives': [
          {'id': 'o1', 'title': '週期'},
        ],
        'tasks': [
          {'id': 't1', 'title': '卡'},
        ],
      }));
      expect(snap.hasNoItems, isFalse);
      expect(snap.liveRooms, isEmpty);
      expect(snap.sortedObjectives, hasLength(1));
    });
  });
}
