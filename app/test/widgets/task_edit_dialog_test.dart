import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/screens/board/board_task_edit_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 改一張卡的標題與敘述（艾斯維爾 09/08）。
///
/// 這份測試守的是**「沒改」與「清空」不可以送成同一個東西**：
/// `_board_patch` 只跳過 null，空字串是一個真的值會把敘述清掉。只改標題的
/// 人因此會發現敘述不見了，而且沒有任何地方報錯。
Future<TaskEdit?> _open(
  WidgetTester tester, {
  String title = '原標題',
  String description = '原敘述',
}) async {
  TaskEdit? result;
  var opened = false;
  await tester.pumpWidget(MaterialApp(
    theme: buildUepTheme(Brightness.dark),
    home: Scaffold(
      body: Builder(builder: (context) {
        if (!opened) {
          opened = true;
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            result = await showTaskEditDialog(context,
                title: title, description: description);
          });
        }
        return const SizedBox.shrink();
      }),
    ),
  ));
  await tester.pumpAndSettle();
  return result;
}

Future<TaskEdit?> _submitAfter(
  WidgetTester tester,
  Future<void> Function() edit, {
  String title = '原標題',
  String description = '原敘述',
}) async {
  TaskEdit? result;
  var opened = false;
  await tester.pumpWidget(MaterialApp(
    theme: buildUepTheme(Brightness.dark),
    home: Scaffold(
      body: Builder(builder: (context) {
        if (!opened) {
          opened = true;
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            result = await showTaskEditDialog(context,
                title: title, description: description);
          });
        }
        return const SizedBox.shrink();
      }),
    ),
  ));
  await tester.pumpAndSettle();
  await edit();
  await tester.tap(find.text('儲存'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('兩個欄位都帶著現在的值進來——編輯不是重打一次', (tester) async {
    await _open(tester);

    expect(find.text('原標題'), findsOneWidget);
    expect(find.text('原敘述'), findsOneWidget);
  });

  testWidgets('🔴 只改標題時，敘述回 null 而不是空字串', (tester) async {
    // 回空字串的話 Hub 會把敘述**清掉**——`_board_patch` 只跳過 null。
    final r = await _submitAfter(tester, () async {
      await tester.enterText(find.byType(TextField).first, '新標題');
    });

    expect(r, isNotNull);
    expect(r!.title, '新標題');
    expect(r.description, isNull, reason: '沒動它就不要送它');
  });

  testWidgets('清空敘述是使用者真的做了那件事——要送空字串', (tester) async {
    final r = await _submitAfter(tester, () async {
      await tester.enterText(find.byType(TextField).last, '');
    });

    expect(r!.description, '', reason: '空字串是「清空」，與 null 不同');
    expect(r.title, isNull);
  });

  testWidgets('什麼都沒改就是沒改，不送一次空的 PATCH', (tester) async {
    final r = await _submitAfter(tester, () async {});

    expect(r!.isEmpty, isTrue);
  });

  testWidgets('標題不能清空——說出理由，不要靜靜地不改', (tester) async {
    // Hub 收到空標題會 `if body.title else None` 靜靜跳過，畫面上看起來
    // 像壞掉。擋在這裡是為了讓拒絕看起來像它自己
    await _open(tester);
    await tester.enterText(find.byType(TextField).first, '   ');
    await tester.tap(find.text('儲存'));
    await tester.pumpAndSettle();

    expect(find.text('標題不能是空的'), findsOneWidget);
    // 對話框沒有關掉——錯誤要看得到才有用
    expect(find.text('編輯任務卡'), findsOneWidget);
  });
}
