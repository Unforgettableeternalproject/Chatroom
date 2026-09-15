import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/participant.dart';
import 'package:chatroom_app/widgets/composer_attachments.dart';
import 'package:chatroom_app/widgets/mention_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ComposerAttachment _att({
  String id = 'a1',
  ComposerAttachmentStatus status = ComposerAttachmentStatus.ready,
  String filename = 'shot.png',
  String? remoteId = 'remote-1',
}) =>
    ComposerAttachment(
      localId: id,
      filename: filename,
      mime: 'image/png',
      size: 2048,
      remoteId: status == ComposerAttachmentStatus.ready ? remoteId : null,
      status: status,
    );

Widget _host({
  required List<ComposerAttachment> attachments,
  required Future<void> Function(String, List<String>) onSend,
}) =>
    MaterialApp(
      theme: buildUepTheme(Brightness.dark),
      home: Scaffold(
        body: MessageComposer(
          members: const <Participant>[],
          attachments: attachments,
          onPickFiles: () {},
          onSend: onSend,
        ),
      ),
    );

void main() {
  group('待送附件與送出條件', () {
    testWidgets('附件還在上傳時不可送出——只帶已就緒的 id 等於默默丟掉那個檔',
        (tester) async {
      var sent = 0;
      await tester.pumpWidget(_host(
        attachments: [_att(status: ComposerAttachmentStatus.uploading)],
        onSend: (_, _) async => sent++,
      ));
      await tester.enterText(find.byType(TextField), '看這個');
      await tester.pump();

      await tester.tap(find.text('送出 →'));
      await tester.pump();
      expect(sent, 0);
    });

    testWidgets('上傳失敗的項目同樣擋住送出（要嘛重試、要嘛移除）', (tester) async {
      var sent = 0;
      await tester.pumpWidget(_host(
        attachments: [_att(status: ComposerAttachmentStatus.failed)],
        onSend: (_, _) async => sent++,
      ));
      await tester.enterText(find.byType(TextField), '看這個');
      await tester.pump();

      await tester.tap(find.text('送出 →'));
      await tester.pump();
      expect(sent, 0);
    });

    testWidgets('沒有文字但有附件時可以送出，內容自動用檔名補'
        '（Hub 的 content 是 min_length=1）', (tester) async {
      String? content;
      await tester.pumpWidget(_host(
        attachments: [_att()],
        onSend: (c, _) async => content = c,
      ));

      await tester.tap(find.text('送出 →'));
      await tester.pump();
      expect(content, contains('shot.png'));
    });

    testWidgets('多個附件時的預設說明帶出數量', (tester) async {
      String? content;
      await tester.pumpWidget(_host(
        attachments: [_att(), _att(id: 'a2', filename: 'log.txt')],
        onSend: (c, _) async => content = c,
      ));

      await tester.tap(find.text('送出 →'));
      await tester.pump();
      expect(content, contains('2 個'));
    });

    testWidgets('沒有文字也沒有附件時不可送出', (tester) async {
      var sent = 0;
      await tester.pumpWidget(_host(
        attachments: const [],
        onSend: (_, _) async => sent++,
      ));

      await tester.tap(find.text('送出 →'));
      await tester.pump();
      expect(sent, 0);
    });

    testWidgets('失敗的附件會顯示錯誤與重試鈕', (tester) async {
      var retried = 0;
      final failed = ComposerAttachment(
        localId: 'a1',
        filename: 'big.zip',
        mime: 'application/zip',
        size: 99,
        status: ComposerAttachmentStatus.failed,
        error: '檔案超過上限 25 MB',
      );
      await tester.pumpWidget(MaterialApp(
        theme: buildUepTheme(Brightness.dark),
        home: Scaffold(
          body: ComposerAttachmentBar(
            attachments: [failed],
            onRemove: (_) {},
            onRetry: (_) => retried++,
          ),
        ),
      ));

      expect(find.text('檔案超過上限 25 MB'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.refresh));
      expect(retried, 1);
    });
  });
}
