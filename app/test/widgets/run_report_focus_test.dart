import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/agent_run.dart';
import 'package:chatroom_app/models/message.dart';
import 'package:chatroom_app/state/runs_providers.dart';
import 'package:chatroom_app/widgets/message_bubble.dart';
import 'package:chatroom_app/widgets/run_report_panel.dart';
import 'package:chatroom_app/widgets/system_message_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/l10n.dart';

/// 回報卡 -> 聊天列表跳轉的接線。
void main() {
  AgentRun run(String id, String kind, String? agent) => AgentRun(
        id: id,
        roomId: 'r1',
        kind: kind,
        project: 'chatroom',
        ref: 'ref-$id',
        agentName: agent,
        status: 'done',
        result: '收工摘要 $id',
        endedAt: '2026-09-17T01:00:00+00:00',
        updatedAt: '2026-09-17T01:00:00+00:00',
      );

  Widget harness(List<AgentRun> runs, ValueChanged<AgentRun>? onFocus) =>
      ProviderScope(
        overrides: [
          finishedRunsProvider('r1').overrideWith((ref) async => runs),
        ],
        child: MaterialApp(
          localizationsDelegates: kTestLocalizationsDelegates,
          supportedLocales: kTestSupportedLocales,
          theme: buildUepTheme(Brightness.dark),
          home: Scaffold(
            body: Stack(children: [
              SizedBox(
                width: 288,
                child: RunReportPanel(roomId: 'r1', onFocusRun: onFocus),
              ),
              const Positioned.fill(child: RunReportOverlay(roomId: 'r1')),
            ]),
          ),
        ),
      );

  testWidgets('點 agent 報告與 push 報告：各自把那一筆 run 交給跳轉，面板照開', (tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final asked = <String>[];
    await tester.pumpWidget(harness(
      [run('t1', 'ticket', 'Amber-Badger'), run('p1', 'push', null)],
      (r) => asked.add(r.id),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Amber-Badger'));
    await tester.pumpAndSettle();
    expect(asked, ['t1']);
    expect(find.byType(RunReportDetailPanel), findsOneWidget);

    await tester.tap(find.text('push · ref-p1'));
    await tester.pumpAndSettle();
    expect(asked, ['t1', 'p1']);
    expect(find.textContaining('收工摘要 p1'), findsOneWidget);
  });

  testWidgets('沒掛 onFocusRun：只開面板，不出錯', (tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness([run('t1', 'ticket', 'Amber-Badger')], null));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Amber-Badger'));
    await tester.pumpAndSettle();
    expect(find.byType(RunReportDetailPanel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('system 訊息套 FocusPulse：播與一般訊息同一個金色呼吸環', (tester) async {
    const msg = Message(
      id: 'm1',
      seq: 1,
      updateSeq: 0,
      kind: 'system',
      content: '派工 push／chatroom 完成。',
      createdAt: '2026-09-17T01:00:00+00:00',
      systemEvent: 'run_done',
    );
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: kTestLocalizationsDelegates,
      supportedLocales: kTestSupportedLocales,
      theme: buildUepTheme(Brightness.dark),
      home: const Scaffold(
        body: FocusPulse(child: SystemMessageTile(message: msg)),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('focus-pulse-ring')), findsOneWidget);
  });
}
