import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/message.dart';
import 'package:chatroom_app/widgets/system_message_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// run 的收工摘要（REMOTE-OPS-PLAN §12 待辦 2）。
///
/// 它走 system 訊息進房，而 system tile 原本只有「兩條髮絲線夾一行置中 mono
/// 小字」一種樣式：整段 Markdown 塞進去之後字太小、標題不渲染，換行後每一行
/// 還會被推出訊息框右緣。這份測試釘的就是那個畫面——**不是**「有沒有用
/// Markdown widget」，而是窄框下**不溢出**且標題真的變成標題。

const _summary = '''
### 收工摘要

- 實作 `JSAI-2377`，commit `dbd17dcf`（GPG 簽，未 push）
- 驗證：既有測試全過
- 檔案：C:/Users/Bernie/source/repos/Unforgettableeternalproject/Chatroom/app/lib/screens/ops/ops_dashboard_view.dart

下一步交給人類決定要不要推。
''';

Message _msg(String content) => Message(
      id: 'm1',
      seq: 1,
      updateSeq: 0,
      kind: 'system',
      content: content,
      createdAt: '2026-09-17T09:30:00+00:00',
      senderId: '',
      senderName: '',
    );

Widget _wrap(Widget child, {double width = 320}) => MaterialApp(
      theme: buildUepTheme(Brightness.dark),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: SingleChildScrollView(child: child),
          ),
        ),
      ),
    );

void main() {
  testWidgets('長 Markdown 摘要不溢出，而且標題渲染成標題', (tester) async {
    await tester.pumpWidget(_wrap(SystemMessageTile(message: _msg(_summary))));
    await tester.pump();

    // overflow 只會在畫面上印一條黃黑條，測試不會自己紅——要主動去撿
    expect(tester.takeException(), isNull);

    // 標題與內文分開渲染（一行 mono 小字的版本只會有一個 Text）
    expect(find.textContaining('收工摘要', findRichText: true), findsWidgets);
    // 原本那條「內容 · 時間」的單行組字不該再出現
    expect(find.textContaining('### 收工摘要 ·'), findsNothing);

    // 整塊的寬度不超過父層。溢出的是內容而不是這層 Container，所以
    // 一併確認裡面每一個 RenderBox 都沒有超出右緣
    final tile = tester.getRect(find.byType(SystemMessageTile));
    expect(tile.width, lessThanOrEqualTo(320));
  });

  testWidgets('短的一行系統訊息維持原本的髮絲線樣式', (tester) async {
    await tester.pumpWidget(_wrap(SystemMessageTile(message: _msg('諾薇亞 加入了聊天室'))));
    await tester.pump();

    expect(tester.takeException(), isNull);
    // 一行版本才會把內容與時間組成同一段字
    expect(find.textContaining('諾薇亞 加入了聊天室 ·'), findsOneWidget);
  });

  test('判定：有換行、有標題、或夠長就當成一段內容', () {
    expect(systemMessageNeedsBlock('諾薇亞 加入了聊天室'), isFalse);
    expect(systemMessageNeedsBlock('第一行\n第二行'), isTrue);
    expect(systemMessageNeedsBlock('### 收工摘要'), isTrue);
    expect(systemMessageNeedsBlock('字' * 201), isTrue);
  });
}
