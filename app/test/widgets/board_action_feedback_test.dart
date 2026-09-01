import 'package:chatroom_app/core/errors/api_exception.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/screens/board/board_action_feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Board 按鈕的錯誤回饋。
///
/// 這份測試釘的是一個實際發生過的失效：board 的按鈕寫成
/// `onTap: () => actions.xxx()`，Hub 回 409 時例外被拋進 framework，
/// **畫面上什麼都不會發生**——使用者按了送審，沒有任何反應，也沒有任何
/// 地方報錯。四顆按鈕全部如此。
///
/// 所以要驗的不是「有沒有呼叫 API」，是**失敗時使用者看不看得見**。
void main() {
  /// 按一下就跑 [body] 的最小畫面。SnackBar 需要 Scaffold 才活得起來。
  Widget harness(Future<void> Function(BuildContext) body) => MaterialApp(
    theme: buildUepTheme(Brightness.dark),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => body(context),
          child: const Text('動作'),
        ),
      ),
    ),
  );

  testWidgets('動作失敗會告訴使用者，而不是安靜地什麼都不做', (tester) async {
    await tester.pumpWidget(harness(
      (context) => runBoardAction(
        context,
        () async => throw const ConflictException(
            'invalid_transition', '目前的狀態不允許這個動作',
            allowed: ['in_progress']),
      ),
    ));

    await tester.tap(find.text('動作'));
    await tester.pumpAndSettle();

    // Hub 的原話，不是我們自己編的一句：它知道為什麼被拒絕
    expect(find.text('目前的狀態不允許這個動作'), findsOneWidget);
  });

  testWidgets('409 交給 onConflict 時不出 SnackBar——那多半不是錯誤', (tester) async {
    ConflictException? seen;
    await tester.pumpWidget(harness(
      (context) => runBoardAction(
        context,
        () async => throw const ConflictException('task_already_claimed',
            '這張卡已經被 Swift-Falcon 領走了'),
        onConflict: (e) => seen = e,
      ),
    ));

    await tester.tap(find.text('動作'));
    await tester.pumpAndSettle();

    // 認領輸掉不該長成錯誤畫面，呼叫端要拿到的是「誰贏了」這個事實
    expect(seen?.code, 'task_already_claimed');
    expect(find.text('這張卡已經被 Swift-Falcon 領走了'), findsNothing);
  });

  testWidgets('成功時把結果原樣交回，不插手', (tester) async {
    String? got;
    await tester.pumpWidget(harness(
      (context) async =>
          got = await runBoardAction(context, () async => 'obj-1'),
    ));

    await tester.tap(find.text('動作'));
    await tester.pumpAndSettle();

    expect(got, 'obj-1');
    expect(find.byType(SnackBar), findsNothing);
  });
}
