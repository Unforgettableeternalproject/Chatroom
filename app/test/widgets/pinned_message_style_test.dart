import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/core/theme/uep_tokens.dart';
import 'package:chatroom_app/models/message.dart';
import 'package:chatroom_app/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 釘選訊息的**常駐**強調（09/08 卡 4f797666，艾斯維爾附圖）。
///
/// 原本釘選只有 alpha .22 的金框，在一整頁訊息裡幾乎看不出來——而釘選是
/// 決議索引，看不出來的索引等於沒有索引。現在用的是原本「跳轉聚焦」那個
/// 強度，聚焦則改成外圈呼吸。
///
/// ⚠️ 這份測試的重點是**兩者分得開**：都用金色，一個靜止一個會動。只驗
/// 「釘選是金色」的話，聚焦回頭用同一個強度也會綠，而那正是這張卡要修的
/// 那個畫面。
Message _msg({bool pinned = false}) => Message(
      id: 'm1',
      seq: 1,
      updateSeq: 0,
      kind: 'chat',
      content: '終局裁定，不再讓來讓去',
      createdAt: '2026-09-08T00:00:00+00:00',
      senderId: 'p1',
      senderName: '決策Novia',
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
  testWidgets('🔴 釘選的訊息常駐一圈實色金框，不是幾乎看不見的淡金',
      (tester) async {
    await tester.pumpWidget(_wrap(MessageBubble(
      message: _msg(pinned: true),
      isSelf: false,
      senderKind: 'claude',
    )));

    expect(_bubbleBorderColor(tester), UepColors.gold);
    expect(find.text('❖ 已釘選'), findsOneWidget);
  });

  testWidgets('沒釘選的訊息不長金框——強調要有對照才是強調', (tester) async {
    await tester.pumpWidget(_wrap(MessageBubble(
      message: _msg(),
      isSelf: false,
      senderKind: 'claude',
    )));

    expect(_bubbleBorderColor(tester), isNot(UepColors.gold));
  });

  testWidgets('🔴 釘選但沒跳到它時，外圈不呼吸——會動的只有「你剛跳到這裡」',
      (tester) async {
    await tester.pumpWidget(_wrap(MessageBubble(
      message: _msg(pinned: true),
      isSelf: false,
      senderKind: 'claude',
    )));

    // 靜止的常駐金框在氣泡自己身上，外圈那層根本不存在
    expect(_pulseAlpha(tester), isNull);
  });

  testWidgets('跳到一則釘選訊息：常駐金框留著，外圈另外呼吸', (tester) async {
    await tester.pumpWidget(_wrap(MessageBubble(
      message: _msg(pinned: true),
      isSelf: false,
      senderKind: 'claude',
      highlighted: true,
    )));

    // 兩件事同時成立：這則很重要（靜止）、你剛跳到這裡（會動）
    expect(_bubbleBorderColor(tester), UepColors.gold);
    final first = _pulseAlpha(tester);
    expect(first, isNotNull);
    await tester.pump(const Duration(milliseconds: 550));
    expect(_pulseAlpha(tester), isNot(first));
  });
}
