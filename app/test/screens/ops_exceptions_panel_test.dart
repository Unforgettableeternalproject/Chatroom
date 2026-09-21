import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/agent_run.dart';
import 'package:chatroom_app/models/ops_exception.dart';
import 'package:chatroom_app/screens/ops/exceptions_panel.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/ops_exceptions_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../helpers/l10n.dart';

/// 異常面板：列表、倒序、**點一筆展開詳情（不導覽）**、詳情裡的「前往聊天室」
/// 才跳房，以及入口把面板開在右側（不是換一整頁）。
OpsException _e({
  required String id,
  required String kind,
  required String createdAt,
  String severity = 'warn',
  String roomId = 'room-1',
  String roomName = '工作房',
  Map<String, dynamic> detail = const {},
}) =>
    OpsException(
      id: id,
      kind: kind,
      reason: kind,
      severity: severity,
      roomId: roomId,
      roomName: roomName,
      runId: 'run-$id',
      runKind: 'investigate',
      runRef: 'task-$id',
      runnerId: 'runner-1',
      detail: detail,
      createdAt: createdAt,
    );

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late SettingsRepository settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsRepository(await SharedPreferences.getInstance());
  });

  // 導覽結果以 router 當下的位置為準
  late GoRouter router;

  String here() =>
      router.routerDelegate.currentConfiguration.last.matchedLocation;

  Future<void> sized(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// 面板本體單獨掛起來（不經入口）：清單與詳情的行為在這裡驗。
  /// [runKey] ＝要補撈 run 的那一筆（房、run），[run] ＝Hub 會回的內容。
  /// 型別在這裡收斂，測試各自只給資料
  Widget host(
    List<OpsException> list, {
    (String, String)? runKey,
    AgentRun? run,
  }) {
    router = GoRouter(
      initialLocation: '/rooms/room-1/ops',
      routes: [
        GoRoute(
          path: '/rooms',
          builder: (context, state) => const Scaffold(body: Text('房間列表')),
        ),
        GoRoute(
          path: '/rooms/:roomId',
          builder: (context, state) => const Scaffold(body: Text('房間')),
        ),
        GoRoute(
          path: '/rooms/:roomId/ops',
          builder: (context, state) => Scaffold(
            body: OpsExceptionsPanel(onClose: () {}),
          ),
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        settingsRepoProvider.overrideWithValue(settings),
        opsExceptionsProvider.overrideWith((ref) async => list),
        if (runKey != null)
          opsExceptionRunProvider(runKey).overrideWith((ref) async => run),
      ],
      child: MaterialApp.router(
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: kTestSupportedLocales,
        theme: buildUepTheme(Brightness.dark),
        routerConfig: router,
      ),
    );
  }

  /// 儀表板的真實掛法：內容 ＋ 疊在上面的異常面板，入口在頂欄。
  Widget dashboardHost(List<OpsException> list) {
    router = GoRouter(
      initialLocation: '/rooms/room-1/ops',
      routes: [
        GoRoute(
          path: '/rooms/:roomId',
          builder: (context, state) => const Scaffold(body: Text('房間')),
        ),
        GoRoute(
          path: '/rooms/:roomId/ops',
          builder: (context, state) => const Scaffold(
            body: Stack(children: [
              Center(child: Column(children: [
                Text('執行儀表板'),
                OpsExceptionsEntry(),
              ])),
              Positioned.fill(child: OpsExceptionsOverlay()),
            ]),
          ),
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        settingsRepoProvider.overrideWithValue(settings),
        opsExceptionsProvider.overrideWith((ref) async => list),
      ],
      child: MaterialApp.router(
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: kTestSupportedLocales,
        theme: buildUepTheme(Brightness.dark),
        routerConfig: router,
      ),
    );
  }

  testWidgets('空清單要講出範圍，不能看起來像「全部都查過了」', (tester) async {
    await tester.pumpWidget(host(const []));
    await tester.pumpAndSettle();
    expect(find.text('目前沒有派工異常'), findsOneWidget);
    expect(find.textContaining('MCP 未就緒'), findsOneWidget);
  });

  testWidgets('列表按時間倒序', (tester) async {
    await sized(tester, const Size(900, 1200));
    await tester.pumpWidget(host([
      _e(id: 'c', kind: 'runner_offline', severity: 'error',
          createdAt: '2026-09-18T12:00:00Z', roomId: 'room-9',
          roomName: '新房', detail: const {'label': 'esvel-pc'}),
      _e(id: 'b', kind: 'stalled', createdAt: '2026-09-18T11:00:00Z',
          detail: const {'stalled_seconds': 620}),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('執行器 esvel-pc 已離線'), findsOneWidget);
    final first = tester.getTopLeft(find.text('執行器 esvel-pc 已離線')).dy;
    final second =
        tester.getTopLeft(find.textContaining('已 620 秒沒有輸出')).dy;
    expect(first, lessThan(second), reason: '最新的那筆要在最上面');
  });

  testWidgets('點一筆展開詳情，而且不導覽', (tester) async {
    await sized(tester, const Size(900, 1200));
    await tester.pumpWidget(host(
      [
        _e(id: 'c', kind: 'timeout', severity: 'error', roomId: 'room-9',
            roomName: '新房', createdAt: '2026-09-18T12:00:00Z',
            detail: const {'stalled_seconds': 900}),
      ],
      runKey: ('room-9', 'run-c'),
      run: const AgentRun(
        id: 'run-c',
        roomId: 'room-9',
        kind: 'investigate',
        project: 'chatroom',
        ref: 'task-c',
        status: 'failed',
        result: '牆鐘逾時，最後一步停在測試。',
      ),
    ));
    await tester.pumpAndSettle();

    // 收著的時候詳情不在
    expect(find.text('run-c'), findsNothing);

    await tester.tap(find.textContaining('被強制終止'));
    await tester.pumpAndSettle();

    expect(here(), '/rooms/room-1/ops', reason: '點一列不該把人帶走');
    // 事件自己的欄位
    expect(find.text('run-c'), findsOneWidget);
    expect(find.text('timeout'), findsWidgets);
    expect(find.textContaining('investigate · task-c'), findsOneWidget);
    expect(find.textContaining('runner-1'), findsOneWidget);
    expect(find.text('2026-09-18T12:00:00Z'), findsWidgets);
    expect(find.text('900'), findsOneWidget, reason: 'detail 的欄位要逐鍵列出');
    // run 補撈回來的最後回報
    expect(find.textContaining('牆鐘逾時'), findsOneWidget);
  });

  testWidgets('詳情裡的「前往聊天室」才導覽', (tester) async {
    await sized(tester, const Size(900, 1200));
    await tester.pumpWidget(host(
      [
        _e(id: 'c', kind: 'timeout', roomId: 'room-9', roomName: '新房',
            createdAt: '2026-09-18T12:00:00Z'),
      ],
      runKey: ('room-9', 'run-c'),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('被強制終止'));
    await tester.pumpAndSettle();
    expect(here(), '/rooms/room-1/ops');

    await tester.tap(find.text('前往聊天室'));
    await tester.pumpAndSettle();
    expect(here(), '/rooms/room-9');
  });

  testWidgets('入口把面板開在右側，不是換一整頁', (tester) async {
    await sized(tester, const Size(1400, 900));
    await tester.pumpWidget(dashboardHost(
      [_e(id: 'a', kind: 'timeout', createdAt: '2026-09-18T10:00:00Z')],
    ));
    await tester.pumpAndSettle();
    expect(find.byType(OpsExceptionsPanel), findsNothing);

    await tester.tap(find.byTooltip('派工異常'));
    await tester.pumpAndSettle();

    expect(here(), '/rooms/room-1/ops', reason: '面板疊上來，路由不動');
    expect(find.text('執行儀表板'), findsOneWidget, reason: '底下那頁還在');
    final box = tester.getRect(find.byType(OpsExceptionsPanel));
    // ±2：面板外框的左右邊線各吃掉 1 px
    expect(box.right, moreOrLessEquals(1400, epsilon: 2), reason: '貼右緣');
    expect(box.width, moreOrLessEquals(560, epsilon: 4),
        reason: '寬度同回報面板：480～560 且不超過主區 60%');

    // 關閉鈕收起來（面板疊在頂欄那顆入口上，開著的時候按不到它）
    await tester.tap(find.byTooltip('關閉'));
    await tester.pumpAndSettle();
    expect(find.byType(OpsExceptionsPanel), findsNothing);
  });

  testWidgets('入口的未讀計數＝比水位新的那幾筆；看過之後歸零', (tester) async {
    final list = [
      _e(id: 'c', kind: 'timeout', createdAt: '2026-09-18T12:00:00Z'),
      _e(id: 'b', kind: 'stalled', createdAt: '2026-09-18T11:00:00Z'),
    ];
    await sized(tester, const Size(1400, 900));
    await tester.pumpWidget(dashboardHost(list));
    await tester.pumpAndSettle();
    expect(find.text('2'), findsOneWidget);

    // 打開面板＝看過了，水位往前
    await tester.tap(find.byTooltip('派工異常'));
    await tester.pumpAndSettle();
    expect(find.text('2'), findsNothing);
    expect(settings.opsExceptionSeenAt, '2026-09-18T12:00:00Z');
  });
}
