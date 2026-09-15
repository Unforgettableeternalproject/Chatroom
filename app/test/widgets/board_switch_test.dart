import 'package:chatroom_app/screens/board/board_switch.dart';
import 'package:flutter_test/flutter_test.dart';

/// 更換任務板的兩步流程（618da61b）。
///
/// 決策 09/07 照 UI 提案裁：**不包新端點**，App 走 detach → attach。
/// 包成一支端點做得到，但那會把中間態藏起來——而它本來就會發生
/// （`attach` 有 `room_already_has_board` 擋著，順序不能反）。
///
/// 🔴 這組測試釘的是**四種結果分得出來**。全部講成「更換失敗」的話，
/// 人不知道自己的房間現在是什麼狀態——而這條流程中途的狀態剛好就是
/// 「沒有板」，那是他必須知道、而且有下一步可做的事。
void main() {
  test('第一步就沒過：什麼都沒變，要說原本那塊還在', () {
    final msg = boardSwitchStatusMessage(
        detached: false, attached: false, error: '只有房間管理者能換');
    expect(msg, contains('原本的任務板還掛在這間房'));
    expect(msg, contains('只有房間管理者能換'));
    // 不能讓人以為房間現在空了——那會讓他去做一件不必做的事
    expect(msg, isNot(contains('現在沒有板')));
  });

  test('🔴 解除了但沒挑新的（使用者取消）：要講出房間現在沒有板', () {
    final msg = boardSwitchStatusMessage(detached: true, attached: false);
    expect(msg, contains('已解除原本的任務板'));
    expect(msg, contains('現在沒有板'));
    // 下一步要講出來——這個狀態不是死路
    expect(msg, contains('可以再掛一塊'));
  });

  test('🔴 解除了、掛新的失敗：錯誤與狀態都要在同一句話裡', () {
    final msg = boardSwitchStatusMessage(
        detached: true, attached: false, error: '這塊板已經封存');
    expect(msg, contains('這塊板已經封存'));
    expect(msg, contains('現在沒有板'),
        reason: '只講錯誤的話，人不知道房間被留在哪個狀態');
    expect(msg, contains('可以再掛一塊'));
  });

  test('兩步都過：不要多話', () {
    expect(boardSwitchStatusMessage(detached: true, attached: true), '換好了。');
  });
}
