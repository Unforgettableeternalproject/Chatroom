import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/attachment.dart';
import 'package:chatroom_app/widgets/attachment_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _image = Attachment(
  id: 'a1',
  filename: 'shot.png',
  mime: 'image/png',
  size: 336,
  isImage: true,
);

const _file = Attachment(
  id: 'a2',
  filename: 'run.log',
  mime: 'text/plain',
  size: 900,
  isImage: false,
);

Widget _host({String? participantId, List<Attachment> attachments = const []}) =>
    // ProviderScope：下載鈕要讀 attachmentsApiProvider
    ProviderScope(
        child: MaterialApp(
      theme: buildUepTheme(Brightness.dark),
      home: Scaffold(
        body: AttachmentView(
          attachments: attachments,
          serverUrl: 'http://hub.test',
          token: 'tok',
          participantId: participantId,
        ),
      ),
    ));

void main() {
  group('圖片附件在身分就緒前不得發出請求', () {
    testWidgets('沒有房內身分時畫佔位，不建立 Image', (tester) async {
      // 身分是 join 完成後才有的，而訊息可能更早就畫出來。那個空窗期發出的
      // 請求會被 Hub 以 401 擋下，而 NetworkImage 的相等性只看 url 與 scale、
      // 不含 headers——失敗結果會被沿用，身分到齊也不會自己重試。使用者
      // 看到的就是「永遠只有檔名」（2026-08-29 實機發現）。
      await tester.pumpWidget(_host(attachments: const [_image]));

      expect(find.byType(Image), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('空字串身分等同沒有身分', (tester) async {
      await tester.pumpWidget(
          _host(participantId: '', attachments: const [_image]));

      expect(find.byType(Image), findsNothing);
    });

    testWidgets('有身分時才真的去抓圖', (tester) async {
      await tester.pumpWidget(
          _host(participantId: 'p1', attachments: const [_image]));

      expect(find.byType(Image), findsOneWidget);
    });
  });

  group('非圖片附件', () {
    testWidgets('沒有身分也照樣顯示檔案資訊——它本來就不抓內容', (tester) async {
      await tester.pumpWidget(_host(attachments: const [_file]));

      expect(find.text('run.log'), findsOneWidget);
    });
  });

  group('存到本機', () {
    testWidgets('圖片與非圖片都有存檔鈕——兩者都是使用者要拿走的東西',
        (tester) async {
      await tester.pumpWidget(
          _host(participantId: 'p1', attachments: const [_image, _file]));

      expect(find.byIcon(Icons.download_outlined), findsNWidgets(2));
    });

    testWidgets('身分還沒到時存檔鈕仍在，但按下去只提示、不發請求',
        (tester) async {
      // 鈕直接消失的話，畫面會在身分到齊的瞬間跳一下；而且使用者會以為
      // 這個附件「不能下載」，那是錯的——它只是還沒準備好
      await tester.pumpWidget(_host(attachments: const [_file]));

      expect(find.byIcon(Icons.download_outlined), findsOneWidget);
      await tester.tap(find.byIcon(Icons.download_outlined));
      await tester.pump();

      expect(find.textContaining('房間身分'), findsOneWidget);
    });
  });

  testWidgets('沒有附件時完全不佔版面', (tester) async {
    await tester.pumpWidget(_host(participantId: 'p1'));

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(Image), findsNothing);
  });
}
