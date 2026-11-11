import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/models/message.dart';
import 'package:chatroom_app/widgets/board_task_card.dart';
import 'package:chatroom_app/widgets/message_bubble.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import '../helpers/l10n.dart';

/// 開發者模式：卡片與訊息上的 ID 顯示、點擊複製、右鍵「複製訊息 ID」。
/// 關閉時畫面上完全沒有這些字。
Widget _wrap(Widget child) => MaterialApp(
      localizationsDelegates: kTestLocalizationsDelegates,
      supportedLocales: kTestSupportedLocales,
      locale: const Locale('zh', 'TW'),
      theme: buildUepTheme(Brightness.dark),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

BoardTask _task({String status = 'todo'}) => BoardTask(
      id: 'task-abc-123',
      roomId: 'r1',
      checklistId: 'c1',
      title: '某張卡',
      boardSeq: 1,
      status: status,
    );

Message _msg() => const Message(
      id: 'msg-uuid-9',
      seq: 42,
      updateSeq: 0,
      kind: 'chat',
      content: '哈囉',
      createdAt: '2026-09-01T00:00:00+00:00',
      senderId: 'p1',
      senderName: '米勒',
    );

MessageActions _actions() => MessageActions(
      onReply: (_) {},
      onTogglePin: (_) {},
      onDelete: (_) {},
      onEdit: (_) {},
      onCreateTask: (_) {},
    );

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  group('任務卡', () {
    testWidgets('devMode 關：沒有 ID', (tester) async {
      await tester.pumpWidget(_wrap(BoardTaskCard(task: _task())));
      expect(find.text('task-abc-123'), findsNothing);
    });

    testWidgets('devMode 開：顯示 ID，點了複製', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      await tester
          .pumpWidget(_wrap(BoardTaskCard(task: _task(), devMode: true)));
      expect(find.text('task-abc-123'), findsOneWidget);

      await tester.tap(find.text('task-abc-123'));
      await tester.pump();
      expect(copied, 'task-abc-123');
    });

    testWidgets('已完成的收合卡也有 ID', (tester) async {
      await tester.pumpWidget(_wrap(
          BoardTaskCard(task: _task(status: 'done'), devMode: true)));
      expect(find.text('task-abc-123'), findsOneWidget);
    });
  });

  group('訊息', () {
    for (final self in [true, false]) {
      testWidgets('devMode 開（${self ? "自己" : "他人"}）：時間後顯示 #seq',
          (tester) async {
        await tester.pumpWidget(_wrap(MessageBubble(
            message: _msg(), isSelf: self, senderKind: 'codex', devMode: true)));
        expect(find.text('#42'), findsOneWidget);
      });
    }

    testWidgets('devMode 關：沒有 #seq', (tester) async {
      await tester.pumpWidget(_wrap(
          MessageBubble(message: _msg(), isSelf: false, senderKind: 'codex')));
      expect(find.text('#42'), findsNothing);
    });

    testWidgets('#seq 與時間之間有間距', (tester) async {
      for (final self in [true, false]) {
        await tester.pumpWidget(_wrap(MessageBubble(
            message: _msg(), isSelf: self, senderKind: 'codex', devMode: true)));
        final seq = tester.getRect(find.text('#42'));
        final time = tester.getRect(find.byWidgetPredicate(
            (w) => w is Text && RegExp(r'\d\d:\d\d$').hasMatch(w.data ?? '')));
        // 兩種排法都是「時間 → #seq」，中間不能貼在一起
        expect(seq.left - time.right, greaterThanOrEqualTo(6));
      }
    });

    testWidgets('點 #seq 複製 seq', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      await tester.pumpWidget(_wrap(MessageBubble(
          message: _msg(), isSelf: false, senderKind: 'codex', devMode: true)));
      await tester.tap(find.text('#42'));
      await tester.pump();
      expect(copied, '42');
    });

    for (final dev in [true, false]) {
      testWidgets('右鍵選單「複製訊息 ID」：devMode=$dev', (tester) async {
        String? copied;
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
        addTearDown(() => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null));

        await tester.pumpWidget(_wrap(MessageBubble(
            message: _msg(),
            isSelf: false,
            senderKind: 'codex',
            actions: _actions(),
            devMode: dev)));
        await tester.tap(find.text('哈囉'), buttons: kSecondaryButton);
        await tester.pumpAndSettle();

        if (!dev) {
          expect(find.text('複製訊息 ID'), findsNothing);
          return;
        }
        expect(find.text('複製訊息 ID'), findsOneWidget);
        await tester.tap(find.text('複製訊息 ID'));
        await tester.pumpAndSettle();
        expect(copied, 'msg-uuid-9');
      });
    }
  });
}
