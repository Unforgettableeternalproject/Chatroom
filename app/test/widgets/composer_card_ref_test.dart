import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/participant.dart';
import 'package:chatroom_app/widgets/mention_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// `#` 卡片指涉的 App 側：候選與插入那半（契約 v1 — 09/09 房 seq 32／40／44）。
///
/// chip 渲染與點擊跳卡等 Hub 的 `card_refs` 欄位落地後再做，不在這一輪。
void main() {
  const cards = [
    CardCandidate(
      boardId: 'b1',
      taskId: 't1',
      title: '釘選列表跳訊息：訊息多的房間定位會偏',
      status: 'done',
    ),
    CardCandidate(
      boardId: 'b1',
      taskId: 't2',
      title: '聊天框用上下鍵遍歷輸入歷史',
      status: 'todo',
    ),
  ];

  Widget wrap({List<CardCandidate> cards = const []}) => MaterialApp(
        theme: buildUepTheme(Brightness.dark),
        home: Scaffold(
          body: MessageComposer(
            members: [
              Participant(
                id: 'p1',
                kind: 'claude',
                displayName: 'Alpha',
                role: 'agent',
                status: 'active',
                joinedAt: '2026-09-09T00:00:00+00:00',
              ),
            ],
            cards: cards,
            onSend: (_, __) async {},
          ),
        ),
      );

  String textOf(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  Future<void> type(WidgetTester tester, String text) async {
    await tester.tap(find.byType(TextField));
    await tester.pump();
    tester.state<EditableTextState>(find.byType(EditableText)).updateEditingValue(
          TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          ),
        );
    await tester.pump();
  }

  group('候選', () {
    testWidgets('打 # 跳出板上的卡', (tester) async {
      await tester.pumpWidget(wrap(cards: cards));
      await type(tester, '#');
      expect(find.textContaining('釘選列表跳訊息'), findsOneWidget);
    });

    testWidgets('🔴 標題用 contains 比對，不是 startsWith', (tester) async {
      await tester.pumpWidget(wrap(cards: cards));
      await type(tester, '#定位');
      expect(find.textContaining('釘選列表跳訊息'), findsOneWidget,
          reason: '沒有人記得住一張卡的開頭是什麼，記得住的是中間那幾個字');
    });

    testWidgets('🔴 卡片標題含空白也比得到——# 不能沿用 @ 的空白邊界',
        (tester) async {
      const spaced = [
        CardCandidate(boardId: 'b1', taskId: 't9', title: '修 A 與 B 的接縫'),
      ];
      await tester.pumpWidget(wrap(cards: spaced));
      await type(tester, '#修 A 與');
      expect(find.textContaining('修 A 與 B 的接縫'), findsOneWidget,
          reason: '名字裡沒有空白但卡片標題有，兩者的邊界規則不能共用一套');
    });

    testWidgets('沒有卡（房間沒掛板）時 # 不彈選單', (tester) async {
      await tester.pumpWidget(wrap());
      await type(tester, '#');
      expect(find.textContaining('釘選列表'), findsNothing);
    });

    testWidgets('比不到任何卡就收起選單', (tester) async {
      await tester.pumpWidget(wrap(cards: cards));
      await type(tester, '#完全不存在的東西');
      expect(find.textContaining('釘選列表'), findsNothing);
    });

    testWidgets('🔴 游標停在插好的指涉後面，不重新彈選單', (tester) async {
      await tester.pumpWidget(wrap(cards: cards));
      await type(tester, '#[聊天框用上下鍵遍歷輸入歷史] 這張');
      expect(find.textContaining('釘選列表跳訊息'), findsNothing,
          reason: '`]` 是右界，往回找觸發字元時要停在那裡');
    });

    testWidgets('@ 的候選不受影響', (tester) async {
      await tester.pumpWidget(wrap(cards: cards));
      await type(tester, '@Alp');
      expect(find.text('Alpha'), findsOneWidget);
    });
  });

  group('插入', () {
    testWidgets('🔴 選中之後落地的是有界的 #[標題]', (tester) async {
      await tester.pumpWidget(wrap(cards: cards));
      await type(tester, '#輸入歷史');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(textOf(tester), '#[聊天框用上下鍵遍歷輸入歷史] ',
          reason: '中文沒有空白可以當右邊界，裸標題比對必然在前綴上出錯');
    });

    testWidgets('方向鍵沿用同一套仲裁——↓ 之後 Enter 選的是第二張',
        (tester) async {
      await tester.pumpWidget(wrap(cards: cards));
      await type(tester, '#');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(textOf(tester), '#[聊天框用上下鍵遍歷輸入歷史] ');
    });

    testWidgets('插在句子中間時只換掉 # 那一段', (tester) async {
      await tester.pumpWidget(wrap(cards: cards));
      await type(tester, '我看了 #輸入歷史');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(textOf(tester), '我看了 #[聊天框用上下鍵遍歷輸入歷史] ');
    });
  });

  group('extractCardRefs', () {
    test('內文有 #[標題] 才算指涉', () {
      final refs = extractCardRefs('看一下 #[聊天框用上下鍵遍歷輸入歷史] 這張', cards);
      expect(refs.map((c) => c.taskId), ['t2']);
    });

    test('🔴 裸標題不算——沒有那兩個括號就沒有可靠的右邊界', () {
      expect(extractCardRefs('看一下 聊天框用上下鍵遍歷輸入歷史 這張', cards), isEmpty);
    });

    test('🔴 前綴不會誤中', () {
      const pair = [
        CardCandidate(boardId: 'b', taskId: 'short', title: '登入頁重構'),
        CardCandidate(boardId: 'b', taskId: 'long', title: '登入頁重構的問題'),
      ];
      final refs = extractCardRefs('#[登入頁重構的問題]', pair);
      expect(refs.map((c) => c.taskId), ['long'],
          reason: '有界比對正是為了這個——裸標題會讓兩張都中');
    });

    test('同一張卡提兩次只算一個指涉', () {
      final refs = extractCardRefs(
        '#[聊天框用上下鍵遍歷輸入歷史] 跟 #[聊天框用上下鍵遍歷輸入歷史]',
        cards,
      );
      expect(refs.length, 1);
    });

    test('對不上任何卡的 #[...] 不產生指涉', () {
      expect(extractCardRefs('#[買牛奶]', cards), isEmpty);
    });

    test('帶的是發文當下的標題快照', () {
      final refs = extractCardRefs('#[聊天框用上下鍵遍歷輸入歷史]', cards);
      expect(refs.single.title, '聊天框用上下鍵遍歷輸入歷史');
      expect(refs.single.boardId, 'b1');
    });
  });
}
