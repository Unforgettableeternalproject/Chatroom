import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
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

/// 異常面板：列表、倒序、點一筆跳到那間房，以及入口的未讀計數。
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

  String? lastRoute;
  // 導覽結果以 router 當下的位置為準：push 之後底下那頁會跟著重建，
  // 靠 builder 記下的 lastRoute 會指到被蓋住的那一頁
  late GoRouter router;

  String here() =>
      router.routerDelegate.currentConfiguration.last.matchedLocation;

  Widget host(List<OpsException> list,
      {Widget? home, String initialLocation = '/ops/exceptions'}) {
    lastRoute = null;
    router = GoRouter(
      initialLocation: initialLocation,
      routes: [
        GoRoute(
          path: '/ops/exceptions',
          builder: (context, state) {
            lastRoute = '/ops/exceptions';
            return home ?? const OpsExceptionsScreen();
          },
        ),
        GoRoute(
          path: '/rooms',
          builder: (context, state) {
            lastRoute = '/rooms';
            return const Scaffold(body: Text('房間列表'));
          },
        ),
        GoRoute(
          path: '/rooms/:roomId',
          builder: (context, state) {
            lastRoute = '/rooms/${state.pathParameters['roomId']}';
            return const Scaffold(body: Text('房間'));
          },
        ),
        // 執行儀表板攤平成獨立路由：這裡要驗的是返回導向，不是巢狀路由的
        // 堆疊行為
        GoRoute(
          path: '/rooms/:roomId/ops',
          builder: (context, state) {
            lastRoute = '/rooms/${state.pathParameters['roomId']}/ops';
            return const Scaffold(
                body: Center(
                    child: Column(children: [
              Text('執行儀表板'),
              OpsExceptionsEntry(),
            ])));
          },
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        settingsRepoProvider.overrideWithValue(settings),
        opsExceptionsProvider.overrideWith((ref) async => list),
      ],
      child: MaterialApp.router(
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

  testWidgets('列表按時間倒序，點一筆跳到那間房', (tester) async {
    await tester.pumpWidget(host([
      _e(id: 'c', kind: 'runner_offline', severity: 'error',
          createdAt: '2026-09-18T12:00:00Z', roomId: 'room-9',
          roomName: '新房', detail: const {'label': 'esvel-pc'}),
      _e(id: 'b', kind: 'stalled', createdAt: '2026-09-18T11:00:00Z',
          detail: const {'stalled_seconds': 620}),
      _e(id: 'a', kind: 'timeout', severity: 'error',
          createdAt: '2026-09-18T10:00:00Z'),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('執行器 esvel-pc 已離線'), findsOneWidget);
    expect(find.textContaining('已 620 秒沒有輸出'), findsOneWidget);
    final first = tester.getTopLeft(find.text('執行器 esvel-pc 已離線')).dy;
    final second =
        tester.getTopLeft(find.textContaining('已 620 秒沒有輸出')).dy;
    expect(first, lessThan(second), reason: '最新的那筆要在最上面');

    await tester.tap(find.text('執行器 esvel-pc 已離線'));
    await tester.pumpAndSettle();
    expect(lastRoute, '/rooms/room-9');
  });

  testWidgets('入口的未讀計數＝比水位新的那幾筆；看過之後歸零', (tester) async {
    final list = [
      _e(id: 'c', kind: 'timeout', createdAt: '2026-09-18T12:00:00Z'),
      _e(id: 'b', kind: 'stalled', createdAt: '2026-09-18T11:00:00Z'),
    ];
    await tester.pumpWidget(host(list,
        home: const Scaffold(body: Center(child: OpsExceptionsEntry()))));
    await tester.pumpAndSettle();
    expect(find.text('2'), findsOneWidget);

    // 打開面板＝看過了，水位往前
    await tester.pumpWidget(host(list));
    await tester.pumpAndSettle();
    await tester.pumpWidget(host(list,
        home: const Scaffold(body: Center(child: OpsExceptionsEntry()))));
    await tester.pumpAndSettle();
    expect(find.text('2'), findsNothing);
    expect(settings.opsExceptionSeenAt,
        '2026-09-18T12:00:00Z');
  });

  testWidgets('從執行儀表板開面板，返回要回到那個儀表板', (tester) async {
    await tester.pumpWidget(host(
      [_e(id: 'a', kind: 'timeout', createdAt: '2026-09-18T10:00:00Z')],
      initialLocation: '/rooms/room-1/ops',
    ));
    await tester.pumpAndSettle();
    expect(here(), '/rooms/room-1/ops');

    await tester.tap(find.byTooltip('派工異常'));
    await tester.pumpAndSettle();
    expect(here(), '/ops/exceptions');

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(here(), '/rooms/room-1/ops', reason: '返回要回到來源頁，不是房間列表');
  });

  testWidgets('直接開網址時，返回靠 ?from= 回到來源頁', (tester) async {
    await tester.pumpWidget(host(
      [_e(id: 'a', kind: 'timeout', createdAt: '2026-09-18T10:00:00Z')],
      initialLocation:
          '/ops/exceptions?from=${Uri.encodeComponent('/rooms/room-7/ops')}',
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(here(), '/rooms/room-7/ops');
  });

  testWidgets('沒有堆疊也沒有來源時才退回房間列表', (tester) async {
    await tester.pumpWidget(host(
      [_e(id: 'a', kind: 'timeout', createdAt: '2026-09-18T10:00:00Z')],
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(here(), '/rooms');
  });
}
