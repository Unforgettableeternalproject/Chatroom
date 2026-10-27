import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/core/theme/uep_tokens.dart';
import 'package:chatroom_app/models/message.dart';
import 'package:chatroom_app/models/reaction.dart';
import 'package:chatroom_app/widgets/message_bubble.dart';
import 'package:chatroom_app/widgets/message_reactions.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/l10n.dart';

const thumb = '\u{1F44D}';
const heart = '❤️';

Message _msg({List<ReactionSummary> reactions = const []}) => Message(
      id: 'm1',
      seq: 3,
      updateSeq: 0,
      kind: 'chat',
      content: '內容',
      senderName: '某人',
      createdAt: '2026-10-27T00:00:00+00:00',
      reactions: reactions,
    );

Widget _app(Widget child) => MaterialApp(
      localizationsDelegates: kTestLocalizationsDelegates,
      supportedLocales: kTestSupportedLocales,
      theme: buildUepTheme(Brightness.dark),
      home: Scaffold(body: Center(child: child)),
    );

MessageActions _actions({
  Future<void> Function(Message, String)? onReact,
  void Function(Message)? onShowReactors,
  bool enabled = true,
}) =>
    MessageActions(
      onReply: (_) {},
      onTogglePin: (_) {},
      onDelete: (_) {},
      onEdit: (_) {},
      onCreateTask: (_) {},
      onReact: onReact,
      onShowReactors: onShowReactors,
      enabled: enabled,
    );

const _two = [
  ReactionSummary(emoji: thumb, count: 2, mine: true, names: ['我', 'Bob']),
  ReactionSummary(emoji: heart, count: 1, mine: false, names: ['Amy']),
];

void main() {
  testWidgets('chip 顯示 emoji 與數量，自己選的有金色框', (tester) async {
    await tester.pumpWidget(_app(MessageBubble(
      message: _msg(reactions: _two),
      isSelf: false,
      senderKind: 'human',
      actions: _actions(onReact: (_, _) async {}),
    )));
    expect(find.text('2'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);

    BoxDecoration deco(String emoji) => tester
        .widget<Container>(find.descendant(
            of: find.byKey(Key('reaction-chip-$emoji')),
            matching: find.byType(Container)))
        .decoration! as BoxDecoration;
    expect((deco(thumb).border! as Border).top.color, UepColors.gold);
    expect((deco(heart).border! as Border).top.color, isNot(UepColors.gold));
  });

  testWidgets('點 chip 只開名單，不呼叫 onReact（不再 toggle）', (tester) async {
    var reacted = 0;
    Message? shown;
    await tester.pumpWidget(_app(MessageBubble(
      message: _msg(reactions: _two),
      isSelf: false,
      senderKind: 'human',
      actions: _actions(
        onReact: (_, _) async => reacted++,
        onShowReactors: (m) => shown = m,
      ),
    )));
    await tester.tap(find.byKey(const Key('reaction-chip-$thumb')));
    await tester.pump();
    expect(reacted, 0);
    expect(shown?.id, 'm1');
  });

  testWidgets('自己的訊息 chip 靠右、別人的靠左', (tester) async {
    Future<double> chipLeft(bool isSelf) async {
      await tester.pumpWidget(_app(SizedBox(
        width: 800,
        child: MessageBubble(
          message: _msg(reactions: _two),
          isSelf: isSelf,
          senderKind: 'human',
          actions: _actions(onReact: (_, _) async {}),
        ),
      )));
      return tester.getTopLeft(find.byKey(const Key('reaction-chip-$thumb'))).dx;
    }

    final others = await chipLeft(false);
    final mine = await chipLeft(true);
    expect(mine, greaterThan(others + 200));
  });

  testWidgets('hover 才出現加表情按鈕，點開快選列，選到後回呼', (tester) async {
    String? picked;
    await tester.pumpWidget(_app(MessageBubble(
      message: _msg(),
      isSelf: false,
      senderKind: 'human',
      actions: _actions(onReact: (_, e) async => picked = e),
    )));
    expect(find.byKey(const Key('reaction-add-button')), findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('內容')));
    await tester.pump();
    expect(find.byKey(const Key('reaction-add-button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('reaction-add-button')));
    await tester.pumpAndSettle();
    for (final e in kReactionEmojis) {
      expect(find.byKey(Key('reaction-picker-$e')), findsOneWidget);
    }
    await tester.tap(find.byKey(const Key('reaction-picker-$heart')));
    await tester.pumpAndSettle();
    expect(picked, heart);
  });

  testWidgets('快選列：目前自己選的有高亮，點它回傳同一個（呼叫端解讀為取消）',
      (tester) async {
    String? picked;
    await tester.pumpWidget(_app(MessageBubble(
      message: _msg(reactions: _two),
      isSelf: false,
      senderKind: 'human',
      actions: _actions(onReact: (_, e) async => picked = e),
    )));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('內容')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('reaction-add-button')));
    await tester.pumpAndSettle();

    BoxDecoration deco(String e) => tester
        .widget<Container>(find.descendant(
            of: find.byKey(Key('reaction-picker-$e')),
            matching: find.byType(Container)))
        .decoration! as BoxDecoration;
    expect((deco(thumb).border! as Border).top.color, UepColors.gold);
    expect((deco(heart).border! as Border).top.color, Colors.transparent);
    await tester.tap(find.byKey(const Key('reaction-picker-$thumb')));
    await tester.pumpAndSettle();
    expect(picked, thumb);
  });

  testWidgets('封存房（enabled=false）沒有加表情入口，chip 仍可看', (tester) async {
    await tester.pumpWidget(_app(MessageBubble(
      message: _msg(reactions: _two),
      isSelf: false,
      senderKind: 'human',
      actions: _actions(onReact: (_, _) async {}, enabled: false),
    )));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('內容')));
    await tester.pump();
    expect(find.byKey(const Key('reaction-add-button')), findsNothing);
    expect(find.byKey(const Key('reaction-chip-$thumb')), findsOneWidget);
  });

  testWidgets('沒給 onReact（例如 agent 身分）時沒有入口', (tester) async {
    await tester.pumpWidget(_app(MessageBubble(
      message: _msg(),
      isSelf: false,
      senderKind: 'human',
      actions: _actions(),
    )));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('內容')));
    await tester.pump();
    expect(find.byKey(const Key('reaction-add-button')), findsNothing);
  });

  testWidgets('右鍵選單有「加入表情」，選了之後開快選列', (tester) async {
    String? picked;
    await tester.pumpWidget(_app(MessageBubble(
      message: _msg(),
      isSelf: false,
      senderKind: 'human',
      actions: _actions(onReact: (_, e) async => picked = e),
    )));
    await tester.tap(find.text('內容'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('加入表情'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reaction-picker-$heart')));
    await tester.pumpAndSettle();
    expect(picked, heart);
  });

  group('名單面板', () {
    const reactors = [
      Reactor(
          participantId: 'p1',
          name: 'Alice',
          kind: 'human',
          role: 'human',
          emoji: thumb,
          mine: true),
      Reactor(
          participantId: 'p2',
          name: 'Bot',
          kind: 'claude',
          role: 'agent',
          emoji: thumb,
          mine: false),
      Reactor(
          participantId: 'p3',
          name: 'Carol',
          kind: 'human',
          role: 'human',
          emoji: heart,
          mine: false),
    ];

    testWidgets('依表情分頁，agent 帶標籤，我有按時可移除', (tester) async {
      var removed = 0;
      await tester.pumpWidget(_app(SizedBox(
        width: 360,
        height: 400,
        child: ReactorsPanel(
          load: () async => reactors,
          onRemoveMine: () async => removed++,
        ),
      )));
      await tester.pumpAndSettle();
      // 全部：三個人
      expect(find.byKey(const Key('reactor-p1')), findsOneWidget);
      expect(find.byKey(const Key('reactor-p2')), findsOneWidget);
      expect(find.byKey(const Key('reactor-p3')), findsOneWidget);
      expect(find.text('CLAUDE'), findsOneWidget);

      await tester.tap(find.byKey(const Key('reactor-tab-$heart')));
      await tester.pump();
      expect(find.byKey(const Key('reactor-p3')), findsOneWidget);
      expect(find.byKey(const Key('reactor-p1')), findsNothing);

      await tester.tap(find.byKey(const Key('reaction-remove-mine')));
      await tester.pump();
      expect(removed, 1);
    });

    testWidgets('我沒按時沒有「移除我的表情」', (tester) async {
      await tester.pumpWidget(_app(SizedBox(
        width: 360,
        height: 400,
        child: ReactorsPanel(
          load: () async => [reactors[1]],
          onRemoveMine: () async {},
        ),
      )));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reaction-remove-mine')), findsNothing);
    });
  });
}
