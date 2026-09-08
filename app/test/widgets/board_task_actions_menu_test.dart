import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/screens/board/board_task_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 任務卡的操作**一次只外露一顆**，其餘收進 `⋯`（09/08 卡 9e8e53d1）。
///
/// 原本 `todo` 一次長出五顆狀態按鈕再加上指派入口，艾斯維爾的原話是「太多、
/// 令人反感」。這與 09/07 修的 Wrap 換行是**兩個層次**：那個修的是「放不下
/// 會爆版」，這個修的是「放得下也不該全部放」。
///
/// ⚠️ 收起來的東西**還在**。這裡兩段斷言是一組的：收起前找不到、打開後找得
/// 到。只寫前半段的話，把功能整個刪掉也會綠。
BoardTask _task({String status = 'todo'}) => BoardTask.fromJson({
      'id': 't1',
      'checklist_id': 'c1',
      'title': '一張卡',
      'status': status,
    });

Widget _wrap(BoardTask task) => ProviderScope(
      child: MaterialApp(
        theme: buildUepTheme(Brightness.dark),
        home: Scaffold(
          body: BoardTaskDrawer(
            roomId: null,
            boardId: 'b1',
            task: task,
            checklistTitle: '階段',
            onClose: () {},
          ),
        ),
      ),
    );

Future<void> _openMore(WidgetTester tester) async {
  await tester.tap(find.text('⋯'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('🔴 todo 只外露「開始」，其餘四顆收進選單', (tester) async {
    await tester.pumpWidget(_wrap(_task()));
    await tester.pumpAndSettle();

    // 這個狀態下你多半要做的那一件事——外露的就是它
    expect(find.text('開始'), findsOneWidget);

    const hidden = ['直接完成', '標記卡住', '搬到別處', '取消任務'];
    for (final label in hidden) {
      expect(find.text(label), findsNothing, reason: '$label 不該直接外露');
    }

    await _openMore(tester);
    for (final label in hidden) {
      expect(find.text(label), findsOneWidget, reason: '$label 應該收在選單裡');
    }
  });

  testWidgets('主要動作跟著狀態走，不是寫死一顆', (tester) async {
    await tester.pumpWidget(_wrap(_task(status: 'blocked')));
    await tester.pumpAndSettle();

    // `blocked` 的主要動作是解除卡住——不是「開始」，那句話在這裡沒有意義
    expect(find.text('解除卡住'), findsOneWidget);
    expect(find.text('開始'), findsNothing);
  });

  testWidgets('沒有東西可收的時候不畫 ⋯——空選單比多一顆按鈕更沒有道理',
      (tester) async {
    // `done` 只剩「重新開啟」一顆，而已收尾的卡不出指派入口
    await tester.pumpWidget(_wrap(_task(status: 'done')));
    await tester.pumpAndSettle();

    expect(find.text('重新開啟'), findsOneWidget);
    expect(find.text('⋯'), findsNothing);
  });
}
