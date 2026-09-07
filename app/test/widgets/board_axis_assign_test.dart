import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/screens/board/board_task_drawer.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 板軸沒有「請人接手」入口（原卡 444d5ceb，決策 2026-09-07 裁「房選擇器」路）。
///
/// 從 Board Library 進來時 `roomId` 是 null，而指派的目標是**房內身分**——
/// 板可以掛好幾間房，也可以一間都沒掛，所以「指派給誰」在板軸上沒有唯一
/// 答案。裁決的形狀：**指派前先選房**。
///
/// - 掛一間 → 直接用那間，不問
/// - 掛多間 → 先選房，再選人
/// - 零房 → 入口停用，並說出為什麼（不是消失：消失會被讀成「這個功能沒做」）
///
/// ⚠️ 停用而不是隱藏，是刻意的。板軸與房軸看到的操作要對得起來——少一顆
/// 按鈕沒有任何症狀，那正是 09/03 與 09/07 各踩過一次的形狀。
const _cfg = AppConfig(
  serverUrl: 'http://test',
  token: 't',
  themeMode: ThemeModePref.dark,
  preferredName: '我',
  deviceKey: 'k',
);

BoardTask _task() => BoardTask.fromJson({
      'id': 't1',
      'checklist_id': 'c1',
      'title': '一張卡',
      'status': 'todo',
    });

BoardSnapshot _snap({required List<Map<String, dynamic>> rooms}) =>
    const BoardSnapshot().merge(BoardDelta.fromJson({
      'board_seq': 10,
      'full': true,
      'board_id': 'b1',
      'my_role': 'owner',
      'attached_rooms': rooms,
    }));

Future<void> _pump(WidgetTester tester, BoardSnapshot snap) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      initialConfigProvider.overrideWithValue(_cfg),
      boardByIdProvider('b1').overrideWith((ref) async => snap),
    ],
    child: MaterialApp(
      theme: buildUepTheme(Brightness.dark),
      home: Scaffold(
        body: BoardTaskDrawer(
          roomId: null,
          boardId: 'b1',
          task: _task(),
          checklistTitle: '階段',
          onClose: () {},
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('🔴 板軸掛著房時，「請人接手」要在', (tester) async {
    await _pump(
        tester,
        _snap(rooms: [
          {'id': 'r1', 'name': '開發 09/07', 'status': 'active'},
        ]));

    expect(tester.takeException(), isNull);
    expect(find.text('請人接手'), findsOneWidget);
  });

  testWidgets('🔴 一間房都沒掛：入口留著但停用，並說得出為什麼', (tester) async {
    await _pump(tester, _snap(rooms: const []));

    // 按鈕還在——**消失會被讀成「板軸沒有這個功能」**，而真相是
    // 「這塊板現在沒有人可以指」
    expect(find.text('請人接手'), findsOneWidget);
    expect(find.text('掛到房間後才能指派'), findsOneWidget);
  });

  testWidgets('解除掛接的房不算——它已經不是這塊板構得到的人', (tester) async {
    await _pump(
        tester,
        _snap(rooms: [
          {
            'id': 'r1',
            'name': '舊房',
            'status': 'active',
            'detached': true,
          },
        ]));

    // 對照組：`detached` 的房若被算進去，指派會送到一個與這塊板
    // 已經無關的房裡，而 server 那端會拒——UI 不該先製造那次失敗
    expect(find.text('掛到房間後才能指派'), findsOneWidget);
  });
}
