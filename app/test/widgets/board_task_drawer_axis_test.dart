import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/screens/board/board_task_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 🔴 2026-09-03：**從 BOARDS 分頁點開任何一張卡，畫面整片灰。**
///
/// 成因是 `BoardTaskDrawer` 的 `roomId` 宣告成非 null，而板軸的呼叫端寫
/// `widget.roomId!`——板軸沒有房，那個 `!` 在 build 期拋 null check 例外。
///
/// ⚠️ 這種失敗特別壞：**畫面上什麼都沒有，也沒有任何錯誤訊息**，而「板是
/// 空的」與「板畫不出來」在灰色裡長得一模一樣。09/03 早上才因為同一個形狀
/// （`_closeoutActions` 的 `_actions!`）修過一次——這是它的第二次現身。
BoardTask _task({int? sourceSeq}) => BoardTask.fromJson({
      'id': 't1',
      'checklist_id': 'c1',
      'title': '一張卡',
      'status': 'todo',
      'source_seq': ?sourceSeq,
    });

Widget _wrap(Widget child) => ProviderScope(
      child: MaterialApp(
        theme: buildUepTheme(Brightness.dark),
        home: Scaffold(body: child),
      ),
    );

void main() {
  testWidgets('🔴 板軸（roomId 為 null）點開卡片不會炸', (tester) async {
    await tester.pumpWidget(_wrap(BoardTaskDrawer(
      roomId: null,
      boardId: 'b1',
      task: _task(),
      checklistTitle: '階段',
      onClose: () {},
    )));
    expect(tester.takeException(), isNull);
    expect(find.text('一張卡'), findsOneWidget);
  });

  testWidgets('板軸下即使卡有來源訊息，也不畫那條路——沒有房就沒有訊息流',
      (tester) async {
    await tester.pumpWidget(_wrap(BoardTaskDrawer(
      roomId: null,
      boardId: 'b1',
      task: _task(sourceSeq: 42),
      checklistTitle: '階段',
      onClose: () {},
    )));
    expect(tester.takeException(), isNull);
    expect(find.text('長出這張卡的訊息'), findsNothing);
  });

  // ⚠️ **房軸那半沒有測**：它會 watch `roomFeedProvider`，那需要一條真的
  // 連線與房內身分。在這裡 mock 一整條 feed 的成本遠大於它的價值——這次修
  // 的是「板軸不炸」，房軸本來就一直是好的。
}
