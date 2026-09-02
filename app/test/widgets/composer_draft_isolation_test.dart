import 'package:chatroom_app/models/participant.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/widgets/mention_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 草稿的第二層：輸入列與外層草稿倉之間那條線（艾斯維爾 2026-09-02）。
///
/// 第一層（`ValueKey(roomId)` 讓 State 隨房重建）在 `app.dart`，倉本身在
/// `composer_drafts_test.dart`。**這支測中間那段**：進場載得到、打字存得回去。
///
/// ⚠️ 為什麼三支分開：兩層缺一不可，而少了任一層的症狀不同——少了 key，
/// 字跟著跑到別的房；少了倉，字在切房時直接消失。合成一支的話，紅燈分不出
/// 是哪一層壞了。
Widget _host({
  required String initialText,
  required ValueChanged<String> onTextChanged,
  Key? key,
}) =>
    ProviderScope(
      child: MaterialApp(
        theme: buildUepTheme(Brightness.dark),
        home: Scaffold(
          body: MessageComposer(
            key: key,
            members: const <Participant>[],
            initialText: initialText,
            onTextChanged: onTextChanged,
            onSend: (_, _) async {},
          ),
        ),
      ),
    );

void main() {
  testWidgets('進場時輸入框帶著這個房間上次沒說完的話', (tester) async {
    await tester.pumpWidget(_host(initialText: '沒說完的話', onTextChanged: (_) {}));
    expect(find.text('沒說完的話'), findsOneWidget);
  });

  testWidgets('打字會回報給外層存起來', (tester) async {
    final seen = <String>[];
    await tester.pumpWidget(_host(initialText: '', onTextChanged: seen.add));
    await tester.enterText(find.byType(TextField), '打到一半');
    expect(seen.last, '打到一半');
  });

  testWidgets('外層之後改變 initialText 不會蓋掉正在打的字', (tester) async {
    // 只在 initState 讀一次的理由：拿外面的值再蓋回去會推走游標、吃掉組字。
    // 換房間靠的是 ValueKey 換一顆 State，不是靠改這個參數
    final seen = <String>[];
    await tester.pumpWidget(_host(
        key: const ValueKey('same'), initialText: '舊的', onTextChanged: seen.add));
    await tester.enterText(find.byType(TextField), '我正在打');
    await tester.pumpWidget(_host(
        key: const ValueKey('same'),
        initialText: '別的房的字',
        onTextChanged: seen.add));
    expect(find.text('我正在打'), findsOneWidget);
    expect(find.text('別的房的字'), findsNothing);
  });

  testWidgets('換一把 key 就是新的一顆 State，字不會留下來', (tester) async {
    // 這是 app.dart 那個 ValueKey(roomId) 在做的事的最小模型
    final seen = <String>[];
    await tester.pumpWidget(_host(
        key: const ValueKey('room-a'), initialText: '', onTextChanged: seen.add));
    await tester.enterText(find.byType(TextField), 'A 房的字');
    await tester.pumpWidget(_host(
        key: const ValueKey('room-b'), initialText: '', onTextChanged: seen.add));
    expect(find.text('A 房的字'), findsNothing,
        reason: 'key 換了 State 卻沒重建，字就會跟著跑到另一個房間');
  });
}
