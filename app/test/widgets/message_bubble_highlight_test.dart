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

/// 外圈呼吸那一層的金色透明度。沒有聚焦時是 null。
double? _pulseAlpha(WidgetTester tester) {
  const rgb = 0x00FFFFFF;
  for (final w in tester.widgetList<DecoratedBox>(find.byType(DecoratedBox))) {
    final d = w.decoration;
    if (d is! BoxDecoration || d.border is! Border || d.color != null) continue;
    final c = (d.border! as Border).top.color;
    if (c.toARGB32() & rgb == UepColors.gold.toARGB32() & rgb) return c.a;
  }
  return null;
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

  // ⚠️ 這條原本斷言「聚焦把氣泡邊框換成金色」。**09/08 起聚焦改成疊在外圈
  // 的呼吸**（卡 4f797666）：釘選升級成常駐金框之後，兩者若共用同一個位置
  // 就會互相蓋掉——跳到一則沒釘選的訊息看起來像被釘了，跳到釘選訊息則什麼
  // 都看不出來。守的東西沒變（跳轉要壓得過常駐狀態），換的是它長在哪裡。
  testWidgets('跳轉聚焦疊在外圈且會呼吸——氣泡自己的強調留在原地不被吃掉',
      (tester) async {
    await tester.pumpWidget(_wrap(MessageBubble(
      message: _msg(),
      isSelf: false,
      senderKind: 'codex',
      memberHighlighted: true,
      highlighted: true,
    )));
    // 成員標記還在——聚焦沒有把它蓋掉
    expect(_bubbleBorderColor(tester),
        UepColors.kindCodex.withValues(alpha: .55));

    // 而「我剛跳到這裡」在外圈，**而且會動**：靜止的金框與釘選分不出來
    final first = _pulseAlpha(tester);
    expect(first, isNotNull);
    await tester.pump(const Duration(milliseconds: 550));
    expect(_pulseAlpha(tester), isNot(first));
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
