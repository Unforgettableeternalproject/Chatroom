import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/screens/board/board_screen.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/l10n.dart';

/// 窄版（< 900）左欄收掉後，切換週期要有入口；寬版維持左欄。
final _snap = const BoardSnapshot().merge(BoardDelta.fromJson({
  'board_seq': 10,
  'full': true,
  'board_id': 'b1',
  'my_role': 'editor',
  'objectives': [
    {'id': 'o1', 'title': '第一個週期', 'status': 'active'},
    {'id': 'o2', 'title': '第二個週期', 'status': 'active'},
  ],
  'checklists': [
    {'id': 'c1', 'objective_id': 'o1', 'title': '甲階段', 'status': 'open'},
    {'id': 'c2', 'objective_id': 'o2', 'title': '乙階段', 'status': 'open'},
  ],
  'tasks': [],
}));

Widget _wrap() => ProviderScope(
      overrides: [
        boardByIdProvider('b1').overrideWith((ref) async => _snap),
      ],
      child: MaterialApp(
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: kTestSupportedLocales,
        theme: buildUepTheme(Brightness.dark),
        home: const BoardScreen(boardId: 'b1'),
      ),
    );

void main() {
  const switcher = ValueKey('board-objective-switcher');

  testWidgets('窄版有切換列，切換後顯示另一個週期', (tester) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.byKey(switcher), findsOneWidget);
    expect(find.text('甲階段'), findsOneWidget);
    expect(find.text('乙階段'), findsNothing);

    await tester.tap(find.byKey(switcher));
    await tester.pumpAndSettle();
    // 面板裡是同一份週期清單
    await tester.tap(find.text('第二個週期').last);
    await tester.pumpAndSettle();

    expect(find.text('乙階段'), findsOneWidget);
    expect(find.text('甲階段'), findsNothing);
    // 選完面板收起來
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('寬版維持左欄，沒有切換列', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.byKey(switcher), findsNothing);
    expect(find.text('第二個週期'), findsOneWidget);
    await tester.tap(find.text('第二個週期'));
    await tester.pumpAndSettle();
    expect(find.text('乙階段'), findsOneWidget);
  });
}
