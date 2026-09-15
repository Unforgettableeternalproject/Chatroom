import 'package:chatroom_app/models/board.dart';
import 'package:flutter_test/flutter_test.dart';

/// 從 Board Library（分頁）進來時**沒有房**。
///
/// 🔴 2026-09-03（其一）：從聊天室進去正常，從 BOARDS 分頁進去**整片灰**
/// ——成因是 `_closeoutActions` 這個 Widget builder 第一行就 `_actions!`，
/// 而沒有房就沒有 actions ⇒ null 檢查在 build 裡炸開。那種失敗特別壞：
/// 畫面上什麼都沒有，而「板是空的」與「板畫不出來」在灰色裡長得一樣。
///
/// 🔴 2026-09-03（其二）：修法當時是把板軸整片判成唯讀。那治好了崩潰，
/// 但**製造了艾斯維爾抱怨的那件事**——「Board 沒有綁房間就必定是唯讀」。
/// 現在板軸有自己的 actions（帶 session key），兩個問題都不靠唯讀解決。
void main() {
  group('進入路徑不決定能不能改', () {
    test('🔴 從 Library 進來＝editable，不是唯讀', () {
      expect(boardEditability(archived: false), BoardEditability.editable);
    });

    test('viewer 是 role 的事——它與「從哪裡進來」無關', () {
      // viewer 要板的 owner 升你。與進入路徑混為一談的話，
      // 人會一直重試「換一條路進去」，而那條路不存在
      expect(boardEditability(archived: false, role: 'viewer'),
          BoardEditability.viewer);
    });

    test('封存壓過一切', () {
      expect(boardEditability(archived: true), BoardEditability.archived);
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
