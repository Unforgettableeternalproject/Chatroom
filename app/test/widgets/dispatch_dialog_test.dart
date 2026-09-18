import 'dart:async';

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
  Future<DispatchProjects>? projectsFuture,
  // 載入中的轉圈會一直動，`pumpAndSettle` 等不到安靜
  bool settle = true,
}) async {
  DispatchRequest? result;
  await tester.pumpWidget(MaterialApp(
    theme: buildUepTheme(Brightness.dark),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await showDispatchDialog(context,
                targetLabel: '卡：修掉登入頁的 500',
                projects: projectsFuture ??
                    Future.value(DispatchProjects(projects: projects)));
          },
          child: const Text('開'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('開'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }
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

  testWidgets('沒有執行器宣告專案：說出下一步在哪', (tester) async {
    await _open(tester, projects: const []);
    expect(find.textContaining('沒有執行器宣告任何專案'), findsOneWidget);
  });

  testWidgets('🔴 沒有專案時按送出：不能只是不動，要當場說為什麼',
      (tester) async {
    // 09/17 實機：執行器剛好被判離線 → 清單空 → 送出鍵停用 → 按下去完全
    // 沒有反應、Hub 沒收到 POST、App log 也沒有一行。使用者只知道「第一次
    // 沒反應」
    final result = await _open(tester, projects: const []);
    await tester.tap(find.text('送出'));
    await tester.pumpAndSettle();
    expect(find.textContaining('沒有可派工的專案'), findsOneWidget);
    expect(result, isNull);
  });

  testWidgets('🔴 清單還在載入：顯示載入中，按送出要說「等一下」而不是沉默',
      (tester) async {
    final gate = Completer<DispatchProjects>();
    await _open(tester, projectsFuture: gate.future, settle: false);
    expect(find.text('專案清單載入中…'), findsOneWidget);
    await tester.tap(find.text('送出'));
    await tester.pump();
    expect(find.textContaining('專案清單還在載入'), findsOneWidget);

    // 載到之後：唯一的專案自動選好，同一個按鍵就送得出去
    gate.complete(const DispatchProjects(projects: ['ai-website']));
    await tester.pumpAndSettle();
    expect(find.text('專案清單載入中…'), findsNothing);
    await tester.tap(find.text('送出'));
    await tester.pumpAndSettle();
    expect(find.byType(DispatchDialog), findsNothing);
  });

  testWidgets('🔴 清單撈不到：把 Hub 的話講出來，不是開一個空的下拉',
      (tester) async {
    await _open(tester,
        projectsFuture:
            Future.value(const DispatchProjects(error: '無法連線到 Hub')));
    expect(find.text('無法連線到 Hub'), findsOneWidget);
    await tester.tap(find.text('送出'));
    await tester.pumpAndSettle();
    // 錯誤欄與表單各一份：按下去之後那句話要出現在看得到的地方
    expect(find.text('無法連線到 Hub'), findsNWidgets(2));
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
                  projects: Future.value(
                      const DispatchProjects(projects: ['ai-website'])));
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
                  targetLabel: '卡：x',
                  projects: Future.value(
                      const DispatchProjects(projects: ['ai-website'])));
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
