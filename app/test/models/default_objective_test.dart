import 'package:chatroom_app/models/board.dart';
import 'package:flutter_test/flutter_test.dart';

/// 🔴 艾斯維爾 09/07 實機：**進 Board 預設展開的是一個已完成的週期**，
/// 而該關注的是進行中的那個。
///
/// **不是新 bug，是 `90cc566` 的直接副作用**：那顆讓 App 帶
/// `include_settled=true` 把歷史週期撈回畫面（先前人類只看得到本週期），
/// 於是清單裡多了已完成的那些，而「預設選哪一筆」還停在「排序上的第一個」。
///
/// 同一族的第三次：**改了資料範圍，沒改預設看哪一筆**。
BoardObjective _o(String id, String status, {int order = 0}) =>
    BoardObjective.fromJson({
      'id': id,
      'title': id,
      'status': status,
      'order_index': order,
    });

void main() {
  test('🔴 已完成的排在前面時，預設仍要選進行中的那個', () {
    final picked = defaultObjective([
      _o('舊週期', 'done'),
      _o('本週期', 'active'),
    ]);
    expect(picked!.id, '本週期');
  });

  test('review／verified 也算「還沒結束」——它們正在等人類', () {
    // 這兩個狀態比任何 done 都更需要被看到：畫面上那個「等你確認」
    // 的週期如果沒被預設展開，人就不會知道有事情在等他
    expect(defaultObjective([_o('舊', 'done'), _o('送審中', 'review')])!.id,
        '送審中');
    expect(defaultObjective([_o('舊', 'done'), _o('已確認', 'verified')])!.id,
        '已確認');
  });

  test('多個未結束時取排序上的第一個——不要另外發明一套順序', () {
    final picked = defaultObjective([
      _o('第一', 'active', order: 0),
      _o('第二', 'active', order: 1),
    ]);
    expect(picked!.id, '第一');
  });

  test('全部都結束了才退回第一個——畫面不能沒有東西', () {
    final picked = defaultObjective([_o('甲', 'done'), _o('乙', 'done')]);
    expect(picked!.id, '甲');
  });

  test('空清單回 null，由呼叫端去畫空狀態', () {
    expect(defaultObjective(const []), isNull);
  });
}
