import 'package:chatroom_app/models/message.dart';
import 'package:chatroom_app/ws/room_feed.dart';
import 'package:flutter_test/flutter_test.dart';

Message msg(int seq, {int updateSeq = 0, bool pinned = false}) => Message(
      id: 'm$seq',
      seq: seq,
      updateSeq: updateSeq,
      kind: 'chat',
      content: '訊息 $seq',
      createdAt: '2026-08-28T00:00:00+00:00',
      pinned: pinned,
    );

/// 🔴 2026-09-07：**沒有變化的推播也會通知，於是房裡一片安靜時畫面照樣重建。**
///
/// 鏈路（三個人各查一段才拼出來的）：
///
/// 1. **Hub 側**：pump 的條件是 `MAX(seq, update_seq) > last`，而**釘選、刪除、
///    編輯都會推進 `update_seq`** ⇒ 一則早就存在的舊訊息會被重新推一次。
///    frame 非空（Hub 不送空 frame），內容卻全是已知的東西。
/// 2. **App 側**：`upsertAll` 對「舊於已載入視窗」的訊息 `continue`（那是對的，
///    塞進來會在時間軸上造成假連續），於是 `_bySeq` 一個字都沒動——
///    **但迴圈結束後無條件 `_notify()`**。
/// 3. ⇒ 有人釘一則舊訊息，所有訂閱者的 `ChatScreen` 重建一次，而畫面上什麼
///    都沒變。
///
/// ⚠️ **這條修的是「無謂的重建」，不宣稱它修好了輸入法卡住那個症狀。**
/// rebuild 會不會打斷真實的 Windows IME，測試環境驗不到（`flutter test` 裡
/// 沒有輸入法）。那一格要靠實機，不要因為這裡綠了就把 B 那張卡結掉。
void main() {
  group('RoomFeed 只在真的變了才通知', () {
    late RoomFeed feed;
    late int notifications;

    setUp(() {
      feed = RoomFeed('r1');
      notifications = 0;
    });

    /// 先建立「已載入視窗」，並從這一刻開始數通知。
    void seedWindow() {
      feed.upsertAll([msg(10), msg(11), msg(12)]);
      feed.changes.listen((_) => notifications++);
    }

    test('🔴 全部舊於視窗的推播不該通知——那正是「釘一則舊訊息」的形狀',
        () async {
      seedWindow();

      // 有人釘了 seq=3（早就捲出視窗）。Hub 推它的完整快照過來
      feed.upsertAll([msg(3, updateSeq: 99, pinned: true)]);
      await Future<void>.delayed(Duration.zero);

      expect(feed.length, 3, reason: 'store 不該變');
      expect(notifications, 0,
          reason: '什麼都沒改卻通知，訂閱者就白重建一次——'
              '而畫面上完全看不出發生過什麼');
    });

    test('cursor 照樣要推進——不通知不等於不記錄', () async {
      seedWindow();
      feed.upsertAll([msg(3, updateSeq: 99, pinned: true)]);
      await Future<void>.delayed(Duration.zero);

      expect(feed.cursor, 99,
          reason: 'cursor 停住的話 resubscribe 會反覆重收同一批更新');
    });

    test('真的有新訊息就要通知', () async {
      seedWindow();
      feed.upsertAll([msg(13)]);
      await Future<void>.delayed(Duration.zero);

      expect(notifications, 1);
      expect(feed.length, 4);
    });

    test('視窗內的舊訊息被更新版本覆寫，也要通知', () async {
      seedWindow();
      // seq=11 在視窗內，被釘選後領了新的 update_seq
      feed.upsertAll([msg(11, updateSeq: 50, pinned: true)]);
      await Future<void>.delayed(Duration.zero);

      expect(notifications, 1, reason: '內容真的變了，畫面要跟著變');
      expect(feed.bySeq(11)!.pinned, isTrue);
    });

    test('⚠️ 已知限制：視窗內的同一份快照重送仍會通知一次', () async {
      seedWindow();
      feed.upsertAll([msg(11)]);
      await Future<void>.delayed(Duration.zero);

      expect(notifications, 1,
          reason: '這條**記錄現況、不是要求**——見下面的理由');
    });

    // 為什麼不順手把上面那條也修掉：要分辨「重送的是同一份」得比對內容，
    // 而 REST 與 WS 兩條路徑回的欄位完整度不見得一樣（例如 reply_preview）。
    // 現行的覆寫規則是「後到的贏」，改成「內容一樣就跳過」等於要先回答
    // 「哪一份比較完整」——那是一個比「省下一次通知」貴得多的問題，而且
    // 答錯會讓畫面停在較不完整的那份，沒有任何症狀。
    //
    // 影響也有限：WS 重連補推一整批只會通知**一次**（整個 upsertAll 收斂成
    // 一次），不是每則一次。真正每天在發生的是「釘一則舊訊息 ⇒ 全房白重建」，
    // 那條已經修掉了。
  });
}
