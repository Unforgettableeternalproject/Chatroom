import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/agent_run.dart';
import 'package:chatroom_app/screens/ops/dispatch_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 派工對話框：**人類不寫自由 prompt**（REMOTE-OPS-PLAN §6.2）。
///
/// 這份測試守的是「選出來的東西送得出去、送不出去時說得出為什麼」：
/// 專案沒選就不讓送（Hub 會以 `project_not_served` 退，而那句話出現在送出
/// 之後就太晚了），簡述超長要當場講。
Future<DispatchRequest?> _open(
  WidgetTester tester, {
  List<String> projects = const ['ai-website'],
}) async {
  DispatchRequest? result;
  await tester.pumpWidget(MaterialApp(
    theme: buildUepTheme(Brightness.dark),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await showDispatchDialog(context,
                targetLabel: '卡：修掉登入頁的 500', projects: projects);
          },
          child: const Text('開'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('開'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('目標寫在上面——選完模板最容易忘的是自己在哪張卡按的',
      (tester) async {
    await _open(tester);
    expect(find.text('目標：卡：修掉登入頁的 500'), findsOneWidget);
  });

  testWidgets('三個模板各帶一句說明', (tester) async {
    await _open(tester);
    for (final t in kRunTemplates) {
      expect(find.text(t.label), findsOneWidget);
      expect(find.text(t.summary), findsOneWidget);
    }
    // push 不是給人選的模板：它是儀表板按鈕組出來的固定形狀
    expect(kRunTemplates.map((t) => t.kind), isNot(contains('push')));
  });

  testWidgets('只有一個專案時預設選好——不讓人為了一個沒有選擇的選擇按一次',
      (tester) async {
    await _open(tester);
    await tester.tap(find.text('送出'));
    await tester.pumpAndSettle();
    expect(find.text('請先選一個專案'), findsNothing);
  });

  testWidgets('🔴 多個專案時不預設：選錯專案會被 Hub 退，而那時人已經走開了',
      (tester) async {
    await _open(tester, projects: const ['ai-website', 'other']);
    await tester.tap(find.text('送出'));
    await tester.pumpAndSettle();
    expect(find.text('請先選一個專案'), findsOneWidget);
  });

  testWidgets('沒有執行器宣告專案：送出停用，並說出下一步在哪',
      (tester) async {
    await _open(tester, projects: const []);
    expect(find.textContaining('沒有執行器宣告任何專案'), findsOneWidget);
    // 停用要說出理由，而理由要能導向下一步——這一條的下一步在那台機器上
    expect(find.textContaining('projects 白名單'), findsOneWidget);
  });

  testWidgets('簡述有計數，超過上限當場擋下', (tester) async {
    await _open(tester);
    expect(find.text('0 / $kRunBriefMaxLength'), findsOneWidget);
    await tester.enterText(
        find.byType(TextField), 'x' * (kRunBriefMaxLength + 1));
    await tester.pumpAndSettle();
    expect(find.text('${kRunBriefMaxLength + 1} / $kRunBriefMaxLength'),
        findsOneWidget);
    await tester.tap(find.text('送出'));
    await tester.pumpAndSettle();
    expect(find.textContaining('簡述超過'), findsOneWidget);
  });

  testWidgets('填完之後把選擇交回呼叫端——對話框自己不送出', (tester) async {
    DispatchRequest? result;
    await tester.pumpWidget(MaterialApp(
      theme: buildUepTheme(Brightness.dark),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDispatchDialog(context,
                  targetLabel: '階段：登入流程',
                  projects: const ['ai-website']);
            },
            child: const Text('開'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('開'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(kRunTemplates[1].label));
    await tester.enterText(find.byType(TextField), '讀 JSAI-123 那張票');
    await tester.pumpAndSettle();
    await tester.tap(find.text('送出'));
    await tester.pumpAndSettle();
    expect(result?.kind, kRunTemplates[1].kind);
    expect(result?.project, 'ai-website');
    expect(result?.brief, '讀 JSAI-123 那張票');
    expect(result?.priority, 0);
  });

  testWidgets('取消回 null，不留一筆半成品', (tester) async {
    DispatchRequest? result;
    var done = false;
    await tester.pumpWidget(MaterialApp(
      theme: buildUepTheme(Brightness.dark),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDispatchDialog(context,
                  targetLabel: '卡：x', projects: const ['ai-website']);
              done = true;
            },
            child: const Text('開'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('開'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(done, isTrue);
    expect(result, isNull);
  });
}
