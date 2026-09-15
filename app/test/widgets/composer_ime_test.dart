import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/widgets/mention_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 🔴 2026-09-04：艾斯維爾「**我在打中文的時候卡住，要去其他地方聚焦
/// 才可以重新打字**」。
///
/// 成因：`_onKey` 把 Enter 一律當成「送出」，**沒有排除輸入法組字狀態**。
///
/// 中文（日文、韓文也一樣）每打一個詞都會先進組字狀態，那時的 Enter 是
/// 「確認這個候選字」。攔下來當送出的話：訊息在打到一半時飛出去，而且
/// IME 的 session 被打斷——畫面看起來就是「不能打字了」，而焦點跳走再
/// 回來會重建 session，所以「去其他地方聚焦」才會恢復。
///
/// ⚠️ 英數字打字時 `composing` 一直是無效的，所以這道判斷不會影響原本的
/// 送出行為——那半也測了，否則修好一邊會壞掉另一邊。
void main() {
  late List<String> sent;

  Widget wrap({String initial = ''}) => MaterialApp(
        theme: buildUepTheme(Brightness.dark),
        home: Scaffold(
          body: MessageComposer(
            members: const [],
            initialText: initial,
            onSend: (text, _) async => sent.add(text),
          ),
        ),
      );

  setUp(() => sent = []);

  Future<void> pressEnter(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
  }

  testWidgets('🔴 組字中按 Enter 不送出——那是在選字', (tester) async {
    await tester.pumpWidget(wrap());
    final field = find.byType(TextField);
    await tester.tap(field);
    await tester.pump();

    // 模擬 IME 組字：composing 範圍有效＝這段字還沒確認
    final state = tester.state<EditableTextState>(find.byType(EditableText));
    state.updateEditingValue(const TextEditingValue(
      text: 'ㄨㄛˇ',
      selection: TextSelection.collapsed(offset: 3),
      composing: TextRange(start: 0, end: 3),
    ));
    await tester.pump();

    await pressEnter(tester);
    expect(sent, isEmpty, reason: '組字中的 Enter 被當成送出，訊息會半途飛出去');
  });

  testWidgets('組字結束之後 Enter 照樣送得出去——不可以為了修這個把送出弄壞',
      (tester) async {
    await tester.pumpWidget(wrap());
    await tester.tap(find.byType(TextField));
    await tester.pump();

    final state = tester.state<EditableTextState>(find.byType(EditableText));
    // composing 空的＝已經確認過的字
    state.updateEditingValue(const TextEditingValue(
      text: '我',
      selection: TextSelection.collapsed(offset: 1),
    ));
    await tester.pump();

    await pressEnter(tester);
    await tester.pumpAndSettle();
    expect(sent, ['我']);
  });

  testWidgets('英數字打字不受影響——composing 一直是無效的', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await pressEnter(tester);
    await tester.pumpAndSettle();
    expect(sent, ['hello']);
  });
}
