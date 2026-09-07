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

/// 🔴 Bernie 2026-09-07 想法板（4cc16199）：**從已封存房間的入口進去，
/// 指派 Supervisor 的按鈕還在**。
///
/// Server 端本來就擋著（`POST /api/rooms/{id}/board/supervisor` 走
/// `_room_or_404` → 409 `room_archived`，主持人模式也繞不過，@開發Novia (Hub)
/// 09/07 查證 + 補了迴歸測試），所以按下去不會有事——但那顆按鈕是在**邀請
/// 一個必定失敗的動作**，跟壞掉沒兩樣。
///
/// ⚠️ 消失與停用不同，這裡選消失＋說明：封存是「這段歷史結束了」，
/// 不是「你現在沒有權限」。留一顆灰按鈕會讓人去找怎麼拿到權限。
///
/// 唯讀的那顆（「誰在做什麼」）**要留著**——封存房照樣讀得到板，
/// 把整段藏掉的話，回頭查「當初是誰在看」就沒有入口了。
Room _room(String status) => Room(
      id: 'r1',
      name: '測試房',
      topic: '',
      status: status,
      createdAt: '2026-09-01T00:00:00+00:00',
    );

const _cfg = AppConfig(
  serverUrl: 'http://test',
  token: 't',
  themeMode: ThemeModePref.dark,
  preferredName: '我',
  deviceKey: 'k',
);

BoardSnapshot _snap(String roomStatus) =>
    const BoardSnapshot().merge(BoardDelta.fromJson({
      'board_seq': 10,
      'full': true,
      'board_id': 'b1',
      'my_role': 'owner',
      'attached_rooms': [
        {'id': 'r1', 'name': '測試房', 'status': roomStatus},
      ],
    }));

Future<void> _open(WidgetTester tester, String roomStatus) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      initialConfigProvider.overrideWithValue(_cfg),
      boardByIdProvider('b1').overrideWith((ref) async => _snap(roomStatus)),
      // 房間管理者——指派入口的權限判準，兩個情境都給滿，
      // 這樣消失與否只剩下「房封存了沒」一個變因
      roomDetailProvider('r1').overrideWith((ref) async => RoomDetail(
            room: _room(roomStatus),
            participants: const [],
            youAreAdmin: true,
          )),
    ],
    child: MaterialApp(
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
  testWidgets('🔴 封存房裡看不到指派入口，但要說出為什麼', (tester) async {
    await _open(tester, 'archived');

    expect(tester.takeException(), isNull);
    expect(find.text('指派'), findsNothing);
    // 只是消失的話，看的人會以為自己權限不夠而去找怎麼要權限
    expect(find.text('這間房已封存，人事不再變動。'), findsOneWidget);
    // 唯讀那顆留著：封存房照樣讀得到板
    expect(find.text('誰在做什麼'), findsOneWidget);
  });

  testWidgets('active 房不受影響——這次修的是封存，不是權限', (tester) async {
    await _open(tester, 'active');

    expect(find.text('指派'), findsOneWidget);
    expect(find.text('這間房已封存，人事不再變動。'), findsNothing);
  });
}
