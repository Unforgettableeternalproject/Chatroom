import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/config/app_settings.dart';
import 'core/theme/uep_theme.dart';
import 'core/window/window_tray.dart';
import 'l10n/l10n.dart';
import 'notifications/local_notifier.dart';
import 'screens/assignments/assignment_screen.dart';
import 'screens/board/board_screen.dart';
import 'screens/host/host_console_screen.dart';
import 'screens/ops/ops_dashboard_screen.dart';
import 'screens/board/scratchpad_screen.dart';
import 'screens/board/board_settings_screen.dart';
import 'screens/board/supervisor_track_screen.dart';
import 'screens/board/watch_notices_screen.dart';
import 'screens/chat/chat_screen.dart';
import 'screens/help/help_screen.dart';
import 'screens/pinned/pinned_wall_screen.dart';
import 'screens/rooms/room_list_screen.dart';
import 'screens/rooms/room_settings_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'screens/shell/app_shell.dart';
import 'state/app_providers.dart';
import 'state/notification_providers.dart';
import 'state/ops_exceptions_providers.dart';

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
      // 主機控制台。**只在裝了 host-kit 的那台機器上有意義**——入口本身
      // 會依偵測結果出現或消失，這條路由留著是為了讓它能被直接開啟
      // （見 kit UI 設計簡報 §6.0）
      GoRoute(
        path: '/host',
        builder: (context, state) => const HostConsoleScreen(),
      ),
      // 手冊。各畫面上不放介紹，要解釋的東西集中在這裡；依入口分成三份，
      // 按進來的人只看到自己那個畫面的說明
      GoRoute(
        path: '/help',
        redirect: (context, state) => '/help/main',
      ),
      GoRoute(
        path: '/help/:topic',
        builder: (context, state) => HelpScreen(
          topic: helpTopicFromSlug(state.pathParameters['topic']),
        ),
      ),
      ShellRoute(
        builder: (context, state, child) => AppShell(
          selectedRoomId: state.pathParameters['roomId'],
          selectedBoardId: state.pathParameters['boardId'],
          child: child,
        ),
        routes: [
          // Board 的**權威路由**（BOARD_DESIGN §10）。v2 起 Board 不屬於任何
          // 聊天室：它可以掛在多間房、也可以一間都沒掛，所以它的網址不能
          // 長在某一間房底下。房底下那條保留為相容入口。
          GoRoute(
            path: '/boards/:boardId',
            builder: (context, state) => BoardScreen(
              boardId: state.pathParameters['boardId']!,
              // 訊息裡的 `#[標題]` 點進來時帶著要打開的那張卡
              focusTaskId: state.uri.queryParameters['task'],
            ),
            routes: [
              // 想法板走板軸，不走房軸——它屬於板，而板活得比房久。
              GoRoute(
                path: 'pads/:padId',
                builder: (context, state) => ScratchpadPage(
                  boardId: state.pathParameters['boardId']!,
                  padId: state.pathParameters['padId']!,
                ),
              ),
              // 任務板設定（名稱、主題、貢獻紀錄）
              GoRoute(
                path: 'settings',
                builder: (context, state) => BoardSettingsScreen(
                  boardId: state.pathParameters['boardId']!,
                ),
              ),
            ],
          ),
          // 追蹤收件匣**跨板**——「我在等的東西完成了嗎」不分板，
          // 所以它不掛在任何一塊板底下
          GoRoute(
            path: '/notices',
            builder: (context, state) => const WatchNoticesScreen(),
          ),
          GoRoute(
            path: '/rooms',
            builder: (context, state) =>
                MediaQuery.sizeOf(context).width >= 900
                    ? const NoRoomSelected()
                    : const RoomListPane(),
            routes: [
              GoRoute(
                path: ':roomId',
                // ⚠️ **key 一定要有。** 少了它，切換房間時 Flutter 認為
                // 這是同一個位置的同一種 widget，於是重用同一顆
                // `_ChatScreenState`——回覆目標、編輯目標與**待送附件**
                // 全部原封不動留著，然後出現在新的房間裡。附件那條最壞：
                // 它會在別的房被送出去，而畫面上只是一排縮圖，沒有人會
                // 逐一去認那是不是自己剛剛在別處挑的檔案
                // （艾斯維爾 2026-09-02；UI 端定位到兩顆 State 都被重用）。
                //
                // 草稿的字**不靠 key 保存**，它存在 composerDraftsProvider
                // 裡——key 讓 State 重建，那會清掉字，所以兩層缺一不可。
                builder: (context, state) => ChatScreen(
                  key: ValueKey(state.pathParameters['roomId']!),
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
                  // 工作房的執行儀表板。與釘選牆／指派同一層——它是這間房
                  // 底下的東西，跟著房間的成員與權限走
                  GoRoute(
                    path: 'ops',
                    builder: (context, state) => OpsDashboardScreen(
                        roomId: state.pathParameters['roomId']!),
                  ),
                  GoRoute(
                    path: 'assign',
                    builder: (context, state) => AssignmentScreen(
                        roomId: state.pathParameters['roomId']!),
                  ),
                  // 房間設定：名稱、主題、說話方式、可見度等，原本散在選單裡
                  GoRoute(
                    path: 'settings',
                    builder: (context, state) => RoomSettingsScreen(
                        roomId: state.pathParameters['roomId']!),
                  ),
                  // Board 與釘選牆／指派同一層：它是這個房間底下的東西，
                  // 跟著房間的成員、權限與封存狀態走
                  // 相容入口。**不 redirect 到 /boards/:id**：要 redirect 就得
                  // 先解析出 board_id，而那是一次網路往返——導覽會先卡在
                  // 一個空白畫面上，然後才跳走。這裡直接用 roomId 開，
                  // BoardScreen 自己從回應學到 board_id。
                  GoRoute(
                    path: 'board',
                    builder: (context, state) => BoardScreen(
                        roomId: state.pathParameters['roomId']!,
                        // `?task=` 與板軸那條同名同義：訊息裡的 `#[標題]`
                        // 點進來時帶著要打開的那張卡。房軸原本吃不到它，
                        // 於是「從聊天室點卡片」只能繞板軸走（就回不去了）
                        focusTaskId: state.uri.queryParameters['task']),
                    routes: [
                      // 想法板的房軸入口。板軸那條（`/boards/:bid/pads/:pid`）
                      // 仍是權威路徑；這條的存在只為了讓「從聊天室點進來」
                      // 的人留在 ROOMS 分頁上——見 RoomScratchpadPage
                      GoRoute(
                        path: 'pads/:padId',
                        builder: (context, state) => RoomScratchpadPage(
                          roomId: state.pathParameters['roomId']!,
                          padId: state.pathParameters['padId']!,
                        ),
                      ),
                      // Supervisor 的追蹤介面。掛在房底下是因為它問的是
                      // 「**這間房裡**誰在做什麼」——Supervisor 是 per-room
                      // 的，板軸上沒有「這一間」可言
                      GoRoute(
                        path: 'track',
                        builder: (context, state) => SupervisorTrackScreen(
                            roomId: state.pathParameters['roomId']!),
                      ),
                      // 任務板設定的房軸入口：與想法板同一個理由，從聊天室
                      // 進來的人留在 ROOMS 分頁上，返回回到這間房的板
                      GoRoute(
                        path: 'settings',
                        builder: (context, state) => BoardSettingsScreen(
                          boardId: state.uri.queryParameters['board'] ?? '',
                          roomId: state.pathParameters['roomId']!,
                        ),
                      ),
                    ],
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
      // 視窗可能正縮在系統匣裡——那時候導頁本身是看不見的，得先把它叫回來
      WindowTray.instance.showWindow();
      _router.go('/rooms/$roomId');
    };
    LocalNotifier.instance.init();
    // 派工例外的通知：掉線與逾時要有人立刻知道，而那兩件事不會出現在
    // 訊息流的通知管線裡（房內那句 system 訊息不發通知）
    ref.read(opsExceptionNotifierProvider).start();
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
    final scale = fontScaleFactor(
        ref.watch(appConfigProvider.select((c) => c.fontScale)));
    final localePref = ref.watch(appConfigProvider.select((c) => c.locale));
    // 字體是 UepText 的靜態值（那些 style 函式沒有 context），在這裡同步；
    // 真正讓畫面換字的是下面 KeyedSubtree 的 key
    final fontFamily =
        ref.watch(appConfigProvider.select((c) => c.fontFamily));
    UepText.family = fontFamily;
    return MaterialApp.router(
      title: 'Chatroom',
      debugShowCheckedModeBanner: false,
      routerConfig: _router,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // 跟隨系統＝傳 null，讓 Flutter 自己依系統語言在 supportedLocales
      // 裡挑；寫死一個值的話使用者換系統語言後 App 不會跟著變
      locale: switch (localePref) {
        LocalePref.system => null,
        LocalePref.zhTW => const Locale('zh', 'TW'),
        LocalePref.en => const Locale('en'),
      },
      // 字級三檔：整體縮放放在這裡，不改各畫面的硬編碼字級。系統本身的
      // 字級設定不再疊加進來（textScaler 被整個換掉），避免兩層放大相乘。
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        // 沒有 context 的程式碼（模型、通知、API 例外）從 L10n.current 拿字，
        // 這裡讓它跟著 MaterialApp 的 locale 走
        child: KeyedSubtree(
          // 換字體只動到一個靜態值，沒有 widget 會因此失效——換 key 把整棵
          // 重建掉，選了就立刻看得到（代價是頁內暫態，如捲動位置，會重來）
          key: ValueKey(fontFamily),
          child: L10nSync(child: child ?? const SizedBox.shrink()),
        ),
      ),
      theme: buildUepTheme(Brightness.light),
      darkTheme: buildUepTheme(Brightness.dark),
      themeMode: themeMode == ThemeModePref.dark
          ? ThemeMode.dark
          : ThemeMode.light,
    );
  }
}
