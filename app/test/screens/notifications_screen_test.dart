import 'package:chatroom_app/api/notifications_api.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/app_notification.dart';
import 'package:chatroom_app/screens/notifications/notifications_screen.dart';
import 'package:chatroom_app/screens/shell/app_shell.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/notification_inbox_providers.dart';
import 'package:chatroom_app/ws/inbox_socket.dart';
import 'package:chatroom_app/ws/ws_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../helpers/app_config.dart';
import '../helpers/l10n.dart';

class _FakeApi extends NotificationsApi {
  _FakeApi(this.items, this.unread) : super(Dio());

  List<AppNotification> items;
  int unread;
  final marked = <List<int>>[];
  int markAllCalls = 0;

  @override
  Future<NotificationPage> list({
    required String sessionKey,
    bool unreadOnly = false,
    int limit = 30,
    int? beforeId,
  }) async =>
      NotificationPage(unreadCount: unread, items: items);

  @override
  Future<void> markRead({
    required String sessionKey,
    List<int> ids = const [],
    bool all = false,
  }) async {
    if (all) {
      markAllCalls++;
    } else {
      marked.add(ids);
    }
  }
}

class _NeverConnects implements WsConnection {
  @override
  int? get closeCode => null;
  @override
  Stream<dynamic> get stream => const Stream.empty();
  @override
  void send(String data) {}
  @override
  Future<void> close() async {}
}

void main() {
  final recent = DateTime.now().toUtc().subtract(const Duration(minutes: 5));

  final items = [
    AppNotification(
      id: 3,
      kind: 'host_room_archived',
      roomId: 'r1',
      roomName: '開發房',
      boardId: 'b1',
      boardName: '主板',
      itemKind: 'task',
      itemId: 't1',
      actorName: 'Bernie',
      actorKind: 'host',
      reason: '長期沒人用',
      summary: '主持人封存了聊天室（共 3 次）',
      count: 3,
      createdAt: recent.toIso8601String(),
      forHost: true,
    ),
    AppNotification(
      id: 2,
      kind: 'run_done',
      roomId: 'r2',
      roomName: '派工房',
      actorName: 'Codex',
      actorKind: 'agent',
      summary: '派工完成',
      createdAt: recent.toIso8601String(),
    ),
    const AppNotification(
      id: 1,
      summary: '舊的已讀通知',
      readAt: '2026-11-01T00:00:00Z',
    ),
  ];

  late _FakeApi api;
  late InboxSocket socket;
  String? lastRoute;

  Future<void> pump(WidgetTester tester, Widget home) async {
    final router = GoRouter(
      initialLocation: '/notices',
      routes: [
        GoRoute(path: '/notices', builder: (_, _) => home),
        GoRoute(
          path: '/boards/:id',
          builder: (_, s) {
            lastRoute = s.uri.toString();
            return const Scaffold(body: Text('板頁'));
          },
        ),
        GoRoute(
          path: '/rooms/:id',
          builder: (_, s) {
            lastRoute = s.uri.toString();
            return const Scaffold(body: Text('房頁'));
          },
        ),
      ],
    );
    socket = InboxSocket(
      uriBuilder: () => Uri.parse('ws://hub.test/ws/inbox'),
      connector: (_) async => _NeverConnects(),
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        initialConfigProvider.overrideWithValue(kTestInitialConfig),
        notificationsApiProvider.overrideWithValue(api),
        inboxSocketProvider.overrideWithValue(socket),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: kTestLocale,
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: kTestSupportedLocales,
        theme: buildUepTheme(Brightness.dark),
      ),
    ));
    await tester.pumpAndSettle();
  }

  setUp(() {
    lastRoute = null;
    api = _FakeApi(items, 2);
  });

  testWidgets('每則顯示來源、觸發者與種類、理由、主持人標記，不重複標 ×N', (tester) async {
    await pump(tester, const NotificationsScreen());

    expect(find.text('通知'), findsOneWidget);
    expect(find.text('主持人封存了聊天室（共 3 次）'), findsOneWidget);
    // 來源房／板
    expect(find.text('開發房 · 主板'), findsOneWidget);
    expect(find.text('派工房'), findsOneWidget);
    // 觸發者名稱與種類（主持人是強調標記）
    expect(find.text('Bernie'), findsOneWidget);
    expect(find.text('主持人'), findsOneWidget);
    expect(find.text('Agent'), findsOneWidget);
    // for_host 標籤
    expect(find.byKey(const Key('notificationForHost')), findsOneWidget);
    expect(find.text('主持人收件'), findsOneWidget);
    // 理由與合併次數
    expect(find.text('理由：長期沒人用'), findsOneWidget);
    // 合併次數已在 summary 裡（共 N 次），畫面不再另外標 ×N
    expect(find.text('×3'), findsNothing);
    expect(find.byKey(const Key('notificationCount')), findsNothing);
    // 相對時間
    expect(find.text('5 分前'), findsNWidgets(2));
    // 有未讀才有「全部已讀」
    expect(find.text('全部已讀'), findsOneWidget);
  });

  testWidgets('點通知：標已讀並導到任務板上的那張卡', (tester) async {
    await pump(tester, const NotificationsScreen());

    await tester.tap(find.text('主持人封存了聊天室（共 3 次）'));
    await tester.pumpAndSettle();

    expect(api.marked.single, [3]);
    expect(lastRoute, '/boards/b1?task=t1');
    expect(find.text('板頁'), findsOneWidget);
  });

  testWidgets('點沒有板的通知：導到房間；已讀的不再送已讀', (tester) async {
    await pump(tester, const NotificationsScreen());

    await tester.tap(find.text('派工完成'));
    await tester.pumpAndSettle();
    expect(api.marked.single, [2]);
    expect(lastRoute, '/rooms/r2');
  });

  testWidgets('全部已讀：送 all，未讀樣式與按鈕消失', (tester) async {
    await pump(tester, const NotificationsScreen());

    await tester.tap(find.text('全部已讀'));
    await tester.pumpAndSettle();

    expect(api.markAllCalls, 1);
    expect(find.text('全部已讀'), findsNothing);
  });

  testWidgets('沒有通知：空狀態', (tester) async {
    api = _FakeApi(const [], 0);
    await pump(tester, const NotificationsScreen());
    expect(find.text('沒有通知。'), findsOneWidget);
    expect(find.text('全部已讀'), findsNothing);
  });

  testWidgets('通知頁開著時 pageOpen 為 true，離開後回 false', (tester) async {
    await pump(tester, const NotificationsScreen());
    final container = ProviderScope.containerOf(
        tester.element(find.byType(NotificationsScreen)));
    expect(container.read(notificationsPageOpenProvider), isTrue);

    // 點通知離開這一頁（容器仍在）
    await tester.tap(find.text('派工完成'));
    await tester.pumpAndSettle();
    expect(find.text('房頁'), findsOneWidget);
    expect(container.read(notificationsPageOpenProvider), isFalse);
  });

  group('鈴鐺', () {
    testWidgets('未讀數顯示在徽章上，99 以上封頂', (tester) async {
      api = _FakeApi(items, 7);
      await pump(
          tester, const Scaffold(body: Center(child: NotificationBell())));
      expect(find.byKey(const Key('notificationBadge')), findsOneWidget);
      expect(find.text('7'), findsOneWidget);

      final container = ProviderScope.containerOf(
          tester.element(find.byType(NotificationBell)));
      // 模擬 WS 推來 150 則未讀
      api.unread = 150;
      await container.read(notificationInboxProvider.notifier).refresh();
      await tester.pump();
      expect(find.text('99+'), findsOneWidget);
    });

    testWidgets('沒有未讀：沒有徽章；點鈴鐺進通知頁', (tester) async {
      api = _FakeApi(const [], 0);
      await pump(
          tester, const Scaffold(body: Center(child: NotificationBell())));
      expect(find.byKey(const Key('notificationBadge')), findsNothing);
    });
  });
}
