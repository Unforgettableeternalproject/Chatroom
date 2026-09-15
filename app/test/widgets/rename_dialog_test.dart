import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/widgets/rename_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 改名對話框（c271c7ff）：房間與板共用同一份規則。
///
/// 這裡釘的是**它回傳什麼**——呼叫端拿那個值去打 API，所以「取消」與
/// 「沒改」都必須回 null：回一個與現值相同的字串，Hub 照樣會在房裡留下
/// 一則「X 將房間改名為 Y」的系統訊息，而什麼都沒變。
/// 開啟對話框，回傳一個**收集回傳值的清單**——關閉之後裡面才會有東西。
///
/// 用清單而不是單一變數，是為了分得出「回了 null」與「還沒回」：
/// 兩者在一個 `String?` 上長得一模一樣，而這組測試有一半在驗前者。
Future<List<String?>> _open(WidgetTester tester,
    {String current = '舊名字'}) async {
  final got = <String?>[];
  await tester.pumpWidget(MaterialApp(
    theme: buildUepTheme(Brightness.dark),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async => got.add(await showRenameDialog(context,
              title: '房間改名', current: current)),
          child: const Text('開'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('開'));
  await tester.pumpAndSettle();
  return got;
}

void main() {
  testWidgets('改成新名字 → 回傳修剪後的字串', (tester) async {
    final got = await _open(tester);
    await tester.enterText(find.byType(TextField), '  新名字  ');
    await tester.tap(find.text('改名'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(got, ['新名字']);
  });

  testWidgets('空白名字不送出，並說出為什麼', (tester) async {
    final got = await _open(tester);
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('改名'));
    await tester.pumpAndSettle();

    // 對話框留著——關掉的話那句錯誤訊息也跟著消失，等於沒說
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('名字不能是空的'), findsOneWidget);
    expect(got, isEmpty, reason: '還沒關閉，不該有任何回傳值');
  });

  testWidgets('名字沒改就當取消——不送一次「改成同一個名字」', (tester) async {
    final got = await _open(tester, current: '舊名字');
    await tester.tap(find.text('改名'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    // 關掉了，而且**沒有值可送**——呼叫端據此不打 API
    expect(got, [null]);
  });

  testWidgets('開始打字就把錯誤收掉——舊的錯誤訊息不該留在新輸入旁邊',
      (tester) async {
    await _open(tester);
    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.text('改名'));
    await tester.pumpAndSettle();
    expect(find.text('名字不能是空的'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '新');
    await tester.pumpAndSettle();
    expect(find.text('名字不能是空的'), findsNothing);
  });
}
