import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/message.dart';
import 'package:chatroom_app/models/participant.dart';
import 'package:chatroom_app/widgets/mention_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 輸入框的鍵盤操作：@ 候選列表方向鍵選取 ＋ 上下鍵遍歷輸入歷史。
///
/// 兩個功能**搶同一組按鍵**，所以寫在同一份測試裡——分開驗的話，兩邊
/// 各自綠著，而使用者按下 ↑ 的時候只有一個會發生，另一個靜靜地不見了。
///
/// 仲裁規則（決策Novia 09/09 房 seq 29 釘選為驗收依據）：
/// 1. 候選列表開著 → ↑↓ 歸候選列表；關著 → 歸輸入歷史
/// 2. 多行輸入不搶游標：游標在第一行才吃 ↑、最後一行才吃 ↓，有選取不吃
/// 3. IME 組字中與編輯模式中都不走歷史
Participant _member(String name) => Participant(
      id: name,
      kind: 'claude',
      displayName: name,
      role: 'agent',
      status: 'active',
      joinedAt: '2026-09-09T00:00:00+00:00',
    );

void main() {
  late List<String> sent;
  late List<String> recorded;

  Widget wrap({
    String initial = '',
    List<String> history = const [],
    List<Participant> members = const [],
    Message? editTarget,
  }) =>
      MaterialApp(
        theme: buildUepTheme(Brightness.dark),
        home: Scaffold(
          body: MessageComposer(
            members: members,
            initialText: initial,
            history: history,
            editTarget: editTarget,
            onHistoryAdd: recorded.add,
            onSend: (text, _) async => sent.add(text),
          ),
        ),
      );

  setUp(() {
    sent = [];
    recorded = [];
  });

  Future<void> focusField(WidgetTester tester) async {
    await tester.tap(find.byType(TextField));
    await tester.pump();
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
  }

  String textOf(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  void setValue(WidgetTester tester, TextEditingValue value) {
    tester
        .state<EditableTextState>(find.byType(EditableText))
        .updateEditingValue(value);
  }

  group('輸入歷史', () {
    testWidgets('↑ 叫回上一則、再按一次回到更舊的', (tester) async {
      await tester.pumpWidget(wrap(history: const ['第一則', '第二則']));
      await focusField(tester);

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(textOf(tester), '第二則', reason: '第一下 ↑ 應該拿到最新的那則');

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(textOf(tester), '第一則');

      // 已經到最舊了，再按不應該跑掉
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(textOf(tester), '第一則');
    });

    testWidgets('↓ 回到底時放回進歷史前的草稿——不是清空', (tester) async {
      await tester.pumpWidget(wrap(initial: '打到一半', history: const ['舊的']));
      await focusField(tester);
      setValue(
          tester,
          const TextEditingValue(
            text: '打到一半',
            selection: TextSelection.collapsed(offset: 4),
          ));
      await tester.pump();

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(textOf(tester), '舊的');

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(textOf(tester), '打到一半',
          reason: '回到底要放回那句還沒說完的話，清空等於把它吃掉');
    });

    testWidgets('沒有歷史時 ↑ 不動輸入框', (tester) async {
      await tester.pumpWidget(wrap(initial: '草稿'));
      await focusField(tester);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(textOf(tester), '草稿');
    });

    testWidgets('不在歷史裡時 ↓ 不動輸入框', (tester) async {
      await tester.pumpWidget(wrap(initial: '草稿', history: const ['舊的']));
      await focusField(tester);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(textOf(tester), '草稿');
    });

    testWidgets('🔴 多行時游標不在第一行，↑ 不搶游標', (tester) async {
      await tester.pumpWidget(wrap(history: const ['舊的']));
      await focusField(tester);
      setValue(
          tester,
          const TextEditingValue(
            text: '第一行\n第二行',
            // 游標在第二行
            selection: TextSelection.collapsed(offset: 6),
          ));
      await tester.pump();

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(textOf(tester), '第一行\n第二行',
          reason: '六行的訊息如果連上下移動游標都做不到，這功能是在幫倒忙');
    });

    testWidgets('🔴 多行時游標不在最後一行，↓ 不搶游標', (tester) async {
      await tester.pumpWidget(wrap(history: const ['舊的']));
      await focusField(tester);
      setValue(
          tester,
          const TextEditingValue(
            text: '第一行\n第二行',
            selection: TextSelection.collapsed(offset: 1),
          ));
      await tester.pump();

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(textOf(tester), '第一行\n第二行');
    });

    testWidgets('🔴 有選取範圍時不吃方向鍵', (tester) async {
      await tester.pumpWidget(wrap(history: const ['舊的']));
      await focusField(tester);
      setValue(
          tester,
          const TextEditingValue(
            text: '選我',
            selection: TextSelection(baseOffset: 0, extentOffset: 2),
          ));
      await tester.pump();

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(textOf(tester), '選我');
    });

    testWidgets('🔴 IME 組字中的 ↑ 是在選字，不走歷史', (tester) async {
      await tester.pumpWidget(wrap(history: const ['舊的']));
      await focusField(tester);
      setValue(
          tester,
          const TextEditingValue(
            text: 'ㄨㄛˇ',
            selection: TextSelection.collapsed(offset: 3),
            composing: TextRange(start: 0, end: 3),
          ));
      await tester.pump();

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(textOf(tester), 'ㄨㄛˇ', reason: '組字中攔走 ↑ 會讓中文選不了候選字');
    });

    testWidgets('🔴 編輯模式不走歷史——那裡裝的是要換掉的那則', (tester) async {
      final target = Message(
        id: 'm1',
        seq: 7,
        updateSeq: 0,
        kind: 'chat',
        content: '原本的內容',
        createdAt: '2026-09-09T00:00:00+00:00',
      );
      // 真實情境是「先在打字，然後點了某則訊息的編輯」——editTarget 從
      // null 變成非 null，內容才會被填進輸入框（didUpdateWidget）
      await tester.pumpWidget(wrap(history: const ['舊的']));
      await tester.pumpWidget(wrap(history: const ['舊的'], editTarget: target));
      await tester.pump();
      await focusField(tester);

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(textOf(tester), '原本的內容',
          reason: '在編輯中的訊息上翻歷史，會把使用者正在改的東西換掉');
    });

    testWidgets('送出成功之後才記進歷史', (tester) async {
      await tester.pumpWidget(wrap(initial: '要送的話'));
      await focusField(tester);
      await press(tester, LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(sent, ['要送的話']);
      expect(recorded, ['要送的話']);
    });
  });

  group('@ 候選列表方向鍵', () {
    Future<void> openMenu(WidgetTester tester) async {
      await focusField(tester);
      setValue(
          tester,
          const TextEditingValue(
            text: '@',
            selection: TextSelection.collapsed(offset: 1),
          ));
      await tester.pump();
    }

    testWidgets('🔴 選單開著時 Enter 選的是高亮那一項，不是第一項', (tester) async {
      await tester.pumpWidget(wrap(members: [_member('Alpha'), _member('Beta')]));
      await openMenu(tester);

      // 群組（all / agents / humans）排在人名前面，先確認選單真的開著
      expect(find.text('Alpha'), findsOneWidget);

      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.enter);
      await tester.pump();

      expect(textOf(tester), isNot(startsWith('@all ')),
          reason: '↓ 移動過之後還選第一項，等於方向鍵沒有作用');
    });

    testWidgets('🔴 選單開著時 ↑↓ 歸選單，不去翻歷史', (tester) async {
      await tester.pumpWidget(wrap(
        history: const ['舊的'],
        members: [_member('Alpha')],
      ));
      await openMenu(tester);

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(textOf(tester), '@',
          reason: '選單開著時 ↑ 被歷史接走，輸入框會被舊訊息蓋掉');
    });

    testWidgets('Esc 收起選單，之後 ↑ 就歸歷史了', (tester) async {
      await tester.pumpWidget(wrap(
        history: const ['舊的'],
        members: [_member('Alpha')],
      ));
      await openMenu(tester);

      await press(tester, LogicalKeyboardKey.escape);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(textOf(tester), '舊的');
    });

    testWidgets('🔴 召回含 @ 的歷史不會彈出候選選單', (tester) async {
      await tester.pumpWidget(wrap(
        history: const ['@Alpha 幫我看一下'],
        members: [_member('Alpha')],
      ));
      await focusField(tester);

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(textOf(tester), '@Alpha 幫我看一下');

      // 選單若被彈出來，下一個 ↑ 會被它接走而不是繼續翻歷史
      expect(find.text('Alpha'), findsNothing,
          reason: '召回舊訊息不是打字，不該觸發補全選單');
    });
  });
}
