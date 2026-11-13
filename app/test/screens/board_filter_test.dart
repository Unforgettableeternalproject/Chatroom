import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/screens/board/board_screen.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/app_config.dart';
import '../helpers/l10n.dart';

/// 任務板篩選：關鍵字、狀態、依賴、認領。測試的 locale 掛繁中（見 helpers/l10n.dart）。
final _snap = const BoardSnapshot().merge(BoardDelta.fromJson({
  'board_seq': 10,
  'full': true,
  'board_id': 'b1',
  'my_role': 'editor',
  'objectives': [
    {'id': 'o1', 'title': '週期', 'status': 'active'},
  ],
  'checklists': [
    {'id': 'c1', 'objective_id': 'o1', 'title': '階段', 'status': 'open'},
  ],
  'tasks': [
    {'id': 't1', 'checklist_id': 'c1', 'title': 'Alpha 卡', 'status': 'todo'},
    {
      'id': 't2',
      'checklist_id': 'c1',
      'title': 'Beta 卡',
      'status': 'in_progress',
      'claim_state': 'held',
      'claim_name': 'Zed',
    },
    {
      'id': 't3',
      'checklist_id': 'c1',
      'title': 'Gamma 卡',
      'status': 'todo',
      'depends_on': [
        {'id': 't1', 'title': 'Alpha 卡', 'status': 'todo', 'met': false}
      ],
    },
  ],
}));

Widget _wrap() => ProviderScope(
      overrides: [
        initialConfigProvider.overrideWithValue(kTestInitialConfig),
        boardByIdProvider('b1').overrideWith((ref) async => _snap),
      ],
      child: MaterialApp(
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: kTestSupportedLocales,
        theme: buildUepTheme(Brightness.dark),
        home: const BoardScreen(boardId: 'b1'),
      ),
    );

Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_wrap());
  await tester.pumpAndSettle();
}

Future<void> _choose(WidgetTester tester, String key, String text) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

void main() {
  const keyword = ValueKey('board-filter-keyword');

  testWidgets('關鍵字：只留標題符合的卡，清除後還原', (tester) async {
    await _pump(tester);
    expect(find.text('Alpha 卡'), findsOneWidget);
    expect(find.text('Beta 卡'), findsOneWidget);

    await tester.enterText(find.byKey(keyword), 'beta');
    await tester.pumpAndSettle();
    expect(find.text('Alpha 卡'), findsNothing);
    expect(find.text('Beta 卡'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('board-filter-clear')));
    await tester.pumpAndSettle();
    expect(find.text('Alpha 卡'), findsOneWidget);
    expect(find.text('Gamma 卡'), findsOneWidget);
  });

  testWidgets('狀態：只留進行中的卡', (tester) async {
    await _pump(tester);
    await _choose(tester, 'board-filter-status', '進行中');
    expect(find.text('Beta 卡'), findsOneWidget);
    expect(find.text('Alpha 卡'), findsNothing);
  });

  testWidgets('依賴：只留有依賴的卡', (tester) async {
    await _pump(tester);
    await _choose(tester, 'board-filter-dependency', '有依賴');
    expect(find.text('Gamma 卡'), findsOneWidget);
    expect(find.text('Alpha 卡'), findsNothing);
    expect(find.text('Beta 卡'), findsNothing);
  });

  testWidgets('認領：已認領／未認領', (tester) async {
    await _pump(tester);
    await _choose(tester, 'board-filter-claimed', '已認領');
    expect(find.text('Beta 卡'), findsOneWidget);
    expect(find.text('Alpha 卡'), findsNothing);

    await _choose(tester, 'board-filter-claimed', '未認領');
    expect(find.text('Beta 卡'), findsNothing);
    expect(find.text('Alpha 卡'), findsOneWidget);
    expect(find.text('Gamma 卡'), findsOneWidget);
  });

  testWidgets('沒有符合的卡：顯示提示', (tester) async {
    await _pump(tester);
    await tester.enterText(find.byKey(keyword), 'zzz');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('board-filter-no-match')), findsOneWidget);
    expect(find.text('Alpha 卡'), findsNothing);
  });
}
