import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/export/run_report_export.dart';
import 'package:chatroom_app/models/agent_run.dart';
import 'package:chatroom_app/state/runs_providers.dart';
import 'package:chatroom_app/widgets/run_report_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/l10n.dart';

/// 回報要帶得走：整段複製、存成 `.md`、以及把列出的幾筆合成一份。
///
/// 存檔那一步走注入的 [RunReportSaver]——測試不開系統對話框，但要驗到
/// 送進去的檔名與內容確實是那一筆。
void main() {
  AgentRun run(int i, {String result = ''}) => AgentRun(
        id: 'run-${i}0123456789',
        roomId: 'r1',
        kind: 'ticket',
        project: 'chatroom',
        ref: 'T-$i',
        agentName: 'Amber-$i',
        status: 'done',
        usage: const {'num_turns': 12, 'total_cost_usd': 1.5},
        result: result.isEmpty ? '# 第 $i 筆\n\n做完了。' : result,
        reason: '',
        endedAt: '2026-09-17T01:00:00+00:00',
        updatedAt: '2026-09-17T01:00:00+00:00',
      );

  group('組裝（純函式）', () {
    test('單筆：標頭有種類／目標／時間／狀態，原文原樣接在後面', () {
      final text = formatRunReport(run(1));

      expect(text, contains('# chatroom run run-1012'));
      expect(text, contains('- kind: ticket'));
      expect(text, contains('- project: chatroom'));
      expect(text, contains('- ref: T-1'));
      expect(text, contains('- agent: Amber-1'));
      expect(text, contains('- status: done'));
      expect(text, contains('- ended_at: 2026-09-17T01:00:00+00:00'));
      // result 不重排、不截斷
      expect(text, contains('# 第 1 筆\n\n做完了。'));
    });

    test('沒有 result 的那幾筆：reason 進標頭，也當內文', () {
      const failed = AgentRun(
        id: 'run-f',
        roomId: 'r1',
        kind: 'ticket',
        project: 'chatroom',
        ref: 'T-9',
        status: 'failed',
        reason: '執行器逾時',
      );
      final text = formatRunReport(failed);

      expect(text, contains('- status: failed'));
      expect(text, contains('- reason: 執行器逾時'));
      expect(text.trimRight(), endsWith('執行器逾時'));
    });

    test('全部匯出：每一筆都在，順序照清單', () {
      final text = formatRunReports([run(0), run(1)]);

      expect(text, startsWith('# chatroom runs (2)'));
      expect(text, contains('# 第 0 筆'));
      expect(text, contains('# 第 1 筆'));
      expect(text.indexOf('# 第 0 筆'), lessThan(text.indexOf('# 第 1 筆')));
    });

    test('檔名是 run id 的前 8 碼', () {
      expect(runReportFileName(run(1)), 'chatroom-run-run-1012.md');
      expect(runReportsFileName(DateTime(2026, 9, 17)),
          'chatroom-runs-20260917.md');
    });
  });

  group('面板', () {
    late List<Map<String, String>> saved;

    Widget harness(List<AgentRun> runs) => ProviderScope(
          overrides: [
            finishedRunsProvider('r1').overrideWith((ref) async => runs),
            runReportSaverProvider.overrideWithValue(({
              required String fileName,
              required String text,
              required String dialogTitle,
            }) async {
              saved.add({'fileName': fileName, 'text': text});
              return 'C:/tmp/$fileName';
            }),
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
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: const RunReportPanel(roomId: 'r1'),
                        ),
                      ),
                    ],
                  ),
                  const Positioned.fill(child: RunReportOverlay(roomId: 'r1')),
                ],
              ),
            ),
          ),
        );

    Future<void> sized(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    setUp(() => saved = []);

    testWidgets('清單上方有「全部匯出」，打開的那一筆有「複製」「匯出」',
        (tester) async {
      await sized(tester);
      await tester.pumpWidget(harness([run(0), run(1)]));
      await tester.pumpAndSettle();

      expect(find.text('全部匯出'), findsOneWidget);
      // 還沒打開任何一筆時，那兩顆鈕不存在
      expect(find.text('複製'), findsNothing);

      await tester.tap(find.text('Amber-0'));
      await tester.pumpAndSettle();
      expect(find.text('複製'), findsOneWidget);
      expect(find.text('匯出'), findsOneWidget);
    });

    testWidgets('按複製：整段 result 進剪貼簿', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      await sized(tester);
      await tester.pumpWidget(harness([run(0)]));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Amber-0'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('複製'));
      await tester.pumpAndSettle();

      expect(copied, run(0).result);
      expect(find.text('已複製'), findsOneWidget);
    });

    testWidgets('按匯出：檔名帶 run 短碼，內容是那一筆的組裝結果',
        (tester) async {
      await sized(tester);
      await tester.pumpWidget(harness([run(0), run(1)]));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Amber-1'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('匯出'));
      await tester.pumpAndSettle();

      expect(saved, hasLength(1));
      expect(saved.single['fileName'], 'chatroom-run-run-1012.md');
      expect(saved.single['text'], formatRunReport(run(1)));
      expect(find.text('已匯出'), findsOneWidget);
    });

    testWidgets('按全部匯出：列出的幾筆合成一份', (tester) async {
      await sized(tester);
      await tester.pumpWidget(harness([run(0), run(1)]));
      await tester.pumpAndSettle();

      await tester.tap(find.text('全部匯出'));
      await tester.pumpAndSettle();

      expect(saved, hasLength(1));
      expect(saved.single['fileName'], startsWith('chatroom-runs-'));
      expect(saved.single['text'], formatRunReports([run(0), run(1)]));
    });

    testWidgets('沒有回報時不給「全部匯出」——那會存出一份空檔', (tester) async {
      await sized(tester);
      await tester.pumpWidget(harness([]));
      await tester.pumpAndSettle();

      expect(find.text('全部匯出'), findsNothing);
    });

    testWidgets('內文包在 SelectionArea 裡，可以局部選取', (tester) async {
      await sized(tester);
      await tester.pumpWidget(harness([run(0)]));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Amber-0'));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(RunReportDetailPanel),
          matching: find.byType(SelectionArea),
        ),
        findsOneWidget,
      );
    });
  });
}
