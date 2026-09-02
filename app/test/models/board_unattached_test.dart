import 'package:chatroom_app/models/board.dart';
import 'package:flutter_test/flutter_test.dart';

/// 這間房有沒有掛板——聊天室那顆 Board 按鈕要顯示「掛接」還是進度，
/// 全看這一個判準。
void main() {
  test('載入中一律不算未掛接', () {
    // 載入中的空快照與真的沒有板長得一模一樣。用「快照是空的」判的話，
    // 每次進房都會先閃一下「掛接任務板」再變回來——那一閃看起來像板被弄丟了
    expect(
      boardUnattached(loaded: false, boardId: '', hasObjectives: false),
      isFalse,
    );
  });

  test('載入完成且沒有 board_id ＝ 真的沒掛', () {
    expect(
      boardUnattached(loaded: true, boardId: '', hasObjectives: false),
      isTrue,
    );
  });

  test('有 board_id 就是掛著', () {
    expect(
      boardUnattached(loaded: true, boardId: 'b1', hasObjectives: false),
      isFalse,
    );
  });

  test('舊 Hub 不回 board_id，但有卡就表示板存在', () {
    // 只看 board_id 的話，舊 Hub 上每一間有板的房都會被判成未掛接，
    // 然後畫面請使用者去「掛接」一塊他早就有的板
    expect(
      boardUnattached(loaded: true, boardId: '', hasObjectives: true),
      isFalse,
    );
  });
}
