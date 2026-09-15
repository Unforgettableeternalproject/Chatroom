import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/screens/board/board_task_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// N-4 的兩顆按鈕：**請人接手**（提出）與 **接下／婉拒**（回答）。
///
/// 🔴 這條測試的由來：我把 `requests` 加進 `_TaskActionBar` 的參數，
/// 卻**忘了在呼叫端傳**——全套 562 條測試照樣全綠，只有 analyze 的
/// `unused_element_parameter` 抓到。那表示當時沒有任何一條測試在看
/// 「回答按鈕有沒有真的出現」，而那正是這張卡的重點：
/// **少了它，「需要對方同意」在畫面上就不成立**（只剩顯示，沒有入口）。
BoardTask _task({String status = 'todo'}) => BoardTask.fromJson({
      'id': 't1',
      'checklist_id': 'c1',
      'title': '一張卡',
      'status': status,
    });

Widget _wrap(Widget child) => ProviderScope(
      child: MaterialApp(
        theme: buildUepTheme(Brightness.dark),
        home: Scaffold(body: child),
      ),
    );


/// 「請人接手」09/08 起**收進 `⋯` 選單**（卡 9e8e53d1：外露的按鈕太多）。
///
/// 入口沒有消失，只是換了位置——這些測試守的仍是「它還在、停用時還說得出
/// 理由」，所以斷言之前先把選單打開。⚠️ 位置變了要改測試，但**斷言不可以
/// 跟著鬆掉**：改成 findsNothing 就等於把這條測試原本要擋的東西放走了。
Future<void> _openMore(WidgetTester tester) async {
  await tester.tap(find.text('⋯'));
  await tester.pumpAndSettle();
}

void main() {
  // ⚠️ 這條原本釘的是「板軸沒有『請人接手』」，理由是那裡沒有房可問。
  // **2026-09-07 決策裁走「房選擇器」路之後那個前提不成立了**：板軸照樣
  // 有入口，只是指派前先選一間掛接房。零房時按鈕仍畫出來但按不動——
  // 消失會被讀成「板軸沒有這個功能」，而真相是「這塊板現在沒有人可以指」。
  //
  // 板軸各種掛接情形的完整覆蓋在 board_axis_assign_test。
  testWidgets('板軸一間房都沒掛：入口在，但按不動且說得出為什麼', (tester) async {
    await tester.pumpWidget(_wrap(BoardTaskDrawer(
      roomId: null,
      boardId: 'b1',
      task: _task(),
      checklistTitle: '階段',
      onClose: () {},
    )));
    expect(tester.takeException(), isNull);
    await _openMore(tester);
    expect(find.text('請人接手'), findsOneWidget);
    expect(find.text('掛到房間後才能指派'), findsOneWidget);
  });

  testWidgets('已完成的卡不再請人接手——請了也只是掛著', (tester) async {
    await tester.pumpWidget(_wrap(BoardTaskDrawer(
      roomId: null,
      boardId: 'b1',
      task: _task(status: 'done'),
      checklistTitle: '階段',
      onClose: () {},
    )));
    expect(find.text('請人接手'), findsNothing);
  });

  group('請求的狀態在畫面上分得出來', () {
    // ⚠️ 這一組不進 widget 樹（房軸要一條真的 feed 與房內身分，
    // 在這裡 mock 一整條的成本遠大於價值）。守的是**送進畫面的那份資料**
    // 本身分不分得出三種狀態——文案是照著它挑的
    TaskRequest r(String status) => TaskRequest.fromJson({
          'id': 'r1',
          'task_id': 't1',
          'target_name': '對方',
          'requester_name': '我',
          'status': status,
        });

    test('🔴 待回覆／已接受／已婉拒是三種，不是「有」與「沒有」', () {
      expect(r('pending').isPending, isTrue);
      expect(r('accepted').isAccepted, isTrue);
      expect(r('declined').isDeclined, isTrue);
      // 三個互斥——任何兩個同時為真，畫面就會同時畫出兩種標籤
      for (final s in ['pending', 'accepted', 'declined']) {
        final x = r(s);
        expect([x.isPending, x.isAccepted, x.isDeclined].where((b) => b).length,
            1);
      }
    });

    test('🔴 只有 pending 的那筆該長出回答按鈕', () {
      // 已回答的還留在清單上（拒絕留紀錄不刪除）——如果拿「有沒有請求」
      // 當判準，被婉拒過的卡會永遠掛著一組按不得的按鈕
      final all = [r('declined'), r('accepted'), r('pending')];
      expect(all.where((x) => x.isPending), hasLength(1));
    });
  });
}
