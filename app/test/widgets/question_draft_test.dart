import 'dart:async';

import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/question.dart';
import 'package:chatroom_app/state/composer_drafts.dart';
import 'package:chatroom_app/widgets/question_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 🔴 2026-09-04：**答題打到一半，卡片捲出視窗就沒了**
/// （@開發Novia (除錯) #414 系統性排查抓到的）。
///
/// 這張卡躺在聊天畫面一個 maxHeight 420 的 `ListView` 裡——待答問題多到
/// 要捲動時，捲出去的卡會被回收，`_QuestionCardState` 連同 controller
/// 一起 dispose。
///
/// **同一個病因的第三次**：訊息草稿跨房跑掉（09-02）、想法板輸入框被回收
/// （今天上午）、現在是這個。三次都不是「忘了存」，是**存在一個生命週期
/// 比它短的地方**。
Question _q(String id) => Question.fromJson({
      'id': id,
      'text': '要選哪一個？',
      'allow_free_text': true,
      'options': const [],
    });

Widget _wrap(ProviderContainer c, Widget child) => UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: buildUepTheme(Brightness.dark),
        home: Scaffold(body: child),
      ),
    );

void main() {
  testWidgets('🔴 卡片被回收再回來，打到一半的答案還在', (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);

    await tester.pumpWidget(_wrap(
        c, QuestionCard(question: _q('q1'), onAnswer: (_, _, _, _, _) async {}, onSkip: () async {})));
    await tester.enterText(find.byType(TextField), '打到一半的長答案');
    await tester.pump();

    // 卡片被回收（捲出視窗）：整棵樹換掉，State 連同 controller 消失
    await tester.pumpWidget(_wrap(c, const SizedBox.shrink()));
    await tester.pump();

    // 捲回來
    await tester.pumpWidget(_wrap(
        c, QuestionCard(question: _q('q1'), onAnswer: (_, _, _, _, _) async {}, onSkip: () async {})));
    await tester.pump();

    expect(find.text('打到一半的長答案'), findsOneWidget);
  });

  testWidgets('🔴 兩題各自的草稿不會串在一起', (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);

    await tester.pumpWidget(_wrap(
        c, QuestionCard(question: _q('q1'), onAnswer: (_, _, _, _, _) async {}, onSkip: () async {})));
    await tester.enterText(find.byType(TextField), '第一題的答案');
    await tester.pump();

    await tester.pumpWidget(_wrap(
        c, QuestionCard(question: _q('q2'), onAnswer: (_, _, _, _, _) async {}, onSkip: () async {})));
    await tester.pump();

    // q2 應該是空的——串在一起的話，答案會被送到錯的問題上
    expect(find.text('第一題的答案'), findsNothing);
    expect(c.read(questionDraftsProvider.notifier).of('q1'), '第一題的答案');
  });

  testWidgets('🔴 送出還沒完成之前不可以先清草稿', (tester) async {
    // ⚠️ **這條守的是「按下去就清」，不是「clear 放在 finally」。**
    //
    // 我一開始的註解寫成後者——**實測不成立**：`finally` 也在
    // `await action()` 之後跑，所以把 clear 移進 finally 時這條照樣綠。
    // 真正會讓它紅的是把 clear 移到 `await` **之前**（按下送出的當下就清）。
    //
    // ⚠️ **「送出失敗時草稿要留著」那半沒有測**：`_run` 只有 try/finally
    // 不捕捉例外，讓 onAnswer 拋出去會被測試框架記成測試失敗，而在 widget
    // test 裡吞掉那個例外試過三種方法都不成——成本超過它的價值。
    // 那半靠的是 `clear()` 寫在 try 內、await 之後（失敗時走不到），
    // **由閱讀保證，不由這條測試保證**。
    final c = ProviderContainer();
    addTearDown(c.dispose);

    final gate = Completer<void>();
    var tried = false;
    await tester.pumpWidget(_wrap(
        c,
        QuestionCard(
          question: _q('q3'),
          onAnswer: (_, _, _, _, _) async {
            tried = true;
            await gate.future;
          },
          onSkip: () async {},
        )));
    await tester.enterText(find.byType(TextField), '好不容易打完的長文');
    await tester.pump();

    await tester.tap(find.textContaining('送出'));
    await tester.pump();

    expect(tried, isTrue, reason: '沒點到送出鈕，這條測試等於沒測');
    expect(c.read(questionDraftsProvider.notifier).of('q3'), '好不容易打完的長文');

    gate.complete();
    await tester.pumpAndSettle();
    // 送出成功之後才該清掉
    expect(c.read(questionDraftsProvider.notifier).of('q3'), isEmpty);
  });
}
