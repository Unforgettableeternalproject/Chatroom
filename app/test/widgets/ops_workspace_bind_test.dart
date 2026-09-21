import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/agent_run.dart';
import 'package:chatroom_app/screens/ops/ops_dashboard_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/l10n.dart';

/// 儀表板上的「這個房間派工到哪裡」。
///
/// 綁定是**一次性**的（Hub 對第二次回 409 `workspace_already_bound`），
/// 所以這一段要分得出三件事：已經綁在哪、還沒綁而我能綁、還沒綁而我不能綁。
/// 壓成同一句話的話，非房主會對著一顆必定 403 的按鈕按，而房主找不到入口。

AgentRunner _runner({
  String id = 'runner-1',
  String status = 'online',
  List<String> projects = const ['ai-website'],
}) =>
    AgentRunner(id: id, status: status, projects: projects);

RoomRunnerBoard _board({
  List<AgentRunner> runners = const [],
  List<String> candidates = const ['ai-website'],
}) =>
    RoomRunnerBoard(
        roomId: 'room-1', runners: runners, workspaceCandidates: candidates);

Widget _wrap(Widget child) => MaterialApp(
      localizationsDelegates: kTestLocalizationsDelegates,
      supportedLocales: kTestSupportedLocales,
      theme: buildUepTheme(Brightness.dark),
      home: Scaffold(body: child),
    );

void main() {
  group('還沒綁', () {
    testWidgets('房主看得到綁定區塊與候選工作區', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(
            runners: [_runner()], candidates: const ['ai-website', 'uep']),
        youAreAdmin: true,
        onBindWorkspace: (_) {},
      )));

      expect(find.text('綁定工作區'), findsOneWidget);
      expect(find.text('綁定後不可更改。'), findsOneWidget);
      // Hub 給了兩個候選——多個就不預設，選錯會綁死
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('ai-website'), findsWidgets);
      expect(find.text('uep'), findsWidgets);
    });

    testWidgets('🔴 候選來自 Hub 的 workspace_candidates，不是自己從 runners 算——'
        '未綁定時 runners 是空的，自己算就永遠綁不了', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        // 一台執行器都沒有（Hub 未綁定時就是這樣回），候選照樣要有
        board: _board(candidates: const ['ai-website', 'uep']),
        youAreAdmin: true,
        onBindWorkspace: (_) {},
      )));

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('uep'), findsWidgets);
    });

    testWidgets('一個候選都沒有時要說出理由，而不是給一個空下拉', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [_runner()], candidates: const []),
        youAreAdmin: true,
        onBindWorkspace: (_) {},
      )));

      expect(find.text('沒有執行器宣告任何工作區。'), findsOneWidget);
      expect(find.byType(DropdownButton<String>), findsNothing);
    });

    testWidgets('非房主：講出在等誰，不畫一顆必定 403 的按鈕', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [_runner()]),
        youAreAdmin: false,
      )));

      expect(find.text('房主尚未綁定工作區。'), findsOneWidget);
      expect(find.text('綁定'), findsNothing);
      expect(find.byType(DropdownButton<String>), findsNothing);
    });
  });

  group('已經綁了', () {
    testWidgets('頁首寫出綁在哪；有人服務時不多說一句', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [_runner()]),
        workspaceKey: 'ai-website',
        workspaceServed: true,
        youAreAdmin: true,
        onBindWorkspace: (_) {},
      )));

      expect(find.text('工作區：ai-website'), findsOneWidget);
      expect(find.text('目前沒有執行器在服務這個工作區。'), findsNothing);
      // 綁過就不能再綁，入口整個不畫
      expect(find.text('綁定工作區'), findsNothing);
    });

    testWidgets('沒有人服務時補一句——派工入口這時是不會出現的', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [_runner(status: 'offline')]),
        workspaceKey: 'ai-website',
        workspaceServed: false,
        youAreAdmin: true,
        onBindWorkspace: (_) {},
      )));

      expect(find.text('工作區：ai-website'), findsOneWidget);
      expect(find.text('目前沒有執行器在服務這個工作區。'), findsOneWidget);
    });
  });

  group('確認框', () {
    testWidgets('綁定前要確認，而且講出綁死的是哪個 key', (tester) async {
      final bound = <String>[];
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [_runner()]),
        youAreAdmin: true,
        onBindWorkspace: bound.add,
      )));

      // 只有一個候選時直接選好——沒有東西可以選錯
      await tester.tap(find.text('綁定'));
      await tester.pumpAndSettle();

      expect(
          find.text('綁定後這個房間只能派工到「ai-website」，不可再更改。'
              '此操作無法復原。'),
          findsOneWidget);
      expect(bound, isEmpty);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      // 取消就是什麼都沒發生。這裡送出去就再也收不回來了
      expect(bound, isEmpty);

      await tester.tap(find.text('綁定'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('綁定').last);
      await tester.pumpAndSettle();
      expect(bound, ['ai-website']);
    });
  });

  testWidgets('沒有執行器在線時，綁定區塊照樣畫得出來——'
      '「這個房綁到哪」正是那時要看的東西', (tester) async {
    await tester.pumpWidget(_wrap(OpsDashboardView(
      board: _board(),
      youAreAdmin: true,
      onBindWorkspace: (_) {},
    )));

    expect(tester.takeException(), isNull);
    expect(find.text('沒有執行器在線'), findsOneWidget);
    expect(find.text('綁定工作區'), findsOneWidget);
  });
}
