import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/message.dart';
import 'package:chatroom_app/screens/chat/focus_preview.dart';
import 'package:chatroom_app/widgets/message_bubble.dart';
import 'package:chatroom_app/widgets/system_message_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/l10n.dart';

/// 遠距跳轉預覽：判斷、預覽 widget、「回到最新」按鈕。
void main() {
  Message msg(int seq, {bool system = false}) => Message(
        id: 'm$seq',
        seq: seq,
        updateSeq: 0,
        kind: system ? 'system' : 'chat',
        content: '發言 $seq',
        createdAt: '2026-11-11T01:00:00+00:00',
        senderId: system ? null : 'p',
        senderName: 'A',
        systemEvent: system ? 'run_done' : null,
      );

  Widget app(Widget child) => MaterialApp(
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: kTestSupportedLocales,
        locale: const Locale('zh', 'TW'),
        theme: buildUepTheme(Brightness.dark),
        home: Scaffold(body: child),
      );

  group('decideFocusMode', () {
    test('不在 feed：預覽', () {
      expect(decideFocusMode(inFeed: false, fromBottom: 0), FocusMode.preview);
    });
    test('在 feed 且近：真跳轉（含剛好門檻）', () {
      expect(decideFocusMode(inFeed: true, fromBottom: 3), FocusMode.jump);
      expect(decideFocusMode(inFeed: true, fromBottom: kFocusPreviewDistance),
          FocusMode.jump);
    });
    test('在 feed 但超過門檻：預覽', () {
      expect(
          decideFocusMode(
              inFeed: true, fromBottom: kFocusPreviewDistance + 1),
          FocusMode.preview);
    });
  });

  group('shouldShowJumpLatest', () {
    test('離底才顯示，預覽中一律顯示', () {
      expect(
          shouldShowJumpLatest(previewing: false, hasClients: true, pixels: 0),
          isFalse);
      expect(
          shouldShowJumpLatest(
              previewing: false, hasClients: true, pixels: kJumpLatestThreshold),
          isFalse);
      expect(
          shouldShowJumpLatest(
              previewing: false,
              hasClients: true,
              pixels: kJumpLatestThreshold + 1),
          isTrue);
      expect(
          shouldShowJumpLatest(previewing: true, hasClients: false, pixels: 0),
          isTrue);
    });
  });

  testWidgets('預覽：目標清晰有 FocusPulse，鄰近有 blur', (tester) async {
    final msgs = [
      msg(8),
      msg(9, system: true),
      msg(10),
      msg(11),
      msg(12),
    ];
    await tester.pumpWidget(app(FocusPreview(
      messages: msgs,
      targetSeq: 10,
      itemBuilder: (m, {required isTarget}) => m.isSystem
          ? (isTarget
              ? FocusPulse(child: SystemMessageTile(message: m))
              : SystemMessageTile(message: m))
          : Text(m.content, key: Key('t${m.seq}')),
    )));
    await tester.pump(const Duration(milliseconds: 300));

    // 目標沒有 ImageFiltered 祖先，鄰近都有
    expect(
        find.ancestor(
            of: find.byKey(const Key('t10')),
            matching: find.byType(ImageFiltered)),
        findsNothing);
    for (final s in [8, 11, 12]) {
      expect(
          find.ancestor(
              of: find.byKey(Key('t$s')), matching: find.byType(ImageFiltered)),
          findsOneWidget,
          reason: 'seq $s');
    }
    // 鄰近的 system 訊息也模糊
    expect(find.byKey(const Key('focus-preview-blur-9')), findsOneWidget);
    expect(find.byKey(const Key('focus-preview-blur-10')), findsNothing);
  });

  testWidgets('預覽：目標是 system 訊息時播 FocusPulse', (tester) async {
    await tester.pumpWidget(app(FocusPreview(
      messages: [msg(1), msg(2, system: true), msg(3)],
      targetSeq: 2,
      itemBuilder: (m, {required isTarget}) => m.isSystem
          ? (isTarget
              ? FocusPulse(child: SystemMessageTile(message: m))
              : SystemMessageTile(message: m))
          : Text(m.content),
    )));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('focus-pulse-ring')), findsOneWidget);
  });

  testWidgets('預覽：chat 目標用 MessageBubble(highlighted) 播 FocusPulse',
      (tester) async {
    await tester.pumpWidget(app(FocusPreview(
      messages: [msg(1), msg(2), msg(3)],
      targetSeq: 2,
      itemBuilder: (m, {required isTarget}) => MessageBubble(
        message: m,
        isSelf: false,
        senderKind: 'agent',
        actions: MessageActions(
          onReply: (_) {},
          onEdit: (_) {},
          onTogglePin: (_) {},
          onDelete: (_) {},
          onCreateTask: (_) {},
        ),
        highlighted: isTarget,
        serverUrl: '',
        token: '',
        roomId: 'r1',
      ),
    )));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('focus-pulse-ring')), findsOneWidget);
    expect(
        find.ancestor(
            of: find.byKey(const Key('focus-pulse-ring')),
            matching: find.byType(ImageFiltered)),
        findsNothing);
  });

  testWidgets('預覽中按「回到最新」：預覽關閉、按鈕消失', (tester) async {
    await tester.pumpWidget(app(_Host(msgs: [msg(1), msg(2), msg(3)])));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('focus-preview')), findsOneWidget);
    expect(find.text('回到最新'), findsOneWidget);
    await tester.tap(find.byKey(const Key('jump-latest')));
    await tester.pump();
    expect(find.byKey(const Key('focus-preview')), findsNothing);
    expect(find.byKey(const Key('jump-latest')), findsNothing);
  });

  group('JumpLatestButton', () {
    Widget host(int unread, VoidCallback onTap) =>
        app(Stack(children: [JumpLatestButton(unread: unread, onTap: onTap)]));

    testWidgets('沒有新訊息：顯示「回到最新」，可點', (tester) async {
      var taps = 0;
      await tester.pumpWidget(host(0, () => taps++));
      expect(find.text('回到最新'), findsOneWidget);
      expect(find.textContaining('新訊息'), findsNothing);
      await tester.tap(find.byKey(const Key('jump-latest')));
      expect(taps, 1);
    });

    testWidgets('有新訊息：改顯示新訊息字樣', (tester) async {
      await tester.pumpWidget(host(3, () {}));
      expect(find.text('有 3 則新訊息'), findsOneWidget);
      expect(find.text('回到最新'), findsNothing);
    });
  });
}

/// 模擬 ChatScreen 的接法：預覽中顯示 FocusPreview 與按鈕，按鈕關閉預覽。
class _Host extends StatefulWidget {
  const _Host({required this.msgs});
  final List<Message> msgs;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  bool _previewing = true;
  @override
  Widget build(BuildContext context) => Stack(children: [
        if (_previewing)
          FocusPreview(
            messages: widget.msgs,
            targetSeq: 2,
            itemBuilder: (m, {required isTarget}) => Text(m.content),
          ),
        if (_previewing)
          JumpLatestButton(
              unread: 0, onTap: () => setState(() => _previewing = false)),
      ]);
}
