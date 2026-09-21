import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/screens/board/board_screen.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/l10n.dart';

/// 週期凍結（Hub 2026-09-21）：週期只有 `active` 時，它自己與底下的階段、
/// 任務才可寫；`review` / `verified` / `done` / `cancelled` 一律 409
/// `objective_closed`。
///
/// 🔴 釘的是**入口的存在**，不是 API 有沒有被呼叫。留著一顆按下去必然 409
/// 的按鈕，畫面上與能用的按鈕長得一模一樣——尤其「重新開啟階段」：它看起來
/// 正是那個解凍的動作，而真正的解凍在上面一層（打回週期）。
BoardSnapshot _snap(String status) =>
    const BoardSnapshot().merge(BoardDelta.fromJson({
      'board_seq': 10,
      'full': true,
      'board_id': 'b1',
      'my_role': 'editor',
      'objectives': [
        {'id': 'o1', 'title': '凍結測試週期', 'status': status},
      ],
      'checklists': [
        {'id': 'c1', 'objective_id': 'o1', 'title': '收好的階段',
          'status': 'done'},
        {'id': 'c2', 'objective_id': 'o1', 'title': '還開著的階段',
          'status': 'open'},
      ],
      'tasks': [
        {'id': 't1', 'checklist_id': 'c1', 'title': '卡', 'status': 'done'},
      ],
    }));

Widget _app(Widget child) => MaterialApp(
      localizationsDelegates: kTestLocalizationsDelegates,
      supportedLocales: kTestSupportedLocales,
      theme: buildUepTheme(Brightness.dark),
      home: child,
    );

Widget _wrap(BoardSnapshot snap) => ProviderScope(
      overrides: [
        boardByIdProvider('b1').overrideWith((ref) async => snap),
      ],
      child: _app(const BoardScreen(boardId: 'b1')),
    );

void main() {
  testWidgets('done 的週期底下沒有「重新開啟階段」——解凍不在這一層',
      (tester) async {
    await tester.pumpWidget(_wrap(_snap('done')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('重新開啟階段'), findsNothing);
    // 階段的其餘寫入入口也一起收
    expect(find.text('收尾階段'), findsNothing);
    expect(find.text('取消階段'), findsNothing);
    expect(find.text('＋ 任務'), findsNothing);
    // 收掉之後要說出為什麼，而且要指向下一步
    expect(find.text('週期已完成，先打回才能修改'), findsOneWidget);
    // 週期自己的狀態按鈕不受影響——提示叫人打回，那顆按鈕就得在
    expect(find.text('打回'), findsOneWidget);
  });

  testWidgets('review 的週期沒有任何編輯入口（週期自己的也沒有）',
      (tester) async {
    await tester.pumpWidget(_wrap(_snap('review')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('編輯'), findsNothing);
    expect(find.text('＋ 階段'), findsNothing);
    expect(find.text('週期已送審，先打回才能修改'), findsOneWidget);
  });

  testWidgets('對照組：active 的週期入口都在', (tester) async {
    await tester.pumpWidget(_wrap(_snap('active')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // 週期一顆（抬頭）＋ 兩個階段各一顆
    expect(find.text('編輯'), findsNWidgets(3));
    expect(find.text('＋ 階段'), findsOneWidget);
    expect(find.text('重新開啟階段'), findsOneWidget);
    expect(find.text('收尾階段'), findsOneWidget);
    expect(find.text('＋ 任務'), findsOneWidget);
    // 沒凍結就沒有那行提示
    expect(find.text('週期已完成，先打回才能修改'), findsNothing);
  });

  testWidgets('打回之後入口回來', (tester) async {
    var status = 'done';
    final container = ProviderContainer(overrides: [
      boardByIdProvider('b1').overrideWith((ref) async => _snap(status)),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: _app(const BoardScreen(boardId: 'b1')),
    ));
    await tester.pumpAndSettle();
    expect(find.text('重新開啟階段'), findsNothing);

    // 打回：Hub 改了週期狀態，板重拉一次
    status = 'active';
    container.invalidate(boardByIdProvider('b1'));
    await tester.pumpAndSettle();

    expect(find.text('重新開啟階段'), findsOneWidget);
    expect(find.text('編輯'), findsNWidgets(3));
    expect(find.text('週期已完成，先打回才能修改'), findsNothing);
  });
}
