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

/// 送出綁定這一步。
///
/// 綁定**不可復原**，所以只有兩件事要守：送出去的 key 就是確認框上那個
/// （送錯的話那個房間永遠派到錯的地方），以及被 Hub 退回時要把它那句話
/// 原樣講出來——「不是房主」「已經綁過了」「沒有執行器服務它」三種處置
/// 完全不同，改寫成同一句「綁定失敗」等於什麼都沒說。
class _FakeRoomsApi extends RoomsApi {
  _FakeRoomsApi({this.error}) : super(Dio());

  final ApiException? error;
  final List<String> bound = [];
  String? lastSessionKey;

  @override
  Future<Room> bindWorkspace(
    String roomId, {
    required String workspaceKey,
    String? sessionKey,
    String? participantId,
  }) async {
    lastSessionKey = sessionKey;
    final e = error;
    if (e != null) throw e;
    bound.add(workspaceKey);
    return Room.fromJson({
      'id': roomId,
      'name': '工作房',
      'kind': 'ops',
      'created_at': '2026-09-20T00:00:00+00:00',
      'workspace_key': workspaceKey,
      'workspace_served': true,
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

Future<void> _press(WidgetTester tester, _FakeRoomsApi api,
    SettingsRepository settings) async {
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
            onPressed: () => bindRoomWorkspace(context, ref,
                roomId: 'room-1', workspaceKey: 'ai-website'),
            child: const Text('送'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('送'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late SettingsRepository settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsRepository(await SharedPreferences.getInstance());
  });

  testWidgets('送出的就是那個 key，而且帶著身分——房主可能還沒 join 自己的房',
      (tester) async {
    final api = _FakeRoomsApi();
    await _press(tester, api, settings);

    expect(api.bound, ['ai-website']);
    expect(api.lastSessionKey, 'device-key');
    expect(find.text('已綁定「ai-website」。'), findsOneWidget);
  });

  testWidgets('被 Hub 退回時原樣講它那句話——三種退法的下一步不一樣',
      (tester) async {
    final api = _FakeRoomsApi(
        error: const ConflictException(
            'workspace_already_bound', '這個房間已經綁定 uep，不能更改。'));
    await _press(tester, api, settings);

    expect(api.bound, isEmpty);
    expect(find.text('這個房間已經綁定 uep，不能更改。'), findsOneWidget);
  });

  testWidgets('私人工作區綁到公開房間：講出那句話，下一步在房間設定那邊',
      (tester) async {
    final api = _FakeRoomsApi(
        error: const ConflictException(
            'workspace_private_room_required', 'private workspace'));
    await _press(tester, api, settings);

    expect(api.bound, isEmpty);
    // Hub 的原話是給機器看的，這一條的下一步（先把房間改成私人）
    // 在另一個畫面上——原樣轉述的話，人只會再按一次
    expect(find.text('這是私人工作區，只能綁到私人房間。'), findsOneWidget);
  });
}
