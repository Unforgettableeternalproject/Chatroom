import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/screens/ops/dispatch_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/l10n.dart';

/// 房間綁定工作區之後，派工對話框的**專案不是一個選擇**。
///
/// Hub 對別的 key 一律 409 `workspace_project_mismatch`——選得到而送不出去
/// 比不給選更糟：人會以為自己選錯了什麼，而其實那個房間只有一個答案。
/// 停用的下拉也不行，那看起來仍然是一個選擇。
/// 送出去的那一筆。對話框自己不打 API，所以這裡收的就是呼叫端會拿到的東西。
final _submitted = <DispatchRequest>[];

Future<void> _open(
  WidgetTester tester, {
  String? workspaceKey,
  List<String> projects = const ['ai-website', 'uep'],
}) async {
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: kTestLocalizationsDelegates,
    supportedLocales: kTestSupportedLocales,
    theme: buildUepTheme(Brightness.dark),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            final r = await showDispatchDialog(context,
                targetLabel: '卡：修掉登入頁的 500',
                workspaceKey: workspaceKey,
                projects: Future.value(DispatchProjects(projects: projects)));
            if (r != null) _submitted.add(r);
          },
          child: const Text('開'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('開'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(_submitted.clear);

  testWidgets('綁定的房間：專案是唯讀的一列，沒有下拉', (tester) async {
    await _open(tester, workspaceKey: 'ai-website');

    expect(find.text('ai-website'), findsOneWidget);
    expect(find.text('已綁定，不可更改'), findsOneWidget);
    // 優先度是 DropdownButton<int>，專案那顆整個不見了
    expect(find.byType(DropdownButton<String>), findsNothing);
    expect(find.text('uep'), findsNothing);
  });

  testWidgets('送出去的 project 就是綁定的那個 key，而且不必先選', (tester) async {
    await _open(tester, workspaceKey: 'ai-website');
    await tester.tap(find.text('送出'));
    await tester.pumpAndSettle();

    expect(_submitted, hasLength(1));
    expect(_submitted.single.project, 'ai-website');
  });

  testWidgets('沒綁定的房間照舊給選——這次改的是綁定之後那條路', (tester) async {
    await _open(tester);

    expect(find.text('已綁定，不可更改'), findsNothing);
    expect(find.byType(DropdownButton<String>), findsOneWidget);
    expect(find.text('選一個專案'), findsWidgets);
  });
}
