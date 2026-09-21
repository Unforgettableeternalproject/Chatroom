import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/question.dart';
import 'package:chatroom_app/widgets/question_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/l10n.dart';

/// 提問者是派工跑出來的臨時 agent 時，「略過」那句話不成立。
///
/// 「改在原本的對話裡問我」預設 agent 有一個回得去的 session；run 成員是
/// 一次性的無頭進程，沒有那個地方。出口仍要留（抽掉的話問題只會擱到過期，
/// 而 expired 對 agent 的意思是「人沒看到」，那是假的），但意思要改成
/// 「我不回答，你自己決定」。
Question _q() => const Question(
      id: 'q1',
      roomId: 'r1',
      prompt: '這份要先發嗎？',
      askerName: 'Novia',
      status: 'pending',
      createdAt: '2026-09-20T00:00:00Z',
    );

void main() {
  Widget host({required bool onRun, void Function()? onSkip}) => ProviderScope(
        child: MaterialApp(
          localizationsDelegates: kTestLocalizationsDelegates,
          supportedLocales: kTestSupportedLocales,
          theme: buildUepTheme(Brightness.dark),
          home: Scaffold(
            body: QuestionCard(
              question: _q(),
              askerOnRun: onRun,
              onAnswer: (_, _, _, _, _) async {},
              onSkip: () async => onSkip?.call(),
            ),
          ),
        ),
      );

  testWidgets('一般 agent 提問：維持原本的略過', (tester) async {
    await tester.pumpWidget(host(onRun: false));
    expect(find.text('略過，改在原本的對話裡問我'), findsOneWidget);
    expect(find.text('不回答，讓它自己決定'), findsNothing);
  });

  testWidgets('run 成員提問：不出現「改在原本的對話裡問我」', (tester) async {
    await tester.pumpWidget(host(onRun: true));
    expect(find.text('略過，改在原本的對話裡問我'), findsNothing);
    expect(find.text('不回答，讓它自己決定'), findsOneWidget);
  });

  testWidgets('run 成員的出口仍然按得到——按下去走的是同一條 skip', (tester) async {
    var skipped = false;
    await tester.pumpWidget(host(onRun: true, onSkip: () => skipped = true));
    await tester.tap(find.text('不回答，讓它自己決定'));
    await tester.pump();
    expect(skipped, isTrue);
  });
}
