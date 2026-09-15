import 'package:chatroom_app/models/board.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「不能改」剩兩種狀態，而它們的**處置不一樣**：封存是「這段歷史結束了」，
/// viewer 是「要板的 owner 升你」。講成同一句「唯讀」的人會去找一個不存在
/// 的封存狀態，或去翻設定頁找一個不存在的權限開關。
///
/// 🔴 2026-09-03：曾經有第三種 `noRoom`——「從 Board Library 進來」。它的
/// 判準是**你從哪條網址進來**，跟板有沒有掛房、跟你是不是 owner 都無關，
/// 於是從 BOARDS 分頁開的板進去一張卡都建不了，包括自己剛開的那塊。
/// 艾斯維爾指出「我不認為 Board 沒有綁房間就必定是唯讀」，而 server 從來
/// 沒有這條規則——它長在 UI。卡片端點認 `X-Session-Key` 之後它退場了。
void main() {
  test('未封存、不是 viewer＝可以改', () {
    expect(boardEditability(archived: false), BoardEditability.editable);
  });

  test('🔴 從 Library 進來（沒有房）**不再**是唯讀的理由', () {
    // 這條測試在 2026-09-03 之前是反過來寫的。改它就是這次修的內容本身：
    // 板軸的動作帶 session key，擋不擋得住由 Hub 說了算
    expect(boardEditability(archived: false, role: 'owner'),
        BoardEditability.editable);
    expect(boardEditability(archived: false, role: 'editor'),
        BoardEditability.editable);
  });

  test('viewer 只能看——這是 role 的事，不是進入路徑的事', () {
    expect(boardEditability(archived: false, role: 'viewer'),
        BoardEditability.viewer);
  });

  test('封存壓過角色。封存的板從哪裡進來、你是誰都改不了', () {
    expect(boardEditability(archived: true, role: 'owner'),
        BoardEditability.archived);
    expect(boardEditability(archived: true, role: 'viewer'),
        BoardEditability.archived);
  });

  test('Hub 沒說 role 時當可以改——真的沒權限時它會回 403，那是誠實的失敗；'
      '預設鎖住則是無聲的', () {
    expect(boardEditability(archived: false), BoardEditability.editable);
  });
}
