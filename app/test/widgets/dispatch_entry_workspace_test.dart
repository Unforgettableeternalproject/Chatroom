import 'package:chatroom_app/api/rooms_api.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/models/room.dart';
import 'package:chatroom_app/screens/board/board_task_drawer.dart';
import 'package:chatroom_app/state/rooms_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/l10n.dart';

/// 派工入口的條件是**工作房 + 工作區有人服務**。
///
/// 工作房一次性綁定一個工作區之後，Hub 對沒綁的房回 409
/// `workspace_not_bound`；綁了而沒有執行器服務它，單建得起來卻永遠沒有人
/// 領。兩種都是按下去不會有結果的按鈕，所以入口整顆不畫——這裡守的是
/// 「條件是兩個，不是一個」。

BoardTask _task() => BoardTask.fromJson({
      'id': 't1',
      'checklist_id': 'c1',
      'title': '一張卡',
      'status': 'todo',
    });

Room _room({bool ops = true, String? key, bool served = false}) =>
    Room.fromJson({
      'id': 'r1',
      'name': '工作房',
      'kind': ops ? 'ops' : 'chat',
      'created_at': '2026-09-20T00:00:00+00:00',
      'workspace_key': key,
      'workspace_served': served,
    });

Future<void> _openMenu(WidgetTester tester, Room room) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      roomDetailProvider('r1').overrideWith(
          (ref) async => RoomDetail(room: room, participants: const [])),
    ],
    child: MaterialApp(
      localizationsDelegates: kTestLocalizationsDelegates,
      supportedLocales: kTestSupportedLocales,
      theme: buildUepTheme(Brightness.dark),
      home: Scaffold(
        body: BoardTaskDrawer(
          roomId: 'r1',
          boardId: 'b1',
          task: _task(),
          checklistTitle: '階段',
          onClose: () {},
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text('⋯'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('綁好了而且有人服務：派工入口在', (tester) async {
    await _openMenu(
        tester, _room(key: 'ai-website', served: true));
    expect(find.text('派工'), findsOneWidget);
  });

  testWidgets('🔴 綁了但沒有執行器在服務它：入口不畫——'
      '那筆單建得起來卻沒有人會領', (tester) async {
    await _openMenu(tester, _room(key: 'ai-website', served: false));
    expect(find.text('派工'), findsNothing);
  });

  testWidgets('還沒綁工作區：入口不畫。Hub 對它一律 409 workspace_not_bound',
      (tester) async {
    await _openMenu(tester, _room());
    expect(find.text('派工'), findsNothing);
  });

  testWidgets('非工作房不受影響——這件事在一般房間裡本來就不存在',
      (tester) async {
    await _openMenu(tester, _room(ops: false, key: 'ai-website', served: true));
    expect(find.text('派工'), findsNothing);
  });
}
