import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/screens/board/board_screen.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 🔴 Bernie 2026-09-07（想法板 #13 段）：已結局的板，從**封存的聊天室**
/// 回去看時右上角要標得出結局狀態。
///
/// 查下去發現封存只是最明顯的切面：結局膠囊的顯示條件是 `myRole == 'owner'`，
/// 所以**非 owner 在任何地方都看不到這塊板有沒有結局**。
///
/// 那是今天在 App 端撞到的第四次同一個形狀——**把「狀態顯示」與「動作入口」
/// 綁在同一個旗標上**（板軸收尾動作、封存房指派入口、supervisor 追蹤入口
/// 都是）。結局是**事實**，不是權限：誰都該看得到；能不能改它才是權限。
///
/// 決策 2026-09-07 裁：有結局＝所有人看得到（唯讀）；owner 才可點；
/// 沒有結局時對非 owner 不畫——不畫一顆他按不動的「宣告結局」。
BoardSnapshot _snap({required String role, String outcome = ''}) =>
    const BoardSnapshot().merge(BoardDelta.fromJson({
      'board_seq': 10,
      'full': true,
      'board_id': 'b1',
      'my_role': role,
      'outcome': outcome,
      'objectives': [
        {'id': 'o1', 'title': '週期', 'status': 'active'},
      ],
    }));

Future<void> _pump(WidgetTester tester, BoardSnapshot snap) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      boardByIdProvider('b1').overrideWith((ref) async => snap),
    ],
    child: MaterialApp(
      theme: buildUepTheme(Brightness.dark),
      home: const BoardScreen(boardId: 'b1'),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('🔴 非 owner 也要看得到結局——那是事實不是權限', (tester) async {
    await _pump(tester, _snap(role: 'editor', outcome: 'completed'));

    expect(tester.takeException(), isNull);
    expect(find.text('完成'), findsOneWidget);
  });

  testWidgets('廢止也一樣看得到——兩種結局不可以只露一種', (tester) async {
    // 只露「完成」的話，被廢止的板讀起來會像「還在進行」，
    // 而那正是最需要看清楚的一種
    await _pump(tester, _snap(role: 'editor', outcome: 'abandoned'));

    expect(find.text('廢止'), findsOneWidget);
  });

  testWidgets('非 owner 而板還沒有結局：不畫按不動的「宣告結局」', (tester) async {
    await _pump(tester, _snap(role: 'editor'));

    expect(find.text('宣告結局'), findsNothing);
  });

  testWidgets('owner 沒有結局時仍有入口——這條不可以被上面那條一起改掉',
      (tester) async {
    await _pump(tester, _snap(role: 'owner'));

    expect(find.text('宣告結局'), findsOneWidget);
  });
}
