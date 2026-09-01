import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/core/theme/uep_tokens.dart';
import 'package:chatroom_app/models/message.dart';
import 'package:chatroom_app/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 標記成員的訊息強調：整圈 kind 色邊框 + 淡底 + 名字旁的 ★。
///
/// 只加粗左軸的版本被推翻過——訊息一多根本看不出 2px 與 5px 的差別。
/// 這份測試釘的是「強調必須看得見」：邊框要真的換成 kind 色、★ 要真的
/// 出現，而跳轉聚焦（暫態金框）仍然壓得過它。
Message _msg({bool pinned = false}) => Message(
      id: 'm1',
      seq: 1,
      updateSeq: 0,
      kind: 'chat',
      content: '進度如何？',
      createdAt: '2026-09-01T00:00:00+00:00',
      senderId: 'p1',
      senderName: '米勒',
      pinned: pinned,
    );

Widget _wrap(Widget child) => MaterialApp(
      theme: buildUepTheme(Brightness.dark),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

/// 訊息卡片那層 Container 的邊框顏色（帶圓角、整圈 Border.all 的那個）。
Color _bubbleBorderColor(WidgetTester tester) {
  final box = tester
      .widgetList<Container>(find.byType(Container))
      .map((c) => c.decoration)
      .whereType<BoxDecoration>()
      .firstWhere((d) => d.borderRadius != null && d.border is Border);
  return (box.border! as Border).top.color;
}

void main() {
  testWidgets('標記的發話者：邊框與淡底換成他的 kind 色，名字旁出現 ★',
      (tester) async {
    await tester.pumpWidget(_wrap(MessageBubble(
      message: _msg(),
      isSelf: false,
      senderKind: 'codex',
      memberHighlighted: true,
    )));
    expect(find.text('★'), findsOneWidget);
    const kind = UepColors.kindCodex;
    expect(_bubbleBorderColor(tester), kind.withValues(alpha: .55));
  });

  testWidgets('沒有標記：沒有 ★，邊框維持一般線色', (tester) async {
    await tester.pumpWidget(_wrap(MessageBubble(
      message: _msg(),
      isSelf: false,
      senderKind: 'codex',
    )));
    expect(find.text('★'), findsNothing);
    const kind = UepColors.kindCodex;
    expect(_bubbleBorderColor(tester), isNot(kind.withValues(alpha: .55)));
  });

  testWidgets('跳轉聚焦的暫態金框壓過成員標記——「我剛跳到這則」不能被常駐狀態蓋掉',
      (tester) async {
    await tester.pumpWidget(_wrap(MessageBubble(
      message: _msg(),
      isSelf: false,
      senderKind: 'codex',
      memberHighlighted: true,
      highlighted: true,
    )));
    expect(_bubbleBorderColor(tester), UepColors.gold);
  });

  testWidgets('標記壓過釘選的邊框——釘選在 header 已有字樣，不丟資訊',
      (tester) async {
    await tester.pumpWidget(_wrap(MessageBubble(
      message: _msg(pinned: true),
      isSelf: false,
      senderKind: 'codex',
      memberHighlighted: true,
    )));
    const kind = UepColors.kindCodex;
    expect(_bubbleBorderColor(tester), kind.withValues(alpha: .55));
    expect(find.text('❖ 已釘選'), findsOneWidget);
  });
}
