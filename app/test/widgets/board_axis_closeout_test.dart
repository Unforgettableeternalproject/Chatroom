import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/screens/board/board_screen.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 🔴 2026-09-07（Bernie 想法板 e86dd552）：**從 Board 分頁進板看不到
/// 「＋ 階段」與「送審」**，從聊天室進去則正常。
///
/// 成因是收尾那一組動作外面掛著 `if (!_boardOnly)`——那是 09/03 留下的
/// 遺物：當時板軸真的沒有 `_actions`（一律唯讀），畫出來會在 build 期
/// `_actions!` 炸開。後來板軸拿到了自己的身分（`BoardActions.forBoard`，
/// 走 session key），`_closeoutActions` 自己也改成先取值再判 null，
/// **但外面那道守衛沒有跟著拆**。
///
/// ⚠️ 這種殘留特別難查：畫面沒有錯誤、沒有灰屏、沒有停用的按鈕，
/// 那一整組操作就是**不存在**——而「這塊板不能送審」與「這條路徑不畫
/// 送審」在畫面上長得一模一樣。
BoardSnapshot _snap() => const BoardSnapshot().merge(BoardDelta.fromJson({
      'board_seq': 10,
      'full': true,
      'board_id': 'b1',
      'my_role': 'editor',
      'objectives': [
        {'id': 'o1', 'title': '09/07 週期', 'status': 'active'},
      ],
      'checklists': [
        {'id': 'c1', 'objective_id': 'o1', 'title': '階段', 'status': 'done'},
      ],
      'tasks': [
        {'id': 't1', 'checklist_id': 'c1', 'title': '卡', 'status': 'done'},
      ],
    }));

Widget _wrap(Widget child, {required BoardSnapshot snap, String? boardId}) =>
    ProviderScope(
      overrides: [
        if (boardId != null)
          boardByIdProvider(boardId).overrideWith((ref) async => snap),
      ],
      child: MaterialApp(
        theme: buildUepTheme(Brightness.dark),
        home: child,
      ),
    );

void main() {
  testWidgets('🔴 板軸（從 Board 分頁進來）也要畫得出「＋ 階段」與「送審」',
      (tester) async {
    await tester.pumpWidget(
        _wrap(const BoardScreen(boardId: 'b1'), snap: _snap(), boardId: 'b1'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // 兩顆一起驗：它們是同一組收尾動作，少的時候是整組一起少
    expect(find.text('＋ 階段'), findsOneWidget);
    expect(find.text('送審'), findsOneWidget);
  });
}
