import 'package:chatroom_app/api/rooms_api.dart';
import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/models/room.dart';
import 'package:chatroom_app/screens/board/supervisor_panel.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:chatroom_app/state/rooms_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/l10n.dart';

/// supervisor 離場即卸任（艾斯維爾 2026-11-12）：欄位空白時面板顯示指定入口，
/// 不再有劃線或「已離開」狀態。
const _cfg = AppConfig(
  serverUrl: 'http://test',
  token: 't',
  themeMode: ThemeModePref.dark,
  preferredName: '我',
  deviceKey: 'k',
);

BoardSnapshot _snap(Map<String, dynamic>? supervisor) =>
    const BoardSnapshot().merge(BoardDelta.fromJson({
      'board_seq': 10,
      'full': true,
      'board_id': 'b1',
      'my_role': 'owner',
      'attached_rooms': [
        {
          'id': 'r1',
          'name': '測試房',
          'status': 'active',
          'supervisor': supervisor,
        },
      ],
    }));

Future<void> _open(WidgetTester tester, Map<String, dynamic>? sup) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      initialConfigProvider.overrideWithValue(_cfg),
      boardByIdProvider('b1').overrideWith((ref) async => _snap(sup)),
      roomDetailProvider('r1').overrideWith((ref) async => RoomDetail(
            room: Room(
              id: 'r1',
              name: '測試房',
              topic: '',
              status: 'active',
              createdAt: '2026-09-01T00:00:00+00:00',
            ),
            participants: const [],
            youAreAdmin: true,
          )),
    ],
    child: MaterialApp(
      localizationsDelegates: kTestLocalizationsDelegates,
      supportedLocales: kTestSupportedLocales,
      theme: buildUepTheme(Brightness.dark),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showSupervisorPanel(context, boardId: 'b1', roomId: 'r1'),
            child: const Text('開'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('開'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('supervisor 空白時顯示指定入口', (tester) async {
    await _open(tester, null);

    expect(tester.takeException(), isNull);
    expect(find.text('指派'), findsOneWidget);
    expect(find.text('已離開'), findsNothing);
    expect(find.text('已離開這間房'), findsNothing);
  });

  testWidgets('舊 Hub 帶 departed:true 也不會畫出已離開', (tester) async {
    await _open(tester, {
      'actor_key': 'k1',
      'display_name': '諾薇亞',
      'actor_kind': 'claude',
      'departed': true,
    });

    expect(find.text('已離開'), findsNothing);
    expect(find.text('已離開這間房'), findsNothing);
    expect(find.text('指派'), findsNothing);
  });
}
