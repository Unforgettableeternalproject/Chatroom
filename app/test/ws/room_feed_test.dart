import 'package:chatroom_app/models/message.dart';
import 'package:chatroom_app/ws/room_feed.dart';
import 'package:flutter_test/flutter_test.dart';

Message msg(int seq,
        {String? id,
        int updateSeq = 0,
        bool pinned = false,
        bool deleted = false}) =>
    Message(
      id: id ?? 'm$seq',
      seq: seq,
      updateSeq: updateSeq,
      kind: 'chat',
      content: '訊息 $seq',
      createdAt: '2026-08-28T00:00:00+00:00',
      pinned: pinned,
      deleted: deleted,
    );

void main() {
  group('RoomFeed', () {
    test('upsert 是覆寫不是 skip：釘選狀態的新快照要蓋掉舊值', () {
      final feed = RoomFeed('r1');
      feed.upsertAll([msg(1), msg(2)]);
      expect(feed.bySeq(1)!.pinned, isFalse);

      // 同 seq 的第二次到達（已被釘選、領了 update_seq）
      feed.upsertAll([msg(1, updateSeq: 3, pinned: true)]);
      expect(feed.bySeq(1)!.pinned, isTrue);
      expect(feed.length, 2);
    });

    test('cursor 用 max(seq, update_seq)，不是連續前綴——seq 天生有洞', () {
      final feed = RoomFeed('r1');
      // seq=2 缺席（那個序號被某次釘選的 update_seq 用掉了）
      feed.upsertAll([msg(1), msg(3)]);
      expect(feed.cursor, 3, reason: '連續前綴會卡在 1，max 才是正確語意');

      feed.upsertAll([msg(1, updateSeq: 5, pinned: true)]);
      expect(feed.cursor, 5);
    });

    test('排序以 seq 遞增，與到達順序無關', () {
      final feed = RoomFeed('r1');
      feed.upsertAll([msg(5), msg(2), msg(9)]);
      expect(feed.messages.map((m) => m.seq), [2, 5, 9]);
    });

    test('prependHistory 更新 oldestLoadedSeq 與 hasMoreHistory', () {
      final feed = RoomFeed('r1');
      feed.upsertAll([msg(10), msg(11)]);
      feed.setHasMoreHistory(true);
      feed.prependHistory([msg(7), msg(8)], hasMore: false);
      expect(feed.oldestLoadedSeq, 7);
      expect(feed.hasMoreHistory, isFalse);
      expect(feed.messages.map((m) => m.seq), [7, 8, 10, 11]);
    });

    test('舊於已載入視窗的訊息不進 store，但 cursor 照樣推進', () {
      final feed = RoomFeed('r1');
      feed.upsertAll([msg(10), msg(11)]);
      // 一則很舊的訊息被釘選，pump 推來完整快照（seq=3 < oldest=10）
      feed.upsertAll([msg(3, updateSeq: 12, pinned: true)]);
      expect(feed.bySeq(3), isNull, reason: '塞進來會造成時間軸假連續');
      expect(feed.cursor, 12, reason: 'cursor 不推進會反覆重收同一批更新');
    });

    test('reset 清空後可重新載入', () {
      final feed = RoomFeed('r1');
      feed.upsertAll([msg(1)]);
      feed.reset();
      expect(feed.isEmpty, isTrue);
      expect(feed.cursor, 0);
      feed.upsertAll([msg(100)]);
      expect(feed.oldestLoadedSeq, 100);
    });

    test('byId 反查', () {
      final feed = RoomFeed('r1');
      feed.upsertAll([msg(1, id: 'abc')]);
      expect(feed.byId('abc')!.seq, 1);
      expect(feed.byId('nope'), isNull);
    });
  });
}
