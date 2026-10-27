import 'package:chatroom_app/api/scratchpad_api.dart';
import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/models/scratchpad.dart';
import 'package:chatroom_app/screens/boards/board_list_screen.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:chatroom_app/state/scratchpad_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/l10n.dart';

/// 側欄鈴鐺的右鍵選單：全部標為已讀。
class _FakeWatchApi extends WatchApi {
  _FakeWatchApi(int unread)
      : _unread = unread,
        super(Dio());

  int _unread;
  int markAllCalls = 0;

  @override
  Future<({List<WatchNotice> notices, int unread})> notices({
    required String sessionKey,
    bool unreadOnly = true,
    String boardId = '',
  }) async =>
      (notices: const <WatchNotice>[], unread: _unread);

  @override
  Future<int> markRead({
    required String sessionKey,
    List<String> noticeIds = const [],
    bool all = false,
  }) async {
    if (all) markAllCalls++;
    final n = _unread;
    _unread = 0;
    return n;
  }
}

void main() {
  const config = AppConfig(
    serverUrl: 'http://test',
    token: 'root-token',
    themeMode: ThemeModePref.dark,
    preferredName: 'Bernie',
    deviceKey: 'device-key',
  );

  Future<void> pump(WidgetTester tester, _FakeWatchApi api) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsRepository(await SharedPreferences.getInstance());
    await tester.pumpWidget(ProviderScope(
      overrides: [
        settingsRepoProvider.overrideWithValue(settings),
        initialConfigProvider.overrideWithValue(config),
        watchApiProvider.overrideWithValue(api),
        boardLibraryProvider
            .overrideWith((ref, view) async => const BoardListResult()),
      ],
      child: MaterialApp(
        locale: kTestLocale,
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: kTestSupportedLocales,
        theme: buildUepTheme(Brightness.dark),
        home: const Scaffold(body: BoardListPane()),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> rightClickBell(WidgetTester tester) async {
    final bell = find.byIcon(Icons.notifications_none);
    expect(bell, findsOneWidget);
    final g = await tester.startGesture(tester.getCenter(bell),
        kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await g.up();
    await tester.pumpAndSettle();
  }

  testWidgets('有未讀：右鍵開出選單，點「全部標為已讀」走 all=true 並更新狀態',
      (tester) async {
    final api = _FakeWatchApi(3);
    await pump(tester, api);

    await rightClickBell(tester);
    final item = find.text('全部標為已讀');
    expect(item, findsOneWidget);

    await tester.tap(item);
    await tester.pumpAndSettle();

    expect(api.markAllCalls, 1);
    expect(find.text('3 筆標為已讀'), findsOneWidget);

    // 狀態重抓後未讀歸零：再開選單時項目停用
    await rightClickBell(tester);
    final menuItem = tester.widget<PopupMenuItem<String>>(
        find.widgetWithText(PopupMenuItem<String>, '全部標為已讀'));
    expect(menuItem.enabled, isFalse);
  });

  testWidgets('沒有未讀：選單項目停用，點了不打 API', (tester) async {
    final api = _FakeWatchApi(0);
    await pump(tester, api);

    await rightClickBell(tester);
    final menuItem = tester.widget<PopupMenuItem<String>>(
        find.widgetWithText(PopupMenuItem<String>, '全部標為已讀'));
    expect(menuItem.enabled, isFalse);

    await tester.tap(find.text('全部標為已讀'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(api.markAllCalls, 0);
  });
}
