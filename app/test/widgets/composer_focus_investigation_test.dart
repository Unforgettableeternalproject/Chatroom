import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/widgets/mention_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 🔴 2026-09-07：艾斯維爾「**打字時 focus 會不見，注音會出現字還沒打出來
/// 但不能動了，得在其他地方有過 text focus 才可以繼續打字**」，而且
/// 「**完全沒有動作的狀況還是會有**」「**所有房間都有**」。
///
/// ⚠️ 這與 `composer_ime_test.dart`（09/04，Enter 在組字中被當成送出）是
/// **同一個症狀的另一個成因**——那次修掉一個，症狀還在。症狀相同不代表原因
/// 相同。
///
/// 這支檔案是**調查紀錄**：每一條要嘛釘住一個已排除的假設（免得下一個人再
/// 走一次），要嘛釘住一個確認過的行為。**沒有驗證過的推測不寫進來。**
void main() {
  Widget wrap({required bool showLeading}) => MaterialApp(
        theme: buildUepTheme(Brightness.dark),
        home: Scaffold(
          body: Column(
            children: [
              if (showLeading) const SizedBox(height: 24),
              Expanded(
                child: MessageComposer(
                  members: const [],
                  initialText: '',
                  onSend: (_, _) async {},
                ),
              ),
            ],
          ),
        ),
      );

  /// ❌ **已排除的假設**：`ChatScreen` 的 Column 裡有三個 collection-if
  /// （釘選列、封存請求列、待答問題），我原本推論它們增減時會讓
  /// `MessageComposer` 對到不同的 Element、State 被丟棄重建。
  ///
  /// **不成立，而且理由值得記住**：Flutter 的 `updateChildren` 不是按索引
  /// 硬配，它**先同步前綴、再同步後綴，中間才用 key 配對**。composer 在那棵
  /// 樹裡是**最後一個 child**，尾端同步已經保護了它——前面怎麼增減都對得回
  /// 同一個 Element。
  ///
  /// ⇒ 為此加 key 不會修好任何東西。這條測試留著是為了讓下一個人不必再推
  /// 一次同樣的假設。
  testWidgets('前面的 sibling 增減不會動到 composer 的 State（尾端同步保護）',
      (tester) async {
    await tester.pumpWidget(wrap(showLeading: false));
    await tester.enterText(find.byType(TextField), '打到一半的字');
    await tester.pump();

    await tester.pumpWidget(wrap(showLeading: true));
    await tester.pump();

    expect(find.text('打到一半的字'), findsOneWidget);
  });

  /// 候選（@開發Novia (UI) 提的）：`_onTextChanged` 裡唯一的那個 `setState`
  /// ——它只在「空 → 有字」與「有字 → 空」的**那一瞬間**觸發（送出鈕的可用
  /// 狀態靠它）。時機正好落在「打第一個字」，而艾斯維爾的症狀是「字還沒打
  /// 出來就不能動了」。
  ///
  /// 這條要問的是：**那次 rebuild 會不會把 IME 的組字範圍清掉？**
  /// 組字範圍（`composing`）掉了，對輸入法而言 session 就斷了。
  testWidgets('組字中觸發「空→有字」的 rebuild，composing 範圍要留著',
      (tester) async {
    await tester.pumpWidget(wrap(showLeading: false));
    await tester.tap(find.byType(TextField));
    await tester.pump();

    final state = tester.state<EditableTextState>(find.byType(EditableText));

    // 注音組字第一個字：文字有了、但還在組字（composing 有效）。
    // 這一刻正是 `_hasText` 從 false 翻 true 的時候
    state.updateEditingValue(const TextEditingValue(
      text: 'ㄨㄛˇ',
      selection: TextSelection.collapsed(offset: 3),
      composing: TextRange(start: 0, end: 3),
    ));
    await tester.pump();

    final value = state.textEditingValue;
    expect(value.composing.isValid, isTrue,
        reason: 'composing 被清掉＝輸入法的組字 session 斷了，'
            '畫面上的症狀就是「字還沒打出來但不能動了」');
    expect(value.text, 'ㄨㄛˇ');
  });
}
