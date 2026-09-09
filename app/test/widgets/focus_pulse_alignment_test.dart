import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/message.dart';
import 'package:chatroom_app/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 🔴 2026-09-09（艾斯維爾 09/09 房 seq 22，附圖）：釘選跳轉的呼吸光暈框
/// 沒有貼合訊息氣泡，往左偏了一段。
///
/// 成因：`_FocusPulse` 用 `Positioned.fill` 貼合它 child 的尺寸，而它原本
/// 包的是**外面那層左軸**（左邊框 + `14 - axisWidth` 內距），不是氣泡本體。
///
/// ⚠️ **自己的訊息沒有那一層**，所以同一份程式碼在自己的訊息上是準的。
/// 「有時候準」正是它一直被當成小瑕疵放過的原因——所以兩邊都要驗，只驗
/// 別人的訊息會讓「把光暈改成包整個 Column」這種修法也綠。
void main() {
  Message msg({String content = '測試訊息'}) => Message(
        id: 'm1',
        seq: 1,
        updateSeq: 0,
        kind: 'chat',
        content: content,
        senderName: '某人',
        createdAt: '2026-09-09T00:00:00+00:00',
      );

  Widget wrap({required bool isSelf}) => MaterialApp(
        theme: buildUepTheme(Brightness.dark),
        home: Scaffold(
          body: Center(
            child: MessageBubble(
              message: msg(),
              isSelf: isSelf,
              senderKind: 'claude',
              highlighted: true,
            ),
          ),
        ),
      );

  /// 光暈框與氣泡本體的邊界。兩者應該完全重合。
  (Rect ring, Rect body) rects(WidgetTester tester) {
    Rect rectOf(String key) {
      final box = tester.renderObject<RenderBox>(find.byKey(Key(key)));
      final origin = box.localToGlobal(Offset.zero);
      return origin & box.size;
    }

    return (rectOf('focus-pulse-ring'), rectOf('bubble-body'));
  }

  testWidgets('🔴 別人的訊息：光暈框貼合氣泡，不是貼合左軸那一層',
      (tester) async {
    await tester.pumpWidget(wrap(isSelf: false));
    await tester.pump(const Duration(milliseconds: 100));

    final (ring, body) = rects(tester);
    expect(ring, body,
        reason: '光暈包到左軸那層的話，框會往左多出 14px——看起來就是沒有貼合氣泡');
  });

  testWidgets('自己的訊息：本來就準，修正不可以把它弄歪', (tester) async {
    await tester.pumpWidget(wrap(isSelf: true));
    await tester.pump(const Duration(milliseconds: 100));

    final (ring, body) = rects(tester);
    expect(ring, body);
  });

  testWidgets('沒有跳轉高亮時不畫光暈框', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildUepTheme(Brightness.dark),
      home: Scaffold(
        body: Center(
          child: MessageBubble(
            message: msg(),
            isSelf: false,
            senderKind: 'claude',
          ),
        ),
      ),
    ));
    await tester.pump();

    expect(find.byKey(const Key('focus-pulse-ring')), findsNothing);
  });
}
