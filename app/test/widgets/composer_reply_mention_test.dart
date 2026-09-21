import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/message.dart';
import 'package:chatroom_app/models/participant.dart';
import 'package:chatroom_app/widgets/mention_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/l10n.dart';

/// 輸入列底下那行「會 tag 到誰」要**把回覆帶的那個人算進去**。
///
/// 🔴 回覆會 mention 被回覆的人，而那是 **Hub** 做的
/// （`server/chatroom_server/app.py` 的 `_insert_message`）。App 這邊的預覽
/// 原本只算內文裡打出來的 `@`，於是回覆送出去會多叫醒一個畫面上沒說的人
/// ——而預覽存在的全部理由就是「送出前知道會叫到誰」（艾斯維爾 09/15）。
///
/// 少報比多報嚴重：多列一個名字使用者看得見、可以取消；少列的那個**仍然
/// 會被通知**，而畫面說了沒有。
void main() {
  const me = 'p-me';

  Message from(String? senderId, String? senderName) => Message(
        id: 'm1',
        seq: 7,
        updateSeq: 7,
        kind: senderId == null ? 'system' : 'chat',
        content: '前次登入資訊的前端顯示做完了',
        createdAt: '2026-09-15T00:00:00+00:00',
        senderId: senderId,
        senderName: senderName,
      );

  Widget wrap({Message? replyTarget, String? selfId = me}) => MaterialApp(
    localizationsDelegates: kTestLocalizationsDelegates,
    supportedLocales: kTestSupportedLocales,
        theme: buildUepTheme(Brightness.dark),
        home: Scaffold(
          body: MessageComposer(
            members: const [
              Participant(
                id: 'p-other',
                kind: 'human',
                displayName: 'Bernie',
                role: 'human',
                status: 'active',
                joinedAt: '2026-09-15T00:00:00+00:00',
              ),
            ],
            replyTarget: replyTarget,
            selfParticipantId: selfId,
            onSend: (_, _) async {},
          ),
        ),
      );

  Future<void> type(WidgetTester tester, String text) async {
    await tester.tap(find.byType(TextField));
    await tester.pump();
    tester
        .state<EditableTextState>(find.byType(EditableText))
        .updateEditingValue(TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        ));
    await tester.pump();
  }

  testWidgets('🔴 回覆別人：一個字都沒打，也要說得出會 tag 到他', (tester) async {
    await tester.pumpWidget(wrap(replyTarget: from('p-other', 'Bernie')));
    await tester.pump();

    expect(find.textContaining('會 tag 到：Bernie'), findsOneWidget,
        reason: 'Hub 會把被回覆者補進 mentions，送出前就該看得到');
    expect(find.textContaining('（回覆）'), findsOneWidget,
        reason: '這個名字不是使用者打的，要看得出它從哪來——'
            '不然他會找不到自己在哪裡 @ 了這個人');
  });

  testWidgets('🔴 自己回自己：不列任何人', (tester) async {
    await tester.pumpWidget(wrap(replyTarget: from(me, '我自己')));
    await tester.pump();

    expect(find.textContaining('會 tag 到'), findsNothing,
        reason: 'Hub 那邊同樣跳過自己回自己——那只會把自己叫醒一次');
    expect(find.textContaining('ENTER 送出'), findsOneWidget,
        reason: '沒有人要 tag 時，這一行回到原本的快捷鍵提示');
  });

  testWidgets('🔴 內文已經 @ 過他：不重複，也不加「（回覆）」', (tester) async {
    await tester.pumpWidget(wrap(replyTarget: from('p-other', 'Bernie')));
    await type(tester, '@Bernie 收到');

    final line = tester
        .widgetList<Text>(find.textContaining('會 tag 到'))
        .map((t) => t.data ?? '')
        .join();
    expect('Bernie'.allMatches(line).length, 1,
        reason: 'Hub 那邊的條件是 `name not in effective`——同一個人只算一次');
    expect(line, isNot(contains('（回覆）')),
        reason: '他是使用者自己打的，標成「回覆」會誤導');
  });

  testWidgets('回覆系統訊息：沒有作者可以 tag', (tester) async {
    await tester.pumpWidget(wrap(replyTarget: from(null, null)));
    await tester.pump();

    expect(find.textContaining('會 tag 到'), findsNothing,
        reason: '系統訊息的 sender_id 是 NULL，Hub 那邊的 '
            '`target["sender_id"] and ...` 會直接跳過');
  });

  testWidgets('拿不到自己的身分時寧可多列', (tester) async {
    await tester.pumpWidget(
        wrap(replyTarget: from('p-other', 'Bernie'), selfId: null));
    await tester.pump();

    expect(find.textContaining('會 tag 到：Bernie'), findsOneWidget,
        reason: 'identity 還沒回來時不能靜靜少列一個——'
            '少列的那個仍然會被通知');
  });
}
