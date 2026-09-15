import 'package:chatroom_app/core/diagnostics/input_diagnostics.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/participant.dart';
import 'package:chatroom_app/widgets/mention_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 輸入卡死的診斷儀器（卡 `7d3db264` 第一階段）。
///
/// 這組測試釘的**不是**「儀器抓到了什麼」——它抓不到任何東西，它只是記錄。
/// 釘的是三件會讓這份 log 變成廢物的事：
///
/// 1. **關掉時要真的不做事**（它會進正式 build）
/// 2. **不記使用者打的字**——那是他正在說的話，而且對這個症狀沒有用。
///    少了這條約束，這份 log 會變成一個沒有人敢交出來的東西
/// 3. **組字狀態的轉折要被記到**（進入／離開），那是這份儀器的主訊號
Widget _wrap(Widget child) => MaterialApp(
      theme: buildUepTheme(Brightness.dark),
      home: Scaffold(body: child),
    );

Participant _member(String name) => Participant.fromJson({
      'id': 'p-$name',
      'display_name': name,
      'kind': 'human',
      'status': 'active',
      'role': 'human',
    });

void main() {
  tearDown(() => InputDiagnostics.instance.enabled = true);

  testWidgets('關掉時每個呼叫點都是 no-op——它會進正式 build', (tester) async {
    InputDiagnostics.instance.enabled = false;
    // 關著時不開檔、不寫任何東西。這裡驗的是「不炸」與「沒有落點」
    InputDiagnostics.instance.focus(hasFocus: true, hasPrimary: true);
    InputDiagnostics.instance.lifecycle('resumed');
    InputDiagnostics.instance.badge(3, before: true);
    expect(InputDiagnostics.instance.path, isNull);
  });

  testWidgets('🔴 組字的進入與離開都要被記到——那是這份儀器的主訊號',
      (tester) async {
    final seen = <Map<String, Object?>>[];
    await tester.pumpWidget(_wrap(MessageComposer(
      members: [_member('Bernie')],
      onSend: (_, _) async {},
      onDiagnostic: (kind, data) => seen.add({'kind': kind, ...data}),
    )));

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    // 進入組字：注音打到一半，composing 範圍有效
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: 'ㄉㄞ',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 2),
    ));
    await tester.pump();

    // 離開組字：選了字，composing 收掉
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: '待',
      selection: TextSelection.collapsed(offset: 1),
    ));
    await tester.pump();

    final composing =
        seen.where((e) => e['kind'] == 'composing').toList();
    expect(composing, hasLength(2), reason: '一進一出，兩筆');
    expect(composing.first['active'], isTrue);
    expect(composing.last['active'], isFalse);
  });

  testWidgets('🔴 不記使用者打的字，只記形狀', (tester) async {
    final seen = <Map<String, Object?>>[];
    await tester.pumpWidget(_wrap(MessageComposer(
      members: [_member('Bernie')],
      onSend: (_, _) async {},
      onDiagnostic: (kind, data) => seen.add({'kind': kind, ...data}),
    )));

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    const secret = '這是一句不該進 log 的話';
    tester.testTextInput.updateEditingValue(TextEditingValue(
      text: secret,
      selection: TextSelection.collapsed(offset: secret.length),
      composing: TextRange(start: secret.length - 1, end: secret.length),
    ));
    await tester.pump();

    final flat = seen.map((e) => e.values.join(' ')).join(' ');
    expect(flat, isNot(contains('不該進 log')));
    // 形狀要在：長度與行數是時序分析要用的
    final composing = seen.firstWhere((e) => e['kind'] == 'composing');
    expect(composing['len'], secret.length);
    expect(composing['lines'], 1);
  });

  testWidgets('焦點的兩個旗標都記——「焦點在但打不出字」只有它們分得出來',
      (tester) async {
    final seen = <Map<String, Object?>>[];
    await tester.pumpWidget(_wrap(MessageComposer(
      members: [_member('Bernie')],
      onSend: (_, _) async {},
      onDiagnostic: (kind, data) => seen.add({'kind': kind, ...data}),
    )));

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    final focus = seen.where((e) => e['kind'] == 'focus').toList();
    expect(focus, isNotEmpty);
    expect(focus.last.containsKey('has'), isTrue);
    expect(focus.last.containsKey('primary'), isTrue,
        reason: '只記 hasFocus 的話，那個怪狀態在 log 上看起來完全正常');
  });
}
