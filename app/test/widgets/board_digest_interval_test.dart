import 'package:chatroom_app/api/board_api.dart';
import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board_contributions.dart';
import 'package:chatroom_app/screens/board/board_settings_screen.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/l10n.dart';

/// 任務板設定頁的「摘要間隔」：選項用分鐘，預設＝不送值（Hub 用預設）。
const _config = AppConfig(
  serverUrl: 'http://test',
  token: 'token',
  themeMode: ThemeModePref.dark,
  preferredName: 'Bernie',
  deviceKey: 'device-key',
);

class _FakeBoardsApi extends BoardsApi {
  _FakeBoardsApi({this.role = 'owner', this.digestSec}) : super(Dio());

  final String role;
  int? digestSec;
  final List<Map<String, Object?>> saved = [];

  @override
  Future<BoardContributions> contributions(
    String boardId, {
    required String sessionKey,
    int limit = 50,
    int offset = 0,
  }) async =>
      BoardContributions.fromJson({
        'board_id': 'b1',
        'board': {
          'name': '板',
          'description': '',
          'status': 'active',
          'my_role': role,
          'owner_name': 'Bernie',
          'digest_interval_sec': digestSec,
          'digest_interval_default': 900,
        },
        'entries': const [],
        'total': 0,
        'has_more': false,
        'stats': const [],
      });

  @override
  Future<void> updateSettings(
    String boardId, {
    required String sessionKey,
    String? name,
    String? description,
    int? digestIntervalSec,
    bool resetDigestInterval = false,
  }) async {
    saved.add({
      'sec': digestIntervalSec,
      'reset': resetDigestInterval,
      'name': name,
    });
    if (resetDigestInterval) digestSec = null;
    if (digestIntervalSec != null) digestSec = digestIntervalSec;
  }
}

Future<void> _open(WidgetTester tester, _FakeBoardsApi api) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsRepository(await SharedPreferences.getInstance());
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      settingsRepoProvider.overrideWithValue(settings),
      initialConfigProvider.overrideWithValue(_config),
      boardsApiProvider.overrideWithValue(api),
    ],
    child: MaterialApp(
      localizationsDelegates: kTestLocalizationsDelegates,
      supportedLocales: kTestSupportedLocales,
      locale: kTestLocale,
      theme: buildUepTheme(Brightness.dark),
      home: const BoardSettingsScreen(boardId: 'b1'),
    ),
  ));
  await tester.pumpAndSettle();
}

Finder get _dropdown => find.byKey(const ValueKey('board-digest-interval'));

void main() {
  testWidgets('顯示摘要間隔，預設值顯示「預設」', (tester) async {
    await _open(tester, _FakeBoardsApi());
    expect(find.text('摘要間隔'), findsOneWidget);
    expect(find.text('預設'), findsOneWidget);
  });

  testWidgets('選 30 分鐘後儲存，送出 1800 秒', (tester) async {
    final api = _FakeBoardsApi();
    await _open(tester, api);
    await tester.tap(_dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('30 分鐘').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('儲存'));
    await tester.pumpAndSettle();
    expect(api.saved, [
      {'sec': 1800, 'reset': false, 'name': null},
    ]);
  });

  testWidgets('已有設定值時顯示該值；改回「預設」會明確重設', (tester) async {
    final api = _FakeBoardsApi(digestSec: 300);
    await _open(tester, api);
    expect(find.text('5 分鐘'), findsOneWidget);
    await tester.tap(_dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('預設').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('儲存'));
    await tester.pumpAndSettle();
    expect(api.saved, [
      {'sec': null, 'reset': true, 'name': null},
    ]);
  });

  testWidgets('非 owner 不能改', (tester) async {
    await _open(tester, _FakeBoardsApi(role: 'viewer'));
    final dd = tester.widget<DropdownButton<int?>>(_dropdown);
    expect(dd.onChanged, isNull);
  });
}
