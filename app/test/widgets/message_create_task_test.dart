import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/message.dart';
import 'package:chatroom_app/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 從一則訊息長出一張 Task。
///
/// 🔴 **這是 App 上唯一產得出 `source_seq` 的路徑。** Hub 一直收那個欄位、
/// 卡片抽屜也一直畫著「↩ 跳回聊天室」，但 App 這側沒有任何地方生得出那個
/// 值——agent 用 MCP 建卡時有，人只能從 board 畫面建，而那裡沒有「來源
/// 訊息」這種東西。所以那條回去的路，對人類建的卡等於不存在。
Message _msg({int seq = 42}) => Message(
      id: 'm1',
      seq: seq,
      updateSeq: 0,
      kind: 'chat',
      content: '封存房間應該還能看 Board',
      createdAt: '2026-09-01T00:00:00+00:00',
      senderId: 'p1',
      senderName: '艾斯維爾',
    );

MessageActions _actions({
  required void Function(Message) onCreateTask,
  bool enabled = true,
}) =>
    MessageActions(
      onReply: (_) {},
      onTogglePin: (_) {},
      onDelete: (_) {},
      onEdit: (_) {},
      onCreateTask: onCreateTask,
      enabled: enabled,
    );

Widget _wrap(Widget child) => MaterialApp(
      theme: buildUepTheme(Brightness.dark),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  testWidgets('🔴 訊息選單有「建立任務」，按下去帶的是那則訊息', (tester) async {
    Message? got;
    await tester.pumpWidget(_wrap(MessageBubble(
      message: _msg(),
      isSelf: false,
      senderKind: 'human',
      actions: _actions(onCreateTask: (m) => got = m),
    )));

    await tester.longPress(find.text('封存房間應該還能看 Board'));
    await tester.pumpAndSettle();
    expect(find.text('❖　建立任務'), findsOneWidget);

    await tester.tap(find.text('❖　建立任務'));
    await tester.pumpAndSettle();

    // seq 就是 source_seq 的來源。帶錯的話卡片會指回另一則訊息，
    // 而那種錯誤在畫面上完全看不出來
    expect(got?.seq, 42);
  });

  testWidgets('封存房不給——它是寫入，跟釘選／刪除同一個閘', (tester) async {
    await tester.pumpWidget(_wrap(MessageBubble(
      message: _msg(),
      isSelf: false,
      senderKind: 'human',
      actions: _actions(onCreateTask: (_) {}, enabled: false),
    )));

    await tester.longPress(find.text('封存房間應該還能看 Board'));
    await tester.pumpAndSettle();

    expect(find.text('❖　建立任務'), findsNothing);
    // 對照組：唯讀房仍然留著「複製內容」，不是整個選單消失
    expect(find.text('⧉　複製內容'), findsOneWidget);
  });

  testWidgets('釘選與建立任務並存——兩件事不互相取代', (tester) async {
    // 釘選是「這則訊息很重要」，任務是「這則訊息要有人去做」。
    // 用其中一個取代另一個，會讓另一件事無處可去（同 Q1 的理由）
    await tester.pumpWidget(_wrap(MessageBubble(
      message: _msg(),
      isSelf: false,
      senderKind: 'human',
      actions: _actions(onCreateTask: (_) {}),
    )));

    await tester.longPress(find.text('封存房間應該還能看 Board'));
    await tester.pumpAndSettle();

    expect(find.text('❖　釘選'), findsOneWidget);
    expect(find.text('❖　建立任務'), findsOneWidget);
  });
}
