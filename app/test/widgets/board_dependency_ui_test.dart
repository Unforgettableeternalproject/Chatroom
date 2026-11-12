import 'package:chatroom_app/core/errors/api_exception.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/screens/board/board_action_feedback.dart';
import 'package:chatroom_app/screens/board/board_dependency_picker.dart';
import 'package:chatroom_app/screens/board/board_task_drawer.dart';
import 'package:chatroom_app/screens/board/board_task_edit_dialog.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:chatroom_app/widgets/board_task_card.dart';
import 'package:chatroom_app/widgets/mention_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import '../helpers/l10n.dart';

/// 任務依賴／影響的畫面層：阻擋標記、依賴造成的卡住、按鈕在按之前就看得出
/// 擋住、抽屜裡的依賴清單、編輯送出、錯誤碼訊息。
BoardTask _task(
  String id, {
  String status = 'todo',
  Map<String, dynamic>? extra,
}) =>
    BoardTask.fromJson({
      'id': id,
      'checklist_id': 'c1',
      'title': '卡 $id',
      'status': status,
      ...?extra,
    });

Map<String, dynamic> _dep(String id,
        {String status = 'todo', bool met = false, String via = ''}) =>
    {
      'id': id,
      'title': '依賴 $id',
      'status': status,
      'met': met,
      'cancelled': status == 'cancelled',
      'via': via,
    };

Widget _app(Widget child, {List<Override> overrides = const []}) =>
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: kTestSupportedLocales,
        theme: buildUepTheme(Brightness.dark),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

Widget _drawer(BoardTask task,
        {void Function(String)? onOpenTask, List<Override> overrides = const []}) =>
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: kTestSupportedLocales,
        theme: buildUepTheme(Brightness.dark),
        home: Scaffold(
          body: BoardTaskDrawer(
            roomId: null,
            boardId: 'b1',
            task: task,
            checklistTitle: '階段',
            onClose: () {},
            onOpenTask: onOpenTask,
          ),
        ),
      ),
    );

void main() {
  group('卡片列', () {
    testWidgets('🔴 阻擋中：顯示「阻擋」、不給認領按鈕、說還在等幾項', (tester) async {
      var claimed = false;
      await tester.pumpWidget(_app(BoardTaskCard(
        task: _task('t1', extra: {
          'dependency_blocked': true,
          'depends_on': [_dep('a')],
          'unmet': [_dep('a'), _dep('b')],
        }),
        onClaim: () => claimed = true,
      )));
      expect(find.text('阻擋'), findsOneWidget);
      expect(find.text('等 2 項依賴完成'), findsOneWidget);
      // 認領按鈕不畫——不是畫了按不動
      expect(find.text('認領'), findsNothing);
      expect(claimed, isFalse);
      // 阻擋不是卡住：狀態徽章仍然是待辦
      expect(find.text('待辦'), findsOneWidget);
      expect(find.text('卡住'), findsNothing);
    });

    testWidgets('沒被擋的卡照舊有認領按鈕、沒有阻擋標記', (tester) async {
      await tester.pumpWidget(_app(BoardTaskCard(
        task: _task('t1'),
        onClaim: () {},
      )));
      expect(find.text('認領'), findsOneWidget);
      expect(find.text('阻擋'), findsNothing);
    });

    testWidgets('🔴 依賴造成的卡住：卡住標記旁註明「依賴造成」', (tester) async {
      await tester.pumpWidget(_app(BoardTaskCard(
        task: _task('t1',
            status: 'blocked', extra: {'blocked_by_dependency': true}),
      )));
      expect(find.text('卡住'), findsOneWidget);
      expect(find.text('依賴造成'), findsOneWidget);
      // 這時不算「阻擋」（阻擋只指待辦且依賴未滿足）
      expect(find.text('阻擋'), findsNothing);
    });

    testWidgets('人手動標的卡住不帶「依賴造成」', (tester) async {
      await tester.pumpWidget(_app(BoardTaskCard(
        task: _task('t1', status: 'blocked'),
      )));
      expect(find.text('卡住'), findsOneWidget);
      expect(find.text('依賴造成'), findsNothing);
    });
  });

  group('抽屜', () {
    testWidgets('🔴 阻擋中：點「開始」不打 API，直接講「依賴還沒完成」', (tester) async {
      await tester.pumpWidget(_drawer(_task('t1', extra: {
        'dependency_blocked': true,
        'unmet': [_dep('a')],
        'depends_on': [_dep('a')],
      })));
      await tester.pumpAndSettle();

      expect(find.text('阻擋'), findsOneWidget);
      await tester.tap(find.text('開始'));
      await tester.pump();
      expect(find.text('依賴還沒完成'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('阻擋中：卡住 / 取消不受影響（只擋開始與完成）', (tester) async {
      await tester.pumpWidget(_drawer(_task('t1', extra: {
        'dependency_blocked': true,
        'unmet': [_dep('a')],
      })));
      await tester.pumpAndSettle();
      await tester.tap(find.text('⋯'));
      await tester.pumpAndSettle();
      expect(find.text('標記卡住'), findsOneWidget);
      expect(find.text('取消任務'), findsOneWidget);
    });

    testWidgets('🔴 依賴造成的卡住：「解除卡住」點了講原因，並標註依賴造成',
        (tester) async {
      await tester.pumpWidget(_drawer(_task('t1',
          status: 'blocked', extra: {'blocked_by_dependency': true})));
      await tester.pumpAndSettle();
      expect(find.text('依賴造成'), findsOneWidget);
      await tester.tap(find.text('解除卡住'));
      await tester.pump();
      expect(find.text('依賴還沒完成'), findsOneWidget);
    });

    testWidgets('列出依賴與影響；每項狀態與跳卡', (tester) async {
      final opened = <String>[];
      await tester.pumpWidget(_drawer(
        _task('t1', extra: {
          'depends_on': [
            _dep('a', status: 'done', met: true),
            _dep('b', status: 'in_progress'),
            _dep('c', status: 'cancelled', met: true),
            _dep('d', status: 'moved'),
          ],
          'affects': [
            {'id': 'x', 'title': '被影響 X', 'status': 'todo'}
          ],
        }),
        onOpenTask: opened.add,
      ));
      await tester.pumpAndSettle();

      expect(find.text('依賴'), findsOneWidget);
      expect(find.text('影響'), findsOneWidget);
      expect(find.text('依賴 a'), findsOneWidget);
      expect(find.text('已完成'), findsWidgets);
      expect(find.text('未完成'), findsOneWidget);
      expect(find.text('已取消'), findsOneWidget);
      expect(find.text('搬走，未寫去向'), findsOneWidget);
      expect(find.text('被影響 X'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('dep-row-b')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('dep-row-x')));
      expect(opened, ['b', 'x']);
    });

    testWidgets('🔴 顯示以手上最新資料為準：快照說未完成、板上那張已完成 ⇒ 已完成',
        (tester) async {
      final snap = const BoardSnapshot().merge(BoardDelta.fromJson({
        'board_seq': 1,
        'full': true,
        'board_id': 'b1',
        'objectives': [
          {'id': 'o1', 'title': '週期'}
        ],
        'checklists': [
          {'id': 'c1', 'objective_id': 'o1', 'title': '階段'}
        ],
        'tasks': [
          {
            'id': 'b',
            'checklist_id': 'c1',
            'title': '依賴 b（最新）',
            'status': 'done'
          },
        ],
      }));
      await tester.pumpWidget(_drawer(
        _task('t1', extra: {
          'depends_on': [_dep('b', status: 'in_progress')],
        }),
        overrides: [
          boardByIdProvider('b1').overrideWith((ref) async => snap),
        ],
      ));
      await tester.pumpAndSettle();
      final state = tester.widget<Text>(find.byKey(const ValueKey('dep-state-b')));
      expect(state.data, '已完成');
      expect(find.text('依賴 b（最新）'), findsOneWidget);
    });

    testWidgets('沒有依賴也沒有影響：整段不畫', (tester) async {
      await tester.pumpWidget(_drawer(_task('t1')));
      await tester.pumpAndSettle();
      expect(find.text('依賴'), findsNothing);
      expect(find.text('影響'), findsNothing);
    });
  });

  group('編輯：送出 depends_on / affects', () {
    final spec = DependencyEditSpec(
      candidates: const [
        CardCandidate(boardId: 'b1', taskId: 'a', title: '卡片甲'),
        CardCandidate(boardId: 'b1', taskId: 'b', title: '卡片乙'),
      ],
      titles: const {'a': '卡片甲', 'b': '卡片乙'},
      dependsOn: const ['a'],
    );

    testWidgets('沒動依賴 ⇒ 兩個欄位都不送（null）', (tester) async {
      TaskEdit? result;
      await tester.pumpWidget(_app(Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await showTaskEditDialog(context,
              title: '標題', description: '', dependencies: spec),
          child: const Text('開'),
        ),
      )));
      await tester.tap(find.text('開'));
      await tester.pumpAndSettle();
      // 已設定的依賴顯示成 chip
      expect(find.byKey(const ValueKey('dep-chip-a')), findsOneWidget);
      // 只改標題
      await tester.enterText(find.byType(TextField).first, '新標題');
      await tester.tap(find.text('儲存'));
      await tester.pumpAndSettle();
      expect(result!.title, '新標題');
      expect(result!.dependsOn, isNull);
      expect(result!.affects, isNull);
    });

    testWidgets('🔴 移除依賴 ⇒ 送空清單（清空），不是 null', (tester) async {
      TaskEdit? result;
      await tester.pumpWidget(_app(Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await showTaskEditDialog(context,
              title: '標題', description: '', dependencies: spec),
          child: const Text('開'),
        ),
      )));
      await tester.tap(find.text('開'));
      await tester.pumpAndSettle();
      // 刪掉 chip
      await tester.tap(find.descendant(
          of: find.byKey(const ValueKey('dep-chip-a')),
          matching: find.byType(Icon)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('儲存'));
      await tester.pumpAndSettle();
      expect(result!.dependsOn, <String>[]);
      expect(result!.affects, isNull);
      expect(result!.isEmpty, isFalse);
    });

    testWidgets('從選擇器加入影響 ⇒ 送 affects；已選的依賴不出現在影響的候選',
        (tester) async {
      TaskEdit? result;
      await tester.pumpWidget(_app(Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await showTaskEditDialog(context,
              title: '標題', description: '', dependencies: spec),
          child: const Text('開'),
        ),
      )));
      await tester.tap(find.text('開'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('dep-add-影響')));
      await tester.pumpAndSettle();
      // a 已是依賴：同一張卡不能同時是依賴與影響（會形成循環）
      expect(find.byKey(const ValueKey('pick-a')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('pick-b')));
      await tester.pump();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('dep-chip-b')), findsOneWidget);

      await tester.tap(find.text('儲存'));
      await tester.pumpAndSettle();
      expect(result!.affects, ['b']);
      expect(result!.dependsOn, isNull);
    });

    testWidgets('週期／階段的編輯（沒給 dependencies）不出這兩欄', (tester) async {
      await tester.pumpWidget(_app(Builder(
        builder: (context) => TextButton(
          onPressed: () => showTaskEditDialog(context,
              title: '週期', description: ''),
          child: const Text('開'),
        ),
      )));
      await tester.tap(find.text('開'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('dep-add-依賴')), findsNothing);
    });
  });

  group('錯誤碼與連動提示', () {
    Future<void> say(WidgetTester tester, ApiException e) async {
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: kTestSupportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(boardActionMessage(context, e)))),
              child: const Text('按'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('按'));
      await tester.pump();
    }

    final cases = <(ApiException, String)>[
      (const ConflictException('dependency_cycle', 'x'), '會形成循環依賴'),
      (const ConflictException('dependency_self', 'x'), '不能依賴自己'),
      (const ConflictException('dependency_other_board', 'x'), '只能依賴同一塊板的卡'),
      (const ConflictException('dependencies_unmet', 'x'), '依賴還沒完成'),
      (
        const ConflictException('dependency_no_board', 'x'),
        '這張卡不在任何板上，不能設定依賴'
      ),
    ];
    for (final (e, text) in cases) {
      testWidgets('${e.code} ⇒ $text', (tester) async {
        await say(tester, e);
        expect(find.text(text), findsOneWidget);
      });
    }

    testWidgets('404 dependency_not_found', (tester) async {
      await say(tester, const NotFoundException('dependency_not_found'));
      expect(find.text('找不到那張卡'), findsOneWidget);
    });

    testWidgets('🔴 not_board_editor 帶 item_id（改影響時對方的卡）⇒ 這張卡你沒有權限改',
        (tester) async {
      await say(
          tester,
          const BoardAccessException(
              'not_board_editor', 'Hub 原話', {'item_id': 't9'}));
      expect(find.text('這張卡你沒有權限改'), findsOneWidget);
    });

    testWidgets('not_board_editor 沒帶 item_id（編輯週期）維持 Hub 原話', (tester) async {
      await say(tester,
          const BoardAccessException('not_board_editor', 'Hub 原話'));
      expect(find.text('Hub 原話'), findsOneWidget);
    });

    Future<void> toast(WidgetTester tester, List<DependencyChange> c) async {
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: kTestSupportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDependencyChangesToast(context, c),
              child: const Text('按'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('按'));
      await tester.pump();
    }

    testWidgets('dependency_changes 非空 ⇒ 「N 張卡因依賴自動卡住」', (tester) async {
      await toast(tester, const [
        DependencyChange(id: 'a', reason: 'dependency_unmet'),
        DependencyChange(id: 'b', reason: 'dependency_unmet'),
      ]);
      expect(find.text('2 張卡因依賴自動卡住'), findsOneWidget);
    });

    testWidgets('自動恢復也要說', (tester) async {
      await toast(tester,
          const [DependencyChange(id: 'a', reason: 'dependency_met')]);
      expect(find.text('1 張卡依賴已完成，自動恢復'), findsOneWidget);
    });

    testWidgets('空的連動什麼都不顯示', (tester) async {
      await toast(tester, const []);
      expect(find.byType(SnackBar), findsNothing);
    });
  });
}
