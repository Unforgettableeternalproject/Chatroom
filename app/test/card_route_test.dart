import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/screens/board/board_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// 從訊息裡的 `#[標題]` 點進一張任務卡（艾斯維爾 09/14 兩條回報）。
///
/// 兩個症狀長得不像，根因是同一個進入點：**它走了板軸**。板軸是另一個
/// 分頁，跳過去就離開了那段對話；而房軸那條相容入口當時吃不到 `?task=`，
/// 所以「改走房軸」本身還帶不進要打開的卡。
void main() {
  group('cardRoute 依進來的軸決定網址', () {
    test('🔴 本次修的 bug：從聊天室進來走房軸，人留在 ROOMS 分頁', () {
      final r = cardRoute(boardId: 'b1', taskId: 't1', roomId: 'r1');
      expect(r, '/rooms/r1/board?task=t1');
      // 關鍵不在字串長相，而在**它不是 /boards/... 開頭**——
      // 只要是那個開頭，AppShell 就會把左欄切去 BOARDS，人回不到聊天室
      expect(r.startsWith('/boards/'), isFalse);
    });

    test('板軸（Board Library）進來的維持權威路徑', () {
      expect(cardRoute(boardId: 'b1', taskId: 't1'), '/boards/b1?task=t1');
    });

    test('兩條路都帶得走 task——網址換軸不該弄丟「要開哪一張」', () {
      expect(cardRoute(boardId: 'b1', taskId: 't1', roomId: 'r1'),
          contains('task=t1'));
      expect(cardRoute(boardId: 'b1', taskId: 't1'), contains('task=t1'));
    });
  });

  group('objectiveOfTask：被指名的卡在哪個週期', () {
    BoardSnapshot snap() => const BoardSnapshot().merge(BoardDelta.fromJson({
          'board_seq': 1,
          'full': true,
          'board_id': 'b1',
          'objectives': [
            {'id': 'o1', 'title': '上個週期'},
            {'id': 'o2', 'title': '這個週期'},
          ],
          'checklists': [
            {'id': 'c1', 'objective_id': 'o1', 'title': '舊階段'},
            {'id': 'c2', 'objective_id': 'o2', 'title': '新階段'},
          ],
          'tasks': [
            {'id': 't1', 'checklist_id': 'c1', 'title': '舊卡'},
            {'id': 't2', 'checklist_id': 'c2', 'title': '新卡'},
          ],
        }));

    test('🔴 本次修的 bug：反查得到卡所屬的週期，不是預設那個', () {
      // 沒有這條反查時，畫面會停在 defaultObjective 挑的週期上——
      // 抽屜開著、左欄卻指著別的地方，讀起來像「這張卡不在這塊板上」
      expect(objectiveOfTask(snap(), 't1')?.id, 'o1');
      expect(objectiveOfTask(snap(), 't2')?.id, 'o2');
    });

    test('沒有指名任何卡 ⇒ null，交給預設週期', () {
      expect(objectiveOfTask(snap(), null), isNull);
    });

    test('板還沒載到那張卡 ⇒ null，不是錯誤', () {
      // 指涉指向一張這塊板上撈不到的卡（被刪、沒權限、或資料還沒到）。
      // 這裡回 null 讓畫面照預設走，比擋著不畫好
      expect(objectiveOfTask(snap(), '不存在的卡'), isNull);
    });

    test('卡在，但它那一階段的週期撈不到 ⇒ null', () {
      final orphan = const BoardSnapshot().merge(BoardDelta.fromJson({
        'board_seq': 1,
        'full': true,
        'board_id': 'b1',
        'objectives': [
          {'id': 'o1', 'title': '週期'},
        ],
        'checklists': [
          {'id': 'c9', 'objective_id': '不在這份快照裡', 'title': '階段'},
        ],
        'tasks': [
          {'id': 't9', 'checklist_id': 'c9', 'title': '卡'},
        ],
      }));
      expect(objectiveOfTask(orphan, 't9'), isNull);
    });
  });

  group('房換過板之後，舊訊息的指涉還指著舊板', () {
    // 🔴 09/14 迴歸（本次改動自己造成的）：「一律走房軸」在換過板的房裡
    // 會開到一塊沒有那張卡的板。而且它不報錯——卡沒被刪，preview 還是 ok，
    // 所以 chip 看起來可以點，點了什麼都不會發生。
    test('同一塊板 ⇒ 留在房軸，人回得去', () {
      expect(cardIsOnRoomBoard('b1', 'b1'), isTrue);
    });

    test('🔴 指涉指著舊板 ⇒ 不留在房軸', () {
      expect(cardIsOnRoomBoard('b1', 'b2'), isFalse);
    });

    test('🔴 本房沒有板（沒掛板／還沒載到）⇒ 不留在房軸', () {
      // 審核用Codex 09/14：這一格原本放行走房軸，但板可以被 detach，而舊
      // 訊息的指涉活過那次卸除——放行只會開出「還沒掛板」的畫面，那張卡
      // 一樣看不到，與這條 bug 原本的症狀相同
      expect(cardIsOnRoomBoard('b1', ''), isFalse);
    });

    test('指涉沒帶 board_id ⇒ 同上', () {
      expect(cardIsOnRoomBoard('', 'b1'), isTrue);
    });

    test('組起來：舊板的卡走板軸，本房的卡走房軸', () {
      String route(String refBoard, String roomBoard) => cardRoute(
            boardId: refBoard,
            taskId: 't1',
            roomId: cardIsOnRoomBoard(refBoard, roomBoard) ? 'r1' : null,
          );
      expect(route('b1', 'b1'), '/rooms/r1/board?task=t1');
      expect(route('b1', 'b2'), '/boards/b1?task=t1',
          reason: '離開聊天室是代價，但那是唯一看得到這張卡的路');
    });
  });
}
