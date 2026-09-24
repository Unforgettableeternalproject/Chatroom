import 'dart:convert';
import 'dart:typed_data';

import 'package:chatroom_app/api/board_api.dart';
import 'package:chatroom_app/api/rooms_api.dart';
import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/errors/api_exception.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/models/participant.dart';
import 'package:chatroom_app/models/room.dart';
import 'package:chatroom_app/screens/rooms/room_actions.dart';
import 'package:chatroom_app/screens/rooms/room_list_screen.dart';
import 'package:chatroom_app/screens/rooms/room_settings_screen.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:chatroom_app/state/rooms_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/l10n.dart';

/// 房間選單收成三項、設定集中到設定頁、刪除只給已封存的房
/// （艾斯維爾 2026-09-23）。
///
/// 三組：API 的線上形狀（主題、離開、刪板）、房間列表選單上實際出現哪些
/// 項目、房主是最後一位人類時離開要先問過人。

class _Stub implements HttpClientAdapter {
  _Stub(this.body);

  final Map<String, dynamic> body;
  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? _,
    Future<void>? _,
  ) async {
    seen.add(options);
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(_Stub stub) =>
    Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = stub;

const _config = AppConfig(
  serverUrl: 'http://test',
  token: 'token',
  themeMode: ThemeModePref.dark,
  preferredName: 'Bernie',
  deviceKey: 'device-key',
);

Room _room({required String status, bool admin = true}) => Room.fromJson({
  'id': 'r1',
  'name': '房',
  'topic': '',
  'status': status,
  'created_at': '2026-09-23T00:00:00+00:00',
  'you_are_admin': admin,
});

class _LeaveApi extends RoomsApi {
  _LeaveApi() : super(Dio());

  final List<bool> calls = [];

  @override
  Future<LeaveResult> leave(
    String roomId, {
    required String participantId,
    bool archiveIfLast = false,
  }) async {
    calls.add(archiveIfLast);
    if (!archiveIfLast) {
      throw const ConflictException(
        'leave_will_archive',
        '你是這個聊天室最後一位人類成員，離開會封存聊天室。',
      );
    }
    return const LeaveResult(archived: true);
  }
}

void main() {
  group('API 形狀', () {
    test('改主題：POST /api/rooms/{id}/topic，帶身分，回 Hub 落庫的主題', () async {
      final stub = _Stub({'ok': true, 'topic': '收尾', 'changed': true});
      final topic = await RoomsApi(_dioWith(stub))
          .setTopic('r1', topic: '  收尾 ', sessionKey: 'k', participantId: 'p1');
      final req = stub.seen.single;
      expect(req.method, 'POST');
      expect(req.path, '/api/rooms/r1/topic');
      expect(req.data, {'topic': '收尾'});
      expect(req.headers['X-Session-Key'], 'k');
      expect(req.headers['X-Participant-Id'], 'p1');
      expect(topic, '收尾');
    });

    test('離開：一般情況不帶 body；Hub 回的接手者要解析出來', () async {
      final stub = _Stub({
        'ok': true,
        'admin_transferred_to': {'participant_id': 'p2', 'display_name': '小明'},
        'archived': false,
      });
      final r = await RoomsApi(_dioWith(stub)).leave('r1', participantId: 'p1');
      expect(stub.seen.single.path, '/api/rooms/r1/leave');
      expect(stub.seen.single.data, isNull);
      expect(r.handedOverTo, '小明');
      expect(r.archived, isFalse);
    });

    test('確認過「離開會封存」才帶 archive_if_last', () async {
      final stub = _Stub({
        'ok': true,
        'admin_transferred_to': null,
        'archived': true,
      });
      final r = await RoomsApi(_dioWith(stub))
          .leave('r1', participantId: 'p1', archiveIfLast: true);
      expect(stub.seen.single.data, {'archive_if_last': true});
      expect(r.archived, isTrue);
      expect(r.handedOverTo, isNull);
    });

    test('刪板：DELETE /api/boards/{id}，帶 session key', () async {
      final stub = _Stub({'ok': true});
      await BoardsApi(_dioWith(stub)).delete('b1', sessionKey: 'k');
      expect(stub.seen.single.method, 'DELETE');
      expect(stub.seen.single.path, '/api/boards/b1');
      expect(stub.seen.single.headers['X-Session-Key'], 'k');
    });
  });

  group('房間列表的「…」選單', () {
    Future<void> pumpList(
      WidgetTester tester, {
      required List<Room> active,
      List<Room> archived = const [],
    }) async {
      SharedPreferences.setMockInitialValues({
        'chatroom.participant.r1': 'p-me',
      });
      final settings = SettingsRepository(
        await SharedPreferences.getInstance(),
      );
      tester.view.physicalSize = const Size(600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsRepoProvider.overrideWithValue(settings),
            initialConfigProvider.overrideWithValue(_config),
            roomListProvider('active')
                .overrideWith((ref) async => RoomListResult(rooms: active)),
            roomListProvider('archived')
                .overrideWith((ref) async => RoomListResult(rooms: archived)),
          ],
          child: MaterialApp(
            localizationsDelegates: kTestLocalizationsDelegates,
            supportedLocales: kTestSupportedLocales,
            locale: kTestLocale,
            theme: buildUepTheme(Brightness.dark),
            home: const Scaffold(body: RoomListPane()),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('進行中的房：只有轉移所有權、離開房間——沒有設定、沒有刪除', (tester) async {
      await pumpList(tester, active: [_room(status: 'active')]);
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pumpAndSettle();

      // 設定只從房內進得去（艾斯維爾 09/23）
      expect(find.text('設定'), findsNothing);
      expect(find.text('轉移所有權'), findsOneWidget);
      expect(find.text('離開房間'), findsOneWidget);
      expect(find.text('永久刪除…'), findsNothing);
      // 設定類與封存都搬進設定頁了
      expect(find.text('封存'), findsNothing);
      expect(find.text('指派'), findsNothing);
      expect(find.byType(PopupMenuItem<String>), findsNWidgets(2));
    });

    testWidgets('非房主看不到轉移所有權', (tester) async {
      await pumpList(tester, active: [_room(status: 'active', admin: false)]);
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pumpAndSettle();
      expect(find.text('轉移所有權'), findsNothing);
      expect(find.text('離開房間'), findsOneWidget);
    });

    testWidgets('已封存分頁的房：刪除入口在這裡', (tester) async {
      await pumpList(
        tester,
        active: const [],
        archived: [_room(status: 'archived')],
      );
      await tester.tap(find.text('已封存'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pumpAndSettle();
      expect(find.text('永久刪除…'), findsOneWidget);
      // 封存房不能轉移（Hub 回 409）
      expect(find.text('轉移所有權'), findsNothing);
    });
  });

  group('房間設定頁', () {
    RoomDetail detail({required bool admin, String me = 'p-me'}) => RoomDetail(
      room: _room(status: 'active', admin: admin),
      youAreAdmin: admin,
      participants: [
        Participant.fromJson({
          'id': me,
          'kind': 'human',
          'display_name': 'Me',
          'role': 'human',
          'status': 'active',
          'joined_at': '2026-09-23T00:00:00+00:00',
        }),
      ],
    );

    Future<void> pumpSettings(
      WidgetTester tester,
      RoomDetail d, {
      String? cachedId = 'p-me',
    }) async {
      SharedPreferences.setMockInitialValues({
        'chatroom.participant.r1': ?cachedId,
      });
      final settings = SettingsRepository(
        await SharedPreferences.getInstance(),
      );
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsRepoProvider.overrideWithValue(settings),
            initialConfigProvider.overrideWithValue(_config),
            roomDetailProvider('r1').overrideWith((ref) async => d),
            boardProvider('r1')
                .overrideWith((ref) async => const BoardSnapshot()),
          ],
          child: MaterialApp(
            localizationsDelegates: kTestLocalizationsDelegates,
            supportedLocales: kTestSupportedLocales,
            locale: kTestLocale,
            theme: buildUepTheme(Brightness.dark),
            home: const RoomSettingsScreen(roomId: 'r1'),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    List<TextField> fields(WidgetTester tester) =>
        tester.widgetList<TextField>(find.byType(TextField)).toList();

    testWidgets('房主：欄位可編輯、有儲存鈕', (tester) async {
      await pumpSettings(tester, detail(admin: true));
      expect(fields(tester), isNotEmpty);
      expect(fields(tester).every((f) => f.enabled ?? true), isTrue);
      expect(find.text('儲存'), findsOneWidget);
      expect(find.text('只有房主能修改'), findsNothing);
    });

    testWidgets('一般成員：唯讀、沒有儲存鈕', (tester) async {
      await pumpSettings(tester, detail(admin: false));
      expect(fields(tester), isNotEmpty);
      expect(fields(tester).every((f) => f.enabled == false), isTrue);
      expect(find.text('儲存'), findsNothing);
      expect(find.text('只有房主能修改'), findsOneWidget);
    });

    testWidgets('非成員直接打開路由：什麼設定都看不到', (tester) async {
      // 主持人模式讀得到詳情，但他不在成員名單上
      await pumpSettings(tester, detail(admin: false, me: 'someone-else'));
      expect(find.text('只有房間成員能查看設定'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('本機沒有房內身分也擋', (tester) async {
      await pumpSettings(tester, detail(admin: false), cachedId: null);
      expect(find.text('只有房間成員能查看設定'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });
  });

  testWidgets('房主是最後一位人類：先跳警示，確認後才帶 archive_if_last 再離開', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsRepository(await SharedPreferences.getInstance());
    final api = _LeaveApi();
    final router = GoRouter(
      initialLocation: '/rooms/r1',
      routes: [
        GoRoute(
          path: '/rooms',
          builder: (_, _) => const Scaffold(body: Text('列表')),
          routes: [
            GoRoute(
              path: ':roomId',
              builder: (context, state) => Scaffold(
                body: Consumer(
                  builder: (context, ref, _) => TextButton(
                    onPressed: () => leaveRoomFlow(
                      context,
                      ref,
                      'r1',
                      participantId: 'p-me',
                    ),
                    child: const Text('離開'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepoProvider.overrideWithValue(settings),
          initialConfigProvider.overrideWithValue(_config),
          roomsApiProvider.overrideWithValue(api),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: kTestLocalizationsDelegates,
          supportedLocales: kTestSupportedLocales,
          locale: kTestLocale,
          theme: buildUepTheme(Brightness.dark),
        ),
      ),
    );

    await tester.tap(find.text('離開'));
    await tester.pumpAndSettle();
    // 第一次被 Hub 擋下，什麼都還沒發生：要先問人
    expect(api.calls, [false]);
    expect(find.text('離開並封存？'), findsOneWidget);

    await tester.tap(find.text('離開並封存'));
    await tester.pumpAndSettle();
    expect(api.calls, [false, true]);
    expect(find.text('列表'), findsOneWidget);
  });

  testWidgets('取消警示就不離開', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsRepository(await SharedPreferences.getInstance());
    final api = _LeaveApi();
    final router = GoRouter(
      initialLocation: '/rooms/r1',
      routes: [
        GoRoute(
          path: '/rooms',
          builder: (_, _) => const Scaffold(body: Text('列表')),
          routes: [
            GoRoute(
              path: ':roomId',
              builder: (context, state) => Scaffold(
                body: Consumer(
                  builder: (context, ref, _) => TextButton(
                    onPressed: () => leaveRoomFlow(
                      context,
                      ref,
                      'r1',
                      participantId: 'p-me',
                    ),
                    child: const Text('離開'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepoProvider.overrideWithValue(settings),
          initialConfigProvider.overrideWithValue(_config),
          roomsApiProvider.overrideWithValue(api),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: kTestLocalizationsDelegates,
          supportedLocales: kTestSupportedLocales,
          locale: kTestLocale,
          theme: buildUepTheme(Brightness.dark),
        ),
      ),
    );

    await tester.tap(find.text('離開'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(api.calls, [false]);
    expect(find.text('列表'), findsNothing);
  });
}
