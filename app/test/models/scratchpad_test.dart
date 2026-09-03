import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/models/scratchpad.dart';
import 'package:chatroom_app/state/scratchpad_providers.dart';
import 'package:flutter_test/flutter_test.dart';

/// 想法板與追蹤收件匣的形狀。
///
/// 這裡測的都是**靜默失效**：欄位讀不到、預設值偏向危險的那一邊、
/// 不認得的事件被吞掉。每一種都不會拋錯，只會讓畫面上少一塊東西。
void main() {
  group('段落', () {
    test('can_edit 是伺服器算的，缺了就當不能改', () {
      // ⚠️ 預設要偏向**不能改**。反過來的話，畫面會給一個編輯框，
      // 而使用者打完按下去才拿到 403——那時他已經寫了一整段
      final b = ScratchpadBlock.fromJson({'id': 'b1'});
      expect(b.canEdit, isFalse);
    });

    test('rev 跟內容一起回來，且缺了不會變成 0', () {
      // rev=0 送回去必然被 Hub 的 ge=1 擋掉，而那個 422 讀起來
      // 與「你的版本過期了」完全不同，會把人帶去查錯的方向
      final b = ScratchpadBlock.fromJson({'id': 'b1', 'content': 'x'});
      expect(b.rev, 1);
    });

    test('人寫的段落認得出來——那條線就是 agent 動不了的界線', () {
      final human = ScratchpadBlock.fromJson({
        'id': 'b1',
        'author_kind': 'human',
      });
      final agent = ScratchpadBlock.fromJson({
        'id': 'b2',
        'author_kind': 'claude',
      });
      expect(human.isHuman, isTrue);
      expect(agent.isHuman, isFalse);
    });

    test('未處理的註解與已處理的分得開', () {
      final b = ScratchpadBlock.fromJson({
        'id': 'b1',
        'notes': [
          {'id': 'n1', 'content': '這段要拆'},
          {'id': 'n2', 'content': '已經處理過的', 'resolved_at': '2026-09-02T00:00:00Z'},
        ],
      });
      expect(b.notes, hasLength(2));
      expect(b.openNotes.map((n) => n.id), ['n1']);
    });
  });

  group('清單卡片', () {
    test('unresolved_notes 讀得到——它是「有人對你的段落提了意見」的唯一線索', () {
      final p = ScratchpadSummary.fromJson({
        'id': 'p1',
        'title': '想法',
        'block_count': 4,
        'unresolved_notes': 2,
      });
      expect(p.blockCount, 4);
      expect(p.unresolvedNotes, 2);
    });
  });

  group('收件匣', () {
    test('read_at 為空才算未讀', () {
      expect(WatchNotice.fromJson({'id': 'n1'}).unread, isTrue);
      expect(
        WatchNotice.fromJson({'id': 'n1', 'read_at': '2026-09-02T00:00:00Z'})
            .unread,
        isFalse,
      );
    });

    test('不認得的事件照樣說得出來，不吞掉', () {
      // ⚠️ 吞掉的話收件匣裡會少一筆，而使用者不會知道少了——
      // 他正在等的可能就是那一筆。難看但看得見，勝過乾淨但不見了
      final label = watchNoticeLabel('task_something_new', '換軸');
      expect(label, contains('換軸'));
      expect(label, contains('task_something_new'));
    });

    test('「又重新打開了」跟「完成了」一樣要講', () {
      // 漏掉 reopen 等於讓人以為可以動工了
      expect(watchNoticeLabel('task_reopened', 'A'), contains('重新打開'));
      expect(watchNoticeLabel('task_done', 'A'), contains('完成'));
    });

    test('沒有標題時不印出一個空的引號', () {
      expect(watchNoticeLabel('task_done', ''), '一張卡 完成了');
    });
  });

  group('每塊板的未讀數', () {
    test('只算未讀的，且照 board 分開', () {
      final notices = [
        WatchNotice.fromJson({'id': '1', 'board_id': 'a'}),
        WatchNotice.fromJson({'id': '2', 'board_id': 'a'}),
        WatchNotice.fromJson({'id': '3', 'board_id': 'b'}),
        WatchNotice.fromJson(
            {'id': '4', 'board_id': 'b', 'read_at': '2026-09-02T00:00:00Z'}),
      ];
      expect(unreadByBoard(notices), {'a': 2, 'b': 1});
    });

    test('沒有 board_id 的不算進任何一塊板', () {
      // 算進去的話會生出一塊 id 是空字串的板，而畫面上找不到它——
      // 那顆紅點會亮在一個不存在的地方
      final n = [WatchNotice.fromJson({'id': '1'})];
      expect(unreadByBoard(n), isEmpty);
    });
  });

  group('卡片上的追蹤欄位', () {
    test('Hub 沒說時當作沒在追、沒人在等', () {
      // 預設 true 的話按鈕會顯示成「已追蹤」，而使用者按下去是取消——
      // 他會以為自己剛剛取消了一個從來沒建立過的追蹤。
      // 舊 Hub 不回這兩欄，所以這條守的是遷移期
      final t = BoardTask.fromJson({'id': 't1', 'title': 'x'});
      expect(t.watching, isFalse);
      expect(t.watcherCount, 0);
    });

    test('讀得到 Hub 補在卡上的值', () {
      final t = BoardTask.fromJson({
        'id': 't1',
        'title': 'x',
        'watching': true,
        'watcher_count': 3,
      });
      expect(t.watching, isTrue);
      expect(t.watcherCount, 3);
    });
  });

  _deliveryMode();
}
/// `delivery_mode`（Hub `c94daeb` 起）。
///
/// ⚠️ 這一組守的是**「掛 1 房」與「掛 1 房但沒有一間活著」不能長得一樣**。
/// 後者表示追蹤者不會再被叫醒，而那是持續狀態，不是閃過去的提示。
void _deliveryMode() {
  group('delivery_mode', () {
    test('Hub 說 inbox_only 就是 inbox_only', () {
      final b = BoardSummary.fromJson({
        'id': 'b1',
        'attached_room_count': 1,
        'live_room_count': 0,
        'delivery_mode': 'inbox_only',
      });
      expect(b.inboxOnly, isTrue);
    });

    test('Hub 說 room_and_inbox 就不標降級，即使房數看起來像', () {
      // 聽 Hub 的，不自己推。自己推的話兩邊的規則會漂移，
      // 而漂移的那一半沒有人在看
      final b = BoardSummary.fromJson({
        'id': 'b1',
        'attached_room_count': 1,
        'live_room_count': 0,
        'delivery_mode': 'room_and_inbox',
      });
      expect(b.inboxOnly, isFalse);
    });

    test('舊 Hub 不回這欄時才退回用房數推', () {
      expect(
        BoardSummary.fromJson({
          'id': 'b1',
          'attached_room_count': 2,
          'live_room_count': 0,
        }).inboxOnly,
        isTrue,
      );
    });

    test('全新的空板不算降級——那不是降級，是還沒開始', () {
      // attached_room_count 也是 0 的話，用 live==0 推會把每一塊新板
      // 都標成「通知要自己來看」，而那句話對它毫無意義
      expect(
        BoardSummary.fromJson({'id': 'b1'}).inboxOnly,
        isFalse,
      );
    });
  });
}
