import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/screens/board/supervisor_panel.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 🔴 艾斯維爾 2026-09-06 實機（#237 截圖）：Supervisor 對話框「判斷與建議」
/// 那顆下拉選單**看起來是空的**。
///
/// 卡上列了兩種可能——選項沒載入（資料層）、或有選項但沒有 placeholder
/// （呈現層）。是後者：`_toActorKey` 初值是 null，而選單裡沒有任何一項的
/// value 是 null，`DropdownButtonFormField` 於是畫出一片空白。
///
/// ⚠️ **null 是刻意的**，不能靠給預設值解決：空字串在這裡是一個真正的選擇
/// （＝對整塊板廣播），所以「還沒挑」必須有自己的值，送出鈕才擋得住。
/// 缺的是把那個狀態**講出來**的那句話。
///
/// 而它與真正的資料層失敗（板上沒有成員）在畫面上長得一模一樣——
/// 一個是「你還沒挑」，一個是「沒有人可以收」，兩者處置相反。
BoardSnapshot _snap({List<Map<String, dynamic>> members = const []}) =>
    const BoardSnapshot().merge(BoardDelta.fromJson({
      'board_seq': 10,
      'full': true,
      'board_id': 'b1',
      'my_role': 'owner',
      'members': members,
    }));

const _cfg = AppConfig(
  serverUrl: 'http://test',
  token: 't',
  themeMode: ThemeModePref.dark,
  preferredName: '我',
  deviceKey: 'k',
);

Widget _wrap(BoardSnapshot snap) => ProviderScope(
      overrides: [
        initialConfigProvider.overrideWithValue(_cfg),
        boardByIdProvider('b1').overrideWith((ref) async => snap),
      ],
      child: MaterialApp(
        theme: buildUepTheme(Brightness.dark),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSupervisorPanel(context, boardId: 'b1'),
              child: const Text('開'),
            ),
          ),
        ),
      ),
    );

Future<void> _open(WidgetTester tester, BoardSnapshot snap) async {
  await tester.pumpWidget(_wrap(snap));
  await tester.tap(find.text('開'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('🔴 還沒挑收件者時，選單要說自己是「還沒挑」而不是一片空白',
      (tester) async {
    await _open(
        tester,
        _snap(members: [
          {'actor_key': 'a1', 'display_name': '開發Novia (UI)', 'role': 'editor'},
        ]));

    expect(tester.takeException(), isNull);
    expect(find.text('選一個收件者…'), findsOneWidget);
  });

  testWidgets('板上沒有成員是另一件事，講的話也不同', (tester) async {
    await _open(tester, _snap());

    // 這句本來就在，測它是為了釘住兩種空狀態**不會合而為一**：
    // 拿 placeholder 去補這個位置的話，「沒有人可以收」會被說成「你還沒挑」
    expect(find.text('這塊板上還沒有成員，沒有人可以收。'), findsOneWidget);
    expect(find.text('選一個收件者…'), findsNothing);
  });
}
