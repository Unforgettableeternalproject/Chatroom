import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/config/app_settings.dart';
import 'core/theme/uep_theme.dart';
import 'screens/assignments/assignment_screen.dart';
import 'screens/chat/chat_screen.dart';
import 'screens/pinned/pinned_wall_screen.dart';
import 'screens/rooms/room_list_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'screens/shell/app_shell.dart';
import 'state/app_providers.dart';

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
