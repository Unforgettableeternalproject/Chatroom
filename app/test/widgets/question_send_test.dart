import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/question.dart';
import 'package:chatroom_app/widgets/question_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 複選題的送出：一顆按鈕，選項與補充**一起送**。
///
/// 兩顆送出按鈕並排時，看的人得先讀懂它們差在哪才敢按——而它們送的曾經是
/// 互斥的兩種答案。Hub `87cc53f` 加了 `extra` 之後不必再二選一，
/// 所以這裡驗的是「按下去送出的到底是什麼」。
Question _q({bool multi = true, bool freeText = true}) => Question(
      id: 'q1',
      roomId: 'r1',
      prompt: '要納入哪些？',
      askerName: 'Novia',
      status: 'pending',
      createdAt: '2026-09-02T00:00:00Z',
      options: const [
        QuestionOption(label: '甲'),
        QuestionOption(label: '乙'),
      ],
      multiSelect: multi,
      allowFreeText: freeText,
    );

void main() {
  late List<Object?> sent;

  Widget host(Question q) => MaterialApp(
        theme: buildUepTheme(Brightness.dark),
        home: Scaffold(
          body: QuestionCard(
            question: q,
            onAnswer: (kind, answer, selected, files, extra) async {
              sent = [kind, answer, selected, extra];
            },
            onSkip: () async {},
          ),
        ),
      );

  setUp(() => sent = []);

  testWidgets('複選 + 可自由輸入時，畫面上只有一顆送出', (tester) async {
    await tester.pumpWidget(host(_q()));
    await tester.tap(find.text('甲'));
    await tester.pump();
    expect(find.text('送出所選 1'), findsOneWidget);
    // 舊版那顆獨立的「送出所選」不該再出現
    expect(find.text('送出所選'), findsNothing);
  });

  testWidgets('只選項：送 option，extra 空', (tester) async {
    await tester.pumpWidget(host(_q()));
    await tester.tap(find.text('甲'));
    await tester.pump();
    await tester.tap(find.text('送出所選 1'));
    await tester.pump();
    expect(sent[0], 'option');
    expect(sent[2], ['甲']);
    expect(sent[3], '');
  });

  testWidgets('選項 + 補充：一起送，不是二選一', (tester) async {
    await tester.pumpWidget(host(_q()));
    await tester.tap(find.text('乙'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '另外那個先別動');
    await tester.pump();
    // 按鈕的字要先說出它會送什麼
    expect(find.text('送出所選 1 ＋補充'), findsOneWidget);
    await tester.tap(find.text('送出所選 1 ＋補充'));
    await tester.pump();
    expect(sent[0], 'option');
    expect(sent[2], ['乙']);
    expect(sent[3], '另外那個先別動');
  });

  testWidgets('單選：先打字再點選項，那段字要一起送出', (tester) async {
    // 單選維持「點了就送」（多一個確認步驟會讓最常見的情況變慢），
    // 但先打字再點選項是很自然的順序——把那段字默默丟掉，
    // 使用者不會發現自己補的話沒送出去
    await tester.pumpWidget(host(_q(multi: false)));
    await tester.enterText(find.byType(TextField), '但乙那個要先確認');
    await tester.pump();
    await tester.tap(find.text('甲'));
    await tester.pump();
    expect(sent[0], 'option');
    expect(sent[1], '甲');
    expect(sent[3], '但乙那個要先確認');
  });

  testWidgets('只打字沒選：走 free_text，extra 必須是空的', (tester) async {
    // extra 跟 free_text 一起送會拿 422 extra_needs_option——
    // 那時打的字本身就是答案，不是補充
    await tester.pumpWidget(host(_q()));
    await tester.enterText(find.byType(TextField), '都不要，我自己寫');
    await tester.pump();
    await tester.tap(find.text('送出'));
    await tester.pump();
    expect(sent[0], 'free_text');
    expect(sent[1], '都不要，我自己寫');
    expect(sent[3], '');
  });
}
