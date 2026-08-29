import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/config/app_settings.dart';
import 'core/theme/uep_theme.dart';
import 'notifications/local_notifier.dart';
import 'screens/assignments/assignment_screen.dart';
import 'screens/chat/chat_screen.dart';
import 'screens/pinned/pinned_wall_screen.dart';
import 'screens/rooms/room_list_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'screens/shell/app_shell.dart';
import 'state/app_providers.dart';
import 'state/notification_providers.dart';

/// 「正在看訊息流」的路由：`/rooms/<id>`，不含 pinned / assign 子頁
/// （那些畫面看不到新訊息，該照常通知）。
final _roomRoute = RegExp(r'^/rooms/([^/]+)$');

/// 目前路由對應的「正在看的房間」——沒有就回 null（通知照發）。
String? activeRoomIdFor(String path) => _roomRoute.firstMatch(path)?.group(1);

GoRouter buildRouter(bool Function() isConfigured) {
  return GoRouter(
    initialLocation: '/rooms',
    redirect: (context, state) {
      // 首次啟動（從未存過 server 設定）→ 先去設定畫面
      if (!isConfigured() && state.matchedLocation != '/settings') {
        return '/settings';
      }
      return null;
    },
    routes: [
      GoRoute(
        path: '/settings',
        builder: (context, state) => const SettingsScreen(),
      ),
      ShellRoute(
        builder: (context, state, child) => AppShell(
          selectedRoomId: state.pathParameters['roomId'],
          child: child,
        ),
        routes: [
          GoRoute(
            path: '/rooms',
            builder: (context, state) =>
                MediaQuery.sizeOf(context).width >= 900
                    ? const NoRoomSelected()
                    : const RoomListPane(),
            routes: [
              GoRoute(
                path: ':roomId',
                builder: (context, state) => ChatScreen(
                  roomId: state.pathParameters['roomId']!,
                  focusSeq: int.tryParse(
                      state.uri.queryParameters['focusSeq'] ?? ''),
                ),
                routes: [
                  GoRoute(
                    path: 'pinned',
                    builder: (context, state) => PinnedWallScreen(
                        roomId: state.pathParameters['roomId']!),
                  ),
                  GoRoute(
                    path: 'assign',
                    builder: (context, state) => AssignmentScreen(
                        roomId: state.pathParameters['roomId']!),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  );
}

class ChatroomApp extends ConsumerStatefulWidget {
  const ChatroomApp({super.key});

  @override
  ConsumerState<ChatroomApp> createState() => _ChatroomAppState();
}

class _ChatroomAppState extends ConsumerState<ChatroomApp> {
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _router = buildRouter(
        () => ref.read(settingsRepoProvider).hasServerConfig);
    // OS 通知：初始化失敗不致命（僅無系統通知）；點擊 → 導頁到該房間
    LocalNotifier.instance.onSelectRoom = (roomId) {
      _router.go('/rooms/$roomId');
    };
    LocalNotifier.instance.init();
    _router.routerDelegate.addListener(_syncActiveRoom);
    _syncActiveRoom();
  }

  @override
  void dispose() {
    _router.routerDelegate.removeListener(_syncActiveRoom);
    super.dispose();
  }

  /// 通知抑制的依據＝「當前路由」，不是「ChatScreen 還活著」。
  ///
  /// 這兩件事會分岔：`/settings` 是 push 到根 Navigator，底下 ShellRoute 裡的
  /// ChatScreen 不會 dispose，於是它繼續宣稱自己是 activeRoomId，使用者明明
  /// 在看設定頁卻收不到任何通知（2026-08-29 實機發現）。改由路由推導後，
  /// 任何蓋在上面的畫面都會自動讓出，未來新增 push 路由也不必記得處理。
  void _syncActiveRoom() {
    // 取 last.matchedLocation 而不是 currentConfiguration.uri：後者是 base
    // location，push 疊上來的畫面不會反映在裡面（`/settings` 蓋住聊天室時
    // uri 仍是 /rooms/<id>），照它判斷等於沒修。實測見 active_room_route_test。
    final matches = _router.routerDelegate.currentConfiguration;
    if (matches.isEmpty) {
      // initState 裡的首次呼叫早於 router 解析出第一條路由，此時 matchList
      // 是空的，`.last` 會拋 Bad state: No element——而它拋在 initState 裡，
      // 整棵樹掛掉，畫面全白（2026-08-29 實機發現）。
      // 還沒有路由＝還沒有任何房間在前景，不抑制任何通知才是對的語意。
      ref.read(notificationCenterProvider).activeRoomId = null;
      return;
    }
    ref.read(notificationCenterProvider).activeRoomId =
        activeRoomIdFor(matches.last.matchedLocation);
  }

  @override
  Widget build(BuildContext context) {
    final themeMode =
        ref.watch(appConfigProvider.select((c) => c.themeMode));
    return MaterialApp.router(
      title: 'Chatroom',
      debugShowCheckedModeBanner: false,
      routerConfig: _router,
      theme: buildUepTheme(Brightness.light),
      darkTheme: buildUepTheme(Brightness.dark),
      themeMode: themeMode == ThemeModePref.dark
          ? ThemeMode.dark
          : ThemeMode.light,
    );
  }
}
