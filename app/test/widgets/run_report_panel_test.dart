import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/agent_run.dart';
import 'package:chatroom_app/state/runs_providers.dart';
import 'package:chatroom_app/widgets/run_report_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/l10n.dart';

/// 側欄回報區的**版面**契約。
///
/// 守的是兩條在資料變多時才會壞的線：
/// 1. run 一多，側欄不可以跟著變長——它的高度是視窗給的。
/// 2. 摘要是整段 Markdown，只能在側欄**左側**那塊面板裡捲，不可以在 288 寬
///    的側欄裡向下展開（那正是這次要修掉的行為）。
void main() {
  /// 一筆結束的 run。result 刻意夠長——短內容撐不出側欄會不會被拉長。
  AgentRun run(int i) => AgentRun(
        id: 'run-$i',
        roomId: 'r1',
        kind: 'ticket',
        project: 'chatroom',
        ref: 'T-$i',
        agentName: 'Amber-$i',
        status: 'done',
        usage: const {'num_turns': 12, 'total_cost_usd': 1.5},
        result: '# 第 $i 筆的回報\n\n${'這一段是收工摘要，會有很多行。\n\n' * 40}',
        endedAt: '2026-09-17T01:00:00+00:00',
        updatedAt: '2026-09-17T01:00:00+00:00',
      );

  /// 側欄的真實掛法：成員區與回報區各拿一塊 Expanded，回報區佔 2/5。
  Widget harness(List<AgentRun> runs) => ProviderScope(
        overrides: [
          finishedRunsProvider('r1').overrideWith((ref) async => runs),
        ],
        child: MaterialApp(
          localizationsDelegates: kTestLocalizationsDelegates,
          supportedLocales: kTestSupportedLocales,
          theme: buildUepTheme(Brightness.dark),
          home: Scaffold(
            body: Stack(
              children: [
                Row(
                  children: [
                    const Expanded(child: Center(child: Text('訊息區'))),
                    SizedBox(
                      width: 288,
                      child: Column(
                        children: [
                          Expanded(
                            flex: 3,
                            child: ListView(
                              children: [
                                for (var i = 0; i < 30; i++) Text('成員 $i'),
                              ],
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: const RunReportPanel(roomId: 'r1'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const Positioned.fill(
                  child: RunReportOverlay(roomId: 'r1'),
                ),
              ],
            ),
          ),
        ),
      );

  Future<void> sized(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('10 筆 run：側欄不被撐長，回報區自己捲', (tester) async {
    await sized(tester, const Size(1400, 800));
    await tester.pumpWidget(harness([for (var i = 0; i < 10; i++) run(i)]));
    await tester.pumpAndSettle();

    // 側欄整條仍然是視窗給的高度，回報區不超過分到的那 2/5
    final panel = tester.getSize(find.byType(RunReportPanel));
    expect(panel.height, lessThanOrEqualTo(800 * 2 / 5));
    expect(panel.width, lessThanOrEqualTo(288));
    // 內容捲在自己的 ListView 裡
    expect(
      find.descendant(
        of: find.byType(RunReportPanel),
        matching: find.byType(Scrollable),
      ),
      findsOneWidget,
    );
    // 卡片本身不內嵌 result——側欄裡看不到摘要內容
    expect(find.textContaining('這一段是收工摘要'), findsNothing);
  });

  testWidgets('點卡片：內容開在側欄左側的面板裡，且可捲', (tester) async {
    await sized(tester, const Size(1400, 800));
    await tester.pumpWidget(harness([for (var i = 0; i < 10; i++) run(i)]));
    await tester.pumpAndSettle();

    expect(find.byType(RunReportDetailPanel), findsNothing);
    await tester.tap(find.text('Amber-0'));
    await tester.pumpAndSettle();

    final detail = find.byType(RunReportDetailPanel);
    expect(detail, findsOneWidget);
    final rect = tester.getRect(detail);
    // 貼著側欄左緣（±2 是面板自己那條 1px 外框），寬度 480～560 且不超過
    // 主區的 60%
    expect(rect.right, moreOrLessEquals(1400 - 288, epsilon: 2));
    expect(rect.width, inInclusiveRange(480, 560));
    expect(rect.width, lessThanOrEqualTo((1400 - 288) * .6));
    // 面板高度是視窗高，不是內容高——長 Markdown 在 ScrollView 裡
    expect(rect.height, moreOrLessEquals(800, epsilon: .5));
    expect(
      find.descendant(
        of: detail,
        matching: find.byType(SingleChildScrollView),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('這一段是收工摘要'), findsWidgets);
  });

  testWidgets('點另一張卡：換內容，不是再開一塊', (tester) async {
    await sized(tester, const Size(1400, 800));
    await tester.pumpWidget(harness([for (var i = 0; i < 10; i++) run(i)]));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Amber-0'));
    await tester.pumpAndSettle();
    expect(find.textContaining('第 0 筆的回報'), findsOneWidget);

    await tester.tap(find.text('Amber-1'));
    await tester.pumpAndSettle();
    expect(find.byType(RunReportDetailPanel), findsOneWidget);
    expect(find.textContaining('第 1 筆的回報'), findsOneWidget);
    expect(find.textContaining('第 0 筆的回報'), findsNothing);
  });

  testWidgets('點訊息區（面板外）關閉', (tester) async {
    await sized(tester, const Size(1400, 800));
    await tester.pumpWidget(harness([for (var i = 0; i < 10; i++) run(i)]));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Amber-0'));
    await tester.pumpAndSettle();
    expect(find.byType(RunReportDetailPanel), findsOneWidget);

    await tester.tapAt(const Offset(60, 400));
    await tester.pumpAndSettle();
    expect(find.byType(RunReportDetailPanel), findsNothing);
  });

  /// 實測進房的 run，ref 是一串 32 碼的 id。
  const longRef = '5e61ec64edf54a779b10dd18e5d82aaa';

  AgentRun titled({String? agentName}) => AgentRun(
        id: 'run-x',
        roomId: 'r1',
        kind: 'ticket',
        project: 'chatroom',
        ref: longRef,
        agentName: agentName,
        status: 'done',
        usage: const {'num_turns': 51, 'total_cost_usd': 3.12},
        result: '做完了',
        endedAt: '2026-09-17T01:00:00+00:00',
        updatedAt: '2026-09-17T01:00:00+00:00',
      );

  testWidgets('卡片的標題是那一輪的 agent，不是 ref 的 id', (tester) async {
    await sized(tester, const Size(1400, 800));
    await tester.pumpWidget(harness([titled(agentName: 'Amber-Badger')]));
    await tester.pumpAndSettle();

    expect(find.text('Amber-Badger'), findsOneWidget);
    // 整串 id 不進畫面——它只在 tooltip 裡
    expect(find.text(longRef), findsNothing);
    // 但對得回派工：短碼還在時間那行
    expect(find.textContaining(longRef.substring(0, 8)), findsOneWidget);
  });

  testWidgets('🔴 還沒有 agent：退回 kind ＋短碼，不是整串 id', (tester) async {
    await sized(tester, const Size(1400, 800));
    await tester.pumpWidget(harness([titled()]));
    await tester.pumpAndSettle();

    expect(find.text('ticket · ${longRef.substring(0, 8)}'), findsOneWidget);
    expect(find.text(longRef), findsNothing);
  });

  testWidgets('超過一頁：先給 20 筆，按「更多」再載入', (tester) async {
    await sized(tester, const Size(1400, 800));
    await tester.pumpWidget(harness([for (var i = 0; i < 25; i++) run(i)]));
    await tester.pumpAndSettle();

    final list = find.descendant(
      of: find.byType(RunReportPanel),
      matching: find.byType(Scrollable),
    );
    // 第 20 筆（index 19）在一頁內，第 21 筆要按了才有
    await tester.scrollUntilVisible(find.text('Amber-19'), 200, scrollable: list);
    expect(find.text('Amber-19'), findsOneWidget);

    final more = find.textContaining('更多');
    await tester.scrollUntilVisible(more, 200, scrollable: list);
    await tester.tap(more);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Amber-24'), 200, scrollable: list);
    expect(find.text('Amber-24'), findsOneWidget);
  });
}
