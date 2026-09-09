import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/message.dart';
import 'package:chatroom_app/widgets/markdown_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// `#[標題]` 在訊息裡的呈現（契約 v1 第 3、4 條 — 09/09 房 seq 32）。
///
/// 兩層結構的分工：**快照**負責「這則訊息當時指的是哪一張」，**preview**
/// 負責「它現在怎麼了」。Hub 已經依 status 挑好該顯示哪一個標題，App 只是
/// 照著畫——兩邊各判一次的話，畫面上看不出是誰對。
void main() {
  CardRef ref({
    String title = '輸入歷史',
    String status = 'ok',
    String previewTitle = '輸入歷史（改過名字）',
  }) =>
      CardRef(
        boardId: 'b1',
        taskId: 't1',
        title: title,
        preview: CardRefPreview(status: status, title: previewTitle),
      );

  Widget wrap(String content, List<CardRef> refs,
          {void Function(CardRef)? onTap}) =>
      MaterialApp(
        theme: buildUepTheme(Brightness.dark),
        home: Scaffold(
          body: UepMarkdownBody(
            data: content,
            cardRefs: refs,
            onTapCard: onTap,
          ),
        ),
      );

  testWidgets('ok：顯示現況標題，不是發文當時那個', (tester) async {
    await tester.pumpWidget(wrap('看 #[輸入歷史] 這張', [ref()]));
    expect(find.text('輸入歷史（改過名字）'), findsOneWidget);
  });

  testWidgets('🔴 deleted：退回快照標題並標記——不是把指涉拿掉', (tester) async {
    await tester.pumpWidget(wrap(
      '看 #[輸入歷史] 這張',
      [ref(status: 'deleted', previewTitle: '輸入歷史')],
    ));
    // chip 是 Text.rich（標題 + 狀態標記），整段是「輸入歷史（已刪除）」
    expect(find.textContaining('輸入歷史'), findsOneWidget);
    expect(find.textContaining('已刪除'), findsOneWidget,
        reason: '把 ref 從訊息裡移除是無聲改寫歷史，比顯示「已刪除」糟');
  });

  testWidgets('moved 標記為已搬走', (tester) async {
    await tester.pumpWidget(wrap(
      '#[輸入歷史]',
      [ref(status: 'moved', previewTitle: '輸入歷史')],
    ));
    expect(find.textContaining('已搬走'), findsOneWidget);
  });

  testWidgets('no_access 標記為看不到', (tester) async {
    await tester.pumpWidget(wrap(
      '#[輸入歷史]',
      [ref(status: 'no_access', previewTitle: '輸入歷史')],
    ));
    expect(find.textContaining('看不到'), findsOneWidget);
  });

  testWidgets('🔴 沒有對應卡的 #[...] 只是普通文字', (tester) async {
    await tester.pumpWidget(wrap('#[買牛奶]', const []));
    expect(find.textContaining('#[買牛奶]'), findsOneWidget,
        reason: '畫成 chip 等於承諾一個點不開的連結');
  });

  group('點擊', () {
    testWidgets('ok 的 chip 點得動', (tester) async {
      CardRef? tapped;
      await tester.pumpWidget(
          wrap('#[輸入歷史]', [ref()], onTap: (r) => tapped = r));
      await tester.tap(find.text('輸入歷史（改過名字）'));
      await tester.pump();
      expect(tapped?.taskId, 't1');
    });

    testWidgets('🔴 deleted 的 chip 不給點——過去只會是一個空畫面',
        (tester) async {
      CardRef? tapped;
      await tester.pumpWidget(wrap(
        '#[輸入歷史]',
        [ref(status: 'deleted', previewTitle: '輸入歷史')],
        onTap: (r) => tapped = r,
      ));
      await tester.tap(find.textContaining('輸入歷史'));
      await tester.pump();
      expect(tapped, isNull);
    });

    testWidgets('no_access 的 chip 也不給點', (tester) async {
      CardRef? tapped;
      await tester.pumpWidget(wrap(
        '#[輸入歷史]',
        [ref(status: 'no_access', previewTitle: '輸入歷史')],
        onTap: (r) => tapped = r,
      ));
      await tester.tap(find.textContaining('輸入歷史'));
      await tester.pump();
      expect(tapped, isNull);
    });
  });

  group('cardRefPattern', () {
    test('🔴 前綴不會誤中——長的標題排前面', () {
      final pattern = RegExp(cardRefPattern([
        CardRef(
          boardId: 'b',
          taskId: 'short',
          title: '登入頁重構',
          preview: const CardRefPreview(),
        ),
        CardRef(
          boardId: 'b',
          taskId: 'long',
          title: '登入頁重構的問題',
          preview: const CardRefPreview(),
        ),
      ]));
      expect(pattern.stringMatch('#[登入頁重構的問題]'), '#[登入頁重構的問題]');
    });

    test('標題裡的正規表示式字元被逸出', () {
      final pattern = RegExp(cardRefPattern([
        CardRef(
          boardId: 'b',
          taskId: 't',
          title: 'a.b (c)',
          preview: const CardRefPreview(),
        ),
      ]));
      expect(pattern.hasMatch('#[a.b (c)]'), isTrue);
      expect(pattern.hasMatch('#[axb (c)]'), isFalse,
          reason: '沒逸出的話 `.` 會match任何字元');
    });
  });

  group('Message.fromJson', () {
    test('讀得出 card_refs 與 card_preview', () {
      final m = Message.fromJson({
        'id': 'm1',
        'seq': 1,
        'kind': 'chat',
        'content': '#[輸入歷史]',
        'created_at': '2026-09-09T00:00:00+00:00',
        'card_refs': [
          {
            'board_id': 'b1',
            'task_id': 't1',
            'title': '輸入歷史',
            'card_preview': {
              'status': 'ok',
              'title': '輸入歷史',
              'task_status': 'done',
              'checklist_id': 'c1',
            },
          },
        ],
      });
      expect(m.cardRefs.single.taskId, 't1');
      expect(m.cardRefs.single.preview.taskStatus, 'done');
    });

    test('🔴 舊版 Hub 不回這個欄位時是空清單，不是炸掉', () {
      final m = Message.fromJson({
        'id': 'm1',
        'seq': 1,
        'kind': 'chat',
        'content': '#[輸入歷史]',
        'created_at': '2026-09-09T00:00:00+00:00',
      });
      expect(m.cardRefs, isEmpty,
          reason: '那時內文裡的 #[標題] 只是普通文字，這是正確的降級');
    });
  });
}
