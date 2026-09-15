import 'package:chatroom_app/models/board.dart';
import 'package:flutter_test/flutter_test.dart';

/// 下一次該從哪個水位要增量。
///
/// 🔴 2026-09-03：艾斯維爾的畫面上左邊寫著 37/48、右邊一張卡都沒有。
/// 資料沒問題、換軸沒問題、API 也沒問題——**client 帶著一個高水位去要增量，
/// 而它手上一張卡都沒有**，於是 Hub 只回那之後的一張，畫面就是空的。
///
/// Hub 做對了它被要求的事。錯的是那個要求。
///
/// ⚠️ 這裡不去分辨那個狀態怎麼來的（換軸、快取被清、水位跨軸沿用⋯⋯，
/// 而且不只一條路）。守的是**不變式**：水位往前走了、手上卻什麼都沒有，
/// 是一個不該存在的狀態，而它**不會報錯**——只會永遠空白。
void main() {
  BoardSnapshot snap({required int seq, required bool withTask}) =>
      const BoardSnapshot().merge(BoardDelta.fromJson({
        'board_seq': seq,
        'full': true,
        if (withTask)
          'tasks': [
            {'id': 't1', 'title': '一張卡'},
          ],
      }));

  test('手上有卡就從目前水位續讀', () {
    final s = snap(seq: 185, withTask: true);
    expect(s.hasNoItems, isFalse);
    expect(s.resumeFrom, 185);
  });

  test('🔴 水位很高但一張卡都沒有 → 從 0 要全量', () {
    // 這一條就是那個空白畫面。沿用 boardSeq 的話，
    // **每一次重讀都只會拿到「185 之後」的那一點點**，而基底永遠是空的
    final s = snap(seq: 185, withTask: false);
    expect(s.hasNoItems, isTrue);
    expect(s.resumeFrom, 0);
  });

  test('全新的空快照也是 0', () {
    expect(const BoardSnapshot().resumeFrom, 0);
  });

  test('真的沒有卡的板：重拉一次全量是免費的，空等不是', () {
    // 真空板每次都會多要一次全量——回來還是空的，成本是一次請求。
    // 而反過來（拿高水位空等）的成本是**畫面永遠是空的，且不報錯**
    final empty = snap(seq: 3, withTask: false);
    expect(empty.resumeFrom, 0);
  });
}
