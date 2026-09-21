import 'package:chatroom_app/api/rooms_api.dart';
import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/errors/api_exception.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/room.dart';
import 'package:chatroom_app/screens/ops/ops_actions.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../helpers/l10n.dart';

/// 送出「同一專案一次只跑一筆」這一步。
///
/// 兩件事要守：送上去的就是切過去那一邊（送反了就是關掉了一個以為還鎖著的
/// 房間），以及被 Hub 退回時要回傳 false——呼叫端靠它把開關撥回去，而且
/// Hub 那兩句話（不是房主／這不是工作房）要原樣講出來。
class _FakeRoomsApi extends RoomsApi {
  _FakeRoomsApi({this.error}) : super(Dio());

  final ApiException? error;
  final List<bool> sent = [];
  String? lastSessionKey;

  @override
  Future<Room> setSingleWriter(
    String roomId, {
    required bool enabled,
    String? sessionKey,
    String? participantId,
  }) async {
    lastSessionKey = sessionKey;
    final e = error;
    if (e != null) throw e;
    sent.add(enabled);
    return Room.fromJson({
      'id': roomId,
      'name': '工作房',
      'kind': 'ops',
      'created_at': '2026-09-21T00:00:00+00:00',
      'single_writer': enabled,
    });
  }
}

const _cfg = AppConfig(
  serverUrl: 'http://test',
  token: 't',
  themeMode: ThemeModePref.dark,
  preferredName: '我',
  deviceKey: 'device-key',
);

Future<bool?> _press(WidgetTester tester, _FakeRoomsApi api,
    SettingsRepository settings, bool enabled) async {
  bool? result;
  await tester.pumpWidget(ProviderScope(
    overrides: [
      initialConfigProvider.overrideWithValue(_cfg),
      roomsApiProvider.overrideWithValue(api),
      settingsRepoProvider.overrideWithValue(settings),
    ],
    child: MaterialApp(
      localizationsDelegates: kTestLocalizationsDelegates,
      supportedLocales: kTestSupportedLocales,
      theme: buildUepTheme(Brightness.dark),
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) => TextButton(
            onPressed: () async {
              result = await setRoomSingleWriter(context, ref,
                  roomId: 'room-1', enabled: enabled);
            },
            child: const Text('送'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('送'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late SettingsRepository settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsRepository(await SharedPreferences.getInstance());
  });

  testWidgets('送出的就是切過去那一邊，而且帶著身分——房主可能還沒 join 自己的房',
      (tester) async {
    final api = _FakeRoomsApi();
    expect(await _press(tester, api, settings, false), isTrue);

    expect(api.sent, [false]);
    expect(api.lastSessionKey, 'device-key');
  });

  testWidgets('開回去也是同一條路', (tester) async {
    final api = _FakeRoomsApi();
    expect(await _press(tester, api, settings, true), isTrue);
    expect(api.sent, [true]);
  });

  testWidgets('被 Hub 退回：回傳 false 讓開關撥回去，並原樣講它那句話',
      (tester) async {
    final api = _FakeRoomsApi(
        error: const ParticipantInvalidException(
            'room_owner_required', '只有房主能改這個設定。'));
    expect(await _press(tester, api, settings, false), isFalse);

    expect(api.sent, isEmpty);
    expect(find.text('只有房主能改這個設定。'), findsOneWidget);
  });
}
