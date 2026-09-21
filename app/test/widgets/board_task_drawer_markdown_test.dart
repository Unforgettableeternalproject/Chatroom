import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/screens/board/board_task_drawer.dart';
import 'package:chatroom_app/widgets/markdown_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/l10n.dart';

/// 🔴 卡片內文是 agent 寫的，慣例上就是 markdown。抽屜原本用 `Text` 渲染，
/// 於是 `## 票`、`**粗體**`、`- ` 清單全部原樣印在畫面上——讀起來像貼錯了
/// 一段原始碼，而那正是這張卡最需要被讀懂的部分。
const _description = '## 票\n\n**重點**在這裡\n\n- 第一項\n- 第二項\n\n`code`';

BoardTask _task() => BoardTask.fromJson({
      'id': 't1',
      'checklist_id': 'c1',
      'title': '一張卡',
      'status': 'todo',
      'description': _description,
    });

Widget _wrap(Widget child, Brightness brightness) => ProviderScope(
      child: MaterialApp(
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: kTestSupportedLocales,
        theme: buildUepTheme(brightness),
        home: Scaffold(body: child),
      ),
    );

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('🔴 內文走 markdown 渲染，不把記號原樣印出來（$brightness）',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BoardTaskDrawer(
          roomId: null,
          boardId: 'b1',
          task: _task(),
          checklistTitle: '階段',
          onClose: () {},
        ),
        brightness,
      ));
      expect(tester.takeException(), isNull);
      // 沿用聊天泡泡那一個 widget——樣式、連結行為與主題都跟著它走
      expect(find.byType(UepMarkdownBody), findsOneWidget);
      // 整段原文出現在畫面上，就代表它又是純文字了
      expect(find.text(_description), findsNothing);
    });
  }
}
