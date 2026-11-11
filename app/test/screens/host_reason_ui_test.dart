import 'dart:typed_data';

import 'package:chatroom_app/api/api_client.dart';
import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/host_reason.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/screens/boards/board_list_screen.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:chatroom_app/widgets/delete_room_confirm.dart';
import 'package:chatroom_app/widgets/host_reason.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/app_config.dart';
import '../helpers/l10n.dart';

class _HostOn extends HostViewNotifier {
  @override
  bool build() => true;
}

class _Capture implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return ResponseBody.fromString('{}', 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _Capture capture;
  late Dio dio;

  Future<void> pumpHarness(WidgetTester tester, {required bool host}) async {
    capture = _Capture();
    dio = createApiDio(
        baseUrl: 'http://hub.test', token: 't', hostView: () => host)
      ..httpClientAdapter = capture;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        initialConfigProvider.overrideWithValue(kTestInitialConfig),
        if (host) hostViewProvider.overrideWith(_HostOn.new),
      ],
      child: MaterialApp(
        locale: kTestLocale,
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: kTestSupportedLocales,
        theme: buildUepTheme(Brightness.dark),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => withAskedHostReason<void>(
                  context,
                  title: '封存聊天室',
                  run: () => dio.post('/api/rooms/r1/archive'),
                ),
                child: const Text('執行'),
              ),
            ),
          ),
        ),
      ),
    ));
  }

  testWidgets('主持人模式：彈出理由欄，填的理由隨請求送出 reason', (tester) async {
    await pumpHarness(tester, host: true);
    await tester.tap(find.text('執行'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('hostReasonField')), findsOneWidget);
    expect(find.text('理由（選填）'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('hostReasonField')), '長期沒人用');
    await tester.tap(find.text('確定'));
    await tester.pumpAndSettle();

    expect(capture.requests.single.data, {'reason': '長期沒人用'});
  });

  testWidgets('主持人模式：理由留空照樣執行，不送 reason；取消則不執行', (tester) async {
    await pumpHarness(tester, host: true);
    await tester.tap(find.text('執行'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('確定'));
    await tester.pumpAndSettle();
    expect(capture.requests.single.data, isNull);

    await tester.tap(find.text('執行'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(capture.requests.length, 1);
  });

  testWidgets('非主持人模式：不彈框、不顯示理由欄，直接執行且不送 reason',
      (tester) async {
    await pumpHarness(tester, host: false);
    await tester.tap(find.text('執行'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('hostReasonField')), findsNothing);
    expect(capture.requests.single.data, isNull);
  });

  testWidgets('DeleteRoomConfirm：只有傳 reason controller 時才有理由欄',
      (tester) async {
    Future<void> show(TextEditingController? reason) async {
      await tester.pumpWidget(MaterialApp(
        locale: kTestLocale,
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: kTestSupportedLocales,
        theme: buildUepTheme(Brightness.dark),
        home: Scaffold(body: DeleteRoomConfirm(name: '房', reason: reason)),
      ));
    }

    await show(null);
    expect(find.byKey(const Key('hostReasonField')), findsNothing);

    await show(TextEditingController());
    expect(find.byKey(const Key('hostReasonField')), findsOneWidget);
  });

  testWidgets('任務板清單：不再有「通知要自己來看」標籤與舊的鈴鐺入口', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsRepository(await SharedPreferences.getInstance());
    await tester.pumpWidget(ProviderScope(
      overrides: [
        settingsRepoProvider.overrideWithValue(settings),
        initialConfigProvider.overrideWithValue(kTestInitialConfig),
        boardLibraryProvider.overrideWith((ref, view) async =>
            const BoardListResult(boards: [
              // 掛了房但沒有活著的：過去會被標成「通知要自己來看」
              BoardSummary(
                  id: 'b1',
                  name: '孤板',
                  attachedRoomCount: 1,
                  liveRoomCount: 0,
                  deliveryMode: 'inbox_only'),
            ])),
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

    expect(find.text('孤板'), findsOneWidget);
    expect(find.text('通知要自己來看'), findsNothing);
    expect(find.text('我在等的東西'), findsNothing);
    expect(find.byIcon(Icons.notifications_none), findsNothing);
  });

  test('runWithHostReason 的 Zone 值不會外漏到動作之外', () {
    expect(currentHostReason(), isNull);
  });
}
