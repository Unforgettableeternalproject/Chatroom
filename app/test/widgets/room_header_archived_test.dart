import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/screens/chat/chat_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 聊天室頂端那一排入口，分的是**檢視／寫入**，不是活著／封存。
///
/// 封存只禁止寫入，不禁止查看。這條界線踩過兩次同樣形狀的坑：入口整個活在
/// `else` 分支裡，房間一封存那扇門就沒了——而門後的東西早就做好唯讀了。
/// 第一次是 Board 入口，第二次是釘選牆（艾斯維爾 09/08 回報）。
///
/// 這排從來沒有被 widget 測試蓋到，所以兩次都要等人在實機上撞見。
Widget _wrap({required bool archived}) => ProviderScope(
      child: MaterialApp(
        theme: buildUepTheme(Brightness.dark),
        home: Scaffold(
          body: RoomHeader(
            roomId: 'r1',
            roomName: '測試房',
            topic: '',
            archived: archived,
            zoneLabel: 'ZONE',
            zoneColor: const Color(0xFF3DCC82),
            zoneStroke: const Color(0xFF3DCC82),
            pinnedCount: 3,
            memberCount: 2,
            showMembersButton: false,
          ),
        ),
      ),
    );

void main() {
  testWidgets('🔴 封存房仍看得到釘選牆的入口', (tester) async {
    await tester.pumpWidget(_wrap(archived: true));

    expect(find.text('❖ 釘選 3'), findsOneWidget);
    // 門後那一頁自己會收掉「取消釘選」，Hub 的讀取也明寫允許封存房——
    // 缺的自始至終只有這扇門
    expect(find.text('解除封存'), findsOneWidget);
  });

  testWidgets('封存房不出寫入類入口', (tester) async {
    await tester.pumpWidget(_wrap(archived: true));

    expect(find.text('指派'), findsNothing);
  });

  testWidgets('活著的房兩類都在', (tester) async {
    await tester.pumpWidget(_wrap(archived: false));

    expect(find.text('❖ 釘選 3'), findsOneWidget);
    expect(find.text('指派'), findsOneWidget);
    expect(find.text('解除封存'), findsNothing);
  });
}
