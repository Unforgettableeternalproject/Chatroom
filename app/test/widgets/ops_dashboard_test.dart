import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/agent_run.dart';
import 'package:chatroom_app/screens/ops/ops_dashboard_view.dart';
import 'package:chatroom_app/widgets/markdown_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/l10n.dart';

/// 執行儀表板：**三種狀態要講三句不同的話**。
///
/// 這份測試守的是那條線。online／limited／offline 在資料上只差一個字串，
/// 而在畫面上差的是「可以派工」「等退避」「那台機器不在了」——講成同一句
/// 的話，人會對著一台離線的執行器等一個永遠不會開始的 run。
///
/// 另一條是「有沒有未推送的 commit」：push 是房內人類從這裡按的，本機沒有
/// 人看著，所以那份清單與按鈕的狀態是整個面板上最要緊的一格。

AgentRunner _runner({
  String status = 'online',
  String? limitedUntil,
  String limitReason = '',
  int unpushed = 0,
  bool? pushable = true,
  bool dirty = false,
  Map<String, dynamic>? dashboardOverride,
  List<Map<String, dynamic>> commands = const [],
  String startedAt = '2026-09-16T00:00:00+00:00',
  String lastRestartReason = '',
}) =>
    AgentRunner.fromJson({
      'id': 'runner-1',
      'host': 'ASVEL-PC',
      'label': 'main',
      'status': status,
      'max_parallel': 3,
      'running_count': status == 'online' ? 1 : 0,
      'projects': ['ai-website'],
      'limited_until': limitedUntil,
      'limit_reason': limitReason,
      'usage_window': const {},
      'dashboard': dashboardOverride ??
          {
            'generated_at': '2026-09-16T01:05:00+00:00',
            'repos': {
              'ai-website/JSAI-Web': {
                'path': 'C:/x/JSAI-Web',
                'branch': 'jsai_dev',
                'dirty': dirty,
                'dirty_count': dirty ? 2 : 0,
                'unpushed_count': unpushed,
                'unpushed': [
                  for (var i = 0; i < unpushed; i++)
                    {
                      'sha': 'abcdef012345$i',
                      'title': '第 $i 顆',
                      'at': '2026-09-16T00:00:00+00:00',
                    },
                ],
                'pushable': ?pushable,
              },
            },
            'usage': const {
              'window_hours': 5.0,
              'tokens': 120000,
              'cost_usd': 3.5,
              'soft_cap_tokens': 500000,
              'soft_cap_usd': 20.0,
              'over_soft_cap': false,
              'remaining_tokens': 380000,
            },
            'runs': const {
              'running': [],
              'queued_count': 0,
              'max_parallel': 3,
            },
            'runner': {
              'version': '0.1.0',
              'started_at': startedAt,
              'last_restart_reason': lastRestartReason,
              'selfcheck_problems': const <String>[],
            },
          },
      'commands': commands,
      'version': '0.1.0',
      'registered_at': '2026-09-15T00:00:00+00:00',
      'last_seen_at': '2026-09-16T01:05:00+00:00',
    });

Map<String, dynamic> _run({
  String id = 'run-1',
  String status = 'queued',
  bool cancelRequested = false,
  String kind = 'ticket',
  String ref = 'task-9',
  String result = '',
  String runnerId = '',
  String requesterKind = 'human',
  String requesterName = '',
}) =>
    {
      'id': id,
      'room_id': 'room-1',
      'board_id': '',
      'kind': kind,
      'project': 'ai-website',
      'ref': ref,
      'brief': '',
      'requested_by': 'p1',
      'requested_by_actor_key': 'a1',
      'requested_by_name': '艾斯維爾',
      'requester_kind': requesterKind,
      'requester_name': requesterName,
      'status': status,
      'priority': 0,
      'position': 1,
      'runner_id': runnerId,
      'claude_session_id': '',
      'attempt': 0,
      'parent_run_id': '',
      'handoff_depth': 0,
      'cancel_requested': cancelRequested,
      'usage': const {},
      'result': result,
      'reason': '',
      'created_at': '2026-09-16T01:00:00+00:00',
      'claimed_at': null,
      'started_at': status == 'running' ? '2026-09-16T01:00:09+00:00' : null,
      'ended_at': null,
      'updated_at': '2026-09-16T01:00:00+00:00',
    };

RoomRunnerBoard _board({
  List<AgentRunner> runners = const [],
  List<Map<String, dynamic>> activeRuns = const [],
}) =>
    RoomRunnerBoard(
      roomId: 'room-1',
      runners: runners,
      activeRuns: [for (final r in activeRuns) AgentRun.fromJson(r)],
    );

Widget _wrap(Widget child) => MaterialApp(
  localizationsDelegates: kTestLocalizationsDelegates,
  supportedLocales: kTestSupportedLocales,
      theme: buildUepTheme(Brightness.dark),
      home: Scaffold(body: child),
    );

void main() {
  group('執行器狀態', () {
    testWidgets('online：狀態是 ONLINE，暫停按得動、恢復不行', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [_runner()]),
        onCommand: (a, b) {},
      )));
      expect(find.text('上線'), findsOneWidget);
      expect(find.text('暫停'), findsOneWidget);
      expect(find.text('恢復'), findsOneWidget);
      // 已經在線上的執行器沒有「恢復」可言：停用留著（消失會被讀成
      // 「沒有這個功能」），但按不動
      final resume = tester.widget<InkWell>(find.ancestor(
          of: find.text('恢復'), matching: find.byType(InkWell)));
      expect(resume.onTap, isNull);
      final pause = tester.widget<InkWell>(find.ancestor(
          of: find.text('暫停'), matching: find.byType(InkWell)));
      expect(pause.onTap, isNotNull);
    });

    testWidgets('limited：畫倒數，而且頂部狀態列要說為什麼', (tester) async {
      final until = DateTime.now()
          .toUtc()
          .add(const Duration(minutes: 30))
          .toIso8601String();
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(
            runners: [
              _runner(
                  status: 'limited',
                  limitedUntil: until,
                  limitReason: 'rate_limit')
            ]),
      )));
      expect(find.text('受限'), findsOneWidget);
      expect(find.textContaining('後重試'), findsWidgets);
      expect(find.textContaining('速率限制'), findsOneWidget);
    });

    testWidgets('limited 但沒有 limited_until：說「未知」，不編一個倒數',
        (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [_runner(status: 'limited')]),
      )));
      expect(find.text('退避時間未知'), findsOneWidget);
      expect(find.textContaining('後重試'), findsNothing);
    });

    testWidgets('offline：說它離線與最後回報時間', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [_runner(status: 'offline')]),
      )));
      expect(find.text('離線'), findsOneWidget);
      expect(find.textContaining('離線'), findsWidgets);
    });

    testWidgets('一台執行器都沒有：說清楚派工會被擋，不留白', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(board: _board())));
      expect(find.text('沒有執行器在線'), findsOneWidget);
    });

    testWidgets('自檢未過要浮到頂部——在線但做不了事只有這一個線索',
        (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [
          _runner(dashboardOverride: const {
            'repos': <String, dynamic>{},
            'usage': <String, dynamic>{},
            'runs': <String, dynamic>{},
            'runner': {
              'version': '0.1.0',
              'selfcheck_problems': ['GPG 簽章探針失敗'],
            },
          }),
        ]),
      )));
      expect(find.textContaining('GPG 簽章探針失敗'), findsOneWidget);
    });
  });

  group('未推送的 commit', () {
    testWidgets('有未推送：列出短碼與標題，推送鈕按得動', (tester) async {
      RepoView? pushed;
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [_runner(unpushed: 2)]),
        onPush: (_, repo) => pushed = repo,
      )));
      expect(find.text('未推送 2 顆'), findsOneWidget);
      expect(find.text('abcdef01'), findsNWidgets(2)); // 短碼
      expect(find.text('第 0 顆'), findsOneWidget);
      await tester.tap(find.text('推送 2 顆'));
      await tester.pump();
      expect(pushed, isNotNull);
      // 按鈕送出去的就是畫面上那一份清單——執行器會拿它比對
      expect(pushed!.unpushed.map((c) => c.sha),
          ['abcdef0123450', 'abcdef0123451']);
    });

    testWidgets('沒有未推送：不畫推送鈕，也不留一顆按不動的', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [_runner()]),
        onPush: (a, b) {},
      )));
      expect(find.text('沒有未推送的 commit'), findsOneWidget);
      expect(find.text('推送 0 顆'), findsNothing);
    });

    testWidgets('分支不在可推清單：不給推，並說出是哪一條分支', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [_runner(unpushed: 1, pushable: false)]),
        onPush: (a, b) {},
      )));
      expect(find.textContaining('不在執行器的可推清單裡'), findsOneWidget);
      expect(find.text('推送 1 顆'), findsNothing);
    });

    testWidgets('🔴 執行器沒回報 pushable：不給推，而且要說是「沒回報」',
        (tester) async {
      // null ≠ false。畫成「不准推」的話，舊版執行器的每個 repo 都會長得
      // 像被禁止，而畫面上沒有任何一句話說那是因為它沒講
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [_runner(unpushed: 1, pushable: null)]),
        onPush: (a, b) {},
      )));
      expect(find.textContaining('沒有回報這條分支能不能推'), findsOneWidget);
      expect(find.text('推送 1 顆'), findsNothing);
    });

    testWidgets('工作樹有未提交的變更要講出來', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [_runner(unpushed: 1, dirty: true)]),
      )));
      expect(find.text('工作樹有未提交的變更'), findsOneWidget);
    });
  });

  group('佇列', () {
    testWidgets('排隊中的顯示位置，且位置是畫面數的', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [_runner()], activeRuns: [
          _run(id: 'a'),
          _run(id: 'b'),
        ]),
      )));
      expect(find.text('排隊第 1 位'), findsNothing); // 位置併在 meta 那一行
      expect(find.textContaining('排隊第 1 位'), findsOneWidget);
      expect(find.textContaining('排隊第 2 位'), findsOneWidget);
    });

    testWidgets('running 的取消：畫面說「已要求取消」，不說已取消',
        (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [_runner()], activeRuns: [
          _run(id: 'a', status: 'running', cancelRequested: true),
        ]),
        onCancel: (_) {},
      )));
      expect(find.text('已要求取消，等執行器收到後停止'), findsOneWidget);
      // 已經要求過的不再給第二顆取消鈕
      expect(find.text('取消'), findsNothing);
    });

    testWidgets('取消鈕把那一筆交回呼叫端', (tester) async {
      AgentRun? cancelled;
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [_runner()], activeRuns: [_run(id: 'a')]),
        onCancel: (r) => cancelled = r,
      )));
      await tester.tap(find.text('取消'));
      await tester.pump();
      expect(cancelled?.id, 'a');
    });
  });

  group('命令進度：三個時間戳是三句不同的話', () {
    /// 相對時間走的是真的時鐘，所以時間戳都從「現在」往回算。
    String ago(Duration d) =>
        DateTime.now().toUtc().subtract(d).toIso8601String();

    Map<String, dynamic> cmd({
      String id = 'c1',
      String command = 'restart',
      String? acked,
      String? applied,
      String note = '',
      Duration created = const Duration(seconds: 10),
    }) =>
        {
          'id': id,
          'command': command,
          'issued_by_name': '艾斯維爾',
          'created_at': ago(created),
          'acked_at': acked,
          'applied_at': applied,
          'note': note,
        };

    testWidgets('還沒領到：說在等執行器領取，並講出 30 秒這個上限',
        (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [
          _runner(commands: [cmd(command: 'pause')]),
        ]),
        onCommand: (a, b) {},
      )));
      expect(find.text('命令進度'), findsOneWidget);
      expect(find.textContaining('暫停：已送出'), findsOneWidget);
      expect(find.textContaining('等執行器領取（最多 30 秒）'), findsOneWidget);
    });

    testWidgets('🔴 領到了但還沒生效：不能說已生效，要講出執行器在等什麼',
        (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [
          _runner(commands: [
            cmd(acked: ago(const Duration(seconds: 5)), note: '等 2 筆 run 結束後重啟'),
          ]),
        ]),
        onCommand: (a, b) {},
      )));
      expect(find.textContaining('重啟：執行器已收到，等 2 筆 run 結束後重啟'),
          findsOneWidget);
      expect(find.textContaining('已生效'), findsNothing);
    });

    testWidgets('已生效：說已生效並帶上執行器那句話', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [
          _runner(
              status: 'paused',
              commands: [
                cmd(
                    command: 'drain',
                    acked: ago(const Duration(seconds: 40)),
                    applied: ago(const Duration(seconds: 30)),
                    note: '已清掉 3 筆排隊中的 run'),
              ]),
        ]),
        onCommand: (a, b) {},
      )));
      expect(find.textContaining('清空佇列：已生效'), findsOneWidget);
      expect(find.textContaining('已清掉 3 筆排隊中的 run'), findsOneWidget);
    });

    testWidgets('restart 生效後那段離線是預期中的，要說「等它回來」',
        (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [
          _runner(status: 'restarting', commands: [
            cmd(
                acked: ago(const Duration(seconds: 50)),
                applied: ago(const Duration(seconds: 40))),
          ]),
        ]),
        onCommand: (a, b) {},
      )));
      expect(find.text('重啟中'), findsOneWidget);
      expect(find.textContaining('重啟中，等它回來（通常 1～2 分鐘）'), findsOneWidget);
    });

    testWidgets('started_at 比 applied_at 新＝它回來了', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [
          _runner(
              startedAt: ago(const Duration(seconds: 20)),
              commands: [
                cmd(
                    acked: ago(const Duration(seconds: 60)),
                    applied: ago(const Duration(seconds: 50))),
              ]),
        ]),
        onCommand: (a, b) {},
      )));
      expect(find.textContaining('已重啟完成，啟動'), findsOneWidget);
    });

    testWidgets('生效超過 2 分鐘的命令不再佔一行', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [
          _runner(commands: [
            cmd(
                command: 'drain',
                acked: ago(const Duration(minutes: 6)),
                applied: ago(const Duration(minutes: 5)),
                note: '已清掉 3 筆'),
          ]),
        ]),
        onCommand: (a, b) {},
      )));
      expect(find.text('命令進度'), findsNothing);
    });

    testWidgets('同一種命令還沒生效時，那一顆按鈕停用', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [
          _runner(commands: [cmd(command: 'drain')]),
        ]),
        onCommand: (a, b) {},
      )));
      final drain = tester.widget<InkWell>(find.ancestor(
          of: find.text('清空佇列'), matching: find.byType(InkWell)));
      expect(drain.onTap, isNull);
      // 其他種類不受影響——停用的是「再按一次也不會更快」的那一顆
      final restart = tester.widget<InkWell>(find.ancestor(
          of: find.text('重啟'), matching: find.byType(InkWell)));
      expect(restart.onTap, isNotNull);
    });
  });

  group('表頭', () {
    testWidgets('寫出啟動時間與上次重啟的原因（原因轉成中文）', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [
          _runner(lastRestartReason: 'restart_command'),
        ]),
      )));
      expect(find.textContaining('啟動 '), findsOneWidget);
      expect(find.textContaining('上次重啟：人類下令'), findsOneWidget);
    });

    testWidgets('沒有重啟過就不畫那一段', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [_runner()]),
      )));
      expect(find.textContaining('上次重啟'), findsNothing);
    });
  });

  group('用量', () {
    testWidgets('有回報：寫出視窗、tokens、cost 與剩餘', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [_runner()]),
      )));
      expect(find.textContaining('近 5 小時'), findsOneWidget);
      expect(find.textContaining('剩 380000'), findsOneWidget);
    });

    testWidgets('沒回報：說「尚未回報」，不端出一排 0', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [
          _runner(dashboardOverride: const {}),
        ]),
      )));
      expect(find.text('執行器尚未回報用量。'), findsOneWidget);
      expect(find.text('這台執行器還沒有回報過儀表板。'), findsOneWidget);
    });
  });

  group('卡片', () {
    /// 最近結束那一區原本把 `result` 原樣印出來：整段 Markdown（`## 收工摘要`、
    /// 粗體、反引號）沒截、長度不一，於是這一區讀起來像 log。卡片上要的是
    /// 「這筆做了什麼」的頭幾行，全文在點開的回報面板裡。
    testWidgets('最近結束：摘要截短，標題行不進卡片', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [_runner()]),
        finished: [
          AgentRun.fromJson(_run(
              id: 'f1',
              status: 'done',
              result: '## 收工摘要\n\n**做了什麼**：改了 A\n第二行\n'
                  '第三行\n第四行不該出現')),
        ],
      )));
      final body =
          tester.widget<UepMarkdownBody>(find.byType(UepMarkdownBody));
      expect(body.data.contains('#'), isFalse);
      expect(body.data.contains('第四行不該出現'), isFalse);
      expect(body.data.split('\n').length, 3);
      // 狀態與 kind 改成看得懂的中文，不再是 done / ticket
      expect(find.text('完成'), findsOneWidget);
      expect(find.text('實作一張票'), findsOneWidget);
    });

    testWidgets('最近結束：超長的一行也要截，不把卡片撐開', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [_runner()]),
        finished: [
          AgentRun.fromJson(
              _run(id: 'f1', status: 'done', result: '字' * 400)),
        ],
      )));
      final body =
          tester.widget<UepMarkdownBody>(find.byType(UepMarkdownBody));
      expect(body.data.length, lessThanOrEqualTo(161));
      expect(body.data.endsWith('…'), isTrue);
    });

    testWidgets('ref 只顯示前 8 碼，全碼留在 tooltip', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [_runner()]),
        finished: [
          AgentRun.fromJson(
              _run(id: 'f1', status: 'done', ref: '0123456789abcdef')),
        ],
      )));
      expect(find.text('01234567'), findsOneWidget);
      expect(find.text('0123456789abcdef'), findsNothing);
      final tip = tester.widget<Tooltip>(find.ancestor(
          of: find.text('01234567'), matching: find.byType(Tooltip)));
      expect(tip.message, '0123456789abcdef');
    });

    testWidgets('佇列卡片：序號、執行器名與等待時間', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [
          _runner()
        ], activeRuns: [
          _run(id: 'a', runnerId: 'runner-1'),
          _run(id: 'b'),
        ]),
        now: DateTime.parse('2026-09-16T01:20:00+00:00').toLocal(),
      )));
      expect(find.text('排隊'), findsNWidgets(2));
      expect(find.textContaining('排隊第 1 位 · ASVEL-PC · main'),
          findsOneWidget);
      expect(find.textContaining('排隊第 2 位'), findsOneWidget);
      // created_at 是 01:00，now 是 01:20
      expect(find.textContaining('等待 20 分'), findsNWidgets(2));
    });

    testWidgets('執行中的卡片：狀態說「執行中」，並帶上 turns', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [
          _runner(dashboardOverride: {
            'repos': const <String, dynamic>{},
            'usage': const <String, dynamic>{},
            'runs': const {
              'running': [
                {
                  'run_id': 'a',
                  'kind': 'ticket',
                  'ref': 'task-9',
                  'turns': 7,
                  'context_peak_tokens': 12000,
                },
              ],
              'queued_count': 0,
              'max_parallel': 3,
            },
            'runner': const {'version': '0.1.0'},
          }),
        ], activeRuns: [
          _run(id: 'a', status: 'running'),
        ]),
        onSoftStop: (_) {},
        onCancel: (_) {},
      )));
      expect(find.text('執行中'), findsOneWidget);
      expect(find.textContaining('7 turns'), findsOneWidget);
      expect(find.text('請收尾'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
    });
  });

  /// Supervisor 代派（2026-09-19）：卡片上要分得出**誰按的**與**配額算誰的**。
  ///
  /// 把兩者壓成一句「艾斯維爾派的」的話，房內那位人類會在自己沒碰過任何
  /// 按鈕的情況下被寫成派工者——而要去看那一筆為什麼存在的人就沒有線索。
  group('派工者', () {
    testWidgets('agent 代派：標 Supervisor，配額歸屬另外講', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [_runner()], activeRuns: [
          _run(requesterKind: 'agent', requesterName: '米絲媞'),
        ]),
      )));
      expect(find.textContaining('Supervisor 米絲媞 派工'), findsOneWidget);
      expect(find.textContaining('配額算 艾斯維爾'), findsOneWidget);
    });

    testWidgets('人類派工：維持現狀，不多一行', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [_runner()], activeRuns: [_run()]),
      )));
      expect(find.textContaining('Supervisor'), findsNothing);
      expect(find.textContaining('配額算'), findsNothing);
    });

    testWidgets('最近結束的那張卡也要講', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [_runner()]),
        finished: [
          AgentRun.fromJson(_run(
              id: 'done-1',
              status: 'done',
              requesterKind: 'agent',
              requesterName: '米絲媞')),
        ],
      )));
      expect(find.textContaining('Supervisor 米絲媞 派工'), findsOneWidget);
    });

    testWidgets('🔴 Supervisor 沒留名字時不留白，講「未知」', (tester) async {
      await tester.pumpWidget(_wrap(OpsDashboardView(
        board: _board(runners: [_runner()], activeRuns: [
          _run(requesterKind: 'agent'),
        ]),
      )));
      expect(find.textContaining('Supervisor 未知 派工'), findsOneWidget);
    });
  });
}
