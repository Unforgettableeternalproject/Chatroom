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

    test('晚到的舊快照不得把已編輯／撤回的狀態降級回去', () {
      // REST 補訊與 WS 推播是兩條並行的路徑。REST 那份在路上時，WS 可能
      // 已經送來更新的快照——無條件覆寫會把畫面倒退回編輯前，而 cursor
      // 早就推進了，於是那個舊狀態會一直留到下次整批重抓。
      //
      // prependHistory 已經有這條方向規則（T0-2），upsertAll 漏了同一條：
      // 同一個病的兩處，當時只修了一處。
      final feed = RoomFeed('r1');
      feed.upsertAll([msg(10, updateSeq: 30, deleted: true)]);
      expect(feed.bySeq(10)!.deleted, isTrue);

      feed.upsertAll([msg(10)]); // 舊快照（cursor 10 < 30）晚到

      expect(feed.bySeq(10)!.deleted, isTrue, reason: '舊快照把撤回狀態蓋回去了');
      expect(feed.cursor, 30);
    });

    test('同 cursor 的重送仍然覆寫，不當成舊快照擋掉', () {
      // 邊界：cursor 相等代表「同一個版本又送了一次」。擋掉它沒有壞處，
      // 但也沒有好處，而 prependHistory 用的是 >=——兩處要一致，否則
      // 下一個人會以為其中一邊有特殊理由
      final feed = RoomFeed('r1');
      feed.upsertAll([msg(10, updateSeq: 30, pinned: true)]);
      feed.upsertAll([msg(10, updateSeq: 30, pinned: true, id: 'm10')]);
      expect(feed.bySeq(10)!.pinned, isTrue);
      expect(feed.length, 1);
    });

    test('往上捲回來的較新快照要蓋掉手上的舊版', () {
      // 症狀是「改了畫面不動、重進房才對」——最難查的那種間歇性。
      // upsertAll 早就是覆寫語意，prependHistory 卻用 containsKey 跳過，
      // 於是同一則訊息的新版本從歷史分頁回來時被靜靜丟掉。
      final feed = RoomFeed('r1');
      feed.upsertAll([msg(10), msg(11)]);
      expect(feed.bySeq(10)!.pinned, isFalse);

      feed.prependHistory(
        [msg(7), msg(10, updateSeq: 14, pinned: true)],
        hasMore: false,
      );

      expect(feed.bySeq(10)!.pinned, isTrue);
      expect(feed.cursor, 14);
      expect(feed.messages.map((m) => m.seq), [7, 10, 11]);
    });

    test('但歷史分頁不得把新版本降級回舊版', () {
      // 覆寫要有方向：分頁請求送出後、回應到達前，WS 可能已經推來更新的
      // 快照。無條件覆寫會讓畫面倒退一格，而那與「沒更新」一樣難查。
      final feed = RoomFeed('r1');
      feed.upsertAll([msg(10, updateSeq: 20, pinned: true)]);

      feed.prependHistory([msg(10)], hasMore: false);

      expect(feed.bySeq(10)!.pinned, isTrue, reason: '較舊的快照不該蓋掉新的');
      expect(feed.cursor, 20);
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
