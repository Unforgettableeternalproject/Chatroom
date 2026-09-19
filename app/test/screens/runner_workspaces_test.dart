import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/screens/host/host_console_screen.dart';
import 'package:chatroom_app/state/host_actions.dart';
import 'package:chatroom_app/state/host_kit_providers.dart';
import 'package:chatroom_app/state/host_probe.dart';
import 'package:chatroom_app/state/kit_installer.dart';
import 'package:chatroom_app/state/mcp_kit_providers.dart';
import 'package:chatroom_app/state/runner_kit_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/l10n.dart';

/// 執行器分頁的「工作區／專案」兩層畫面。
///
/// 這裡只驗**畫面講了什麼、哪些動作要先確認**——寫檔那一半在資料層
/// （`runner_workspaces.dart`）自己的測試裡，那邊有真的檔案可以改。
void main() {
  const runnerKit = RunnerKit(
    kitDir: r'E:\Chatroom\Runner',
    configPath: r'E:\Chatroom\Runner\config.json',
  );

  final config = RunnerConfigFile(
    path: r'E:\Chatroom\Runner\config.json',
    raw: const {},
    workspaces: const [
      RunnerWorkspace(
        key: 'chatroom',
        folder: r'C:\repos',
        skillDirs: [r'C:\repos'],
        // 掃不到的 skill：檔案裡寫著它，畫面就不該讓它無聲消失
        primarySkill: 'pm',
        projects: {
          'Chatroom': RunnerProject(path: r'C:\repos\Chatroom'),
          'UEP': RunnerProject(path: r'C:\repos\UEP'),
        },
        defaultProject: 'Chatroom',
      ),
    ],
    modified: DateTime(2026, 9, 18),
  );

  Widget wrap() => ProviderScope(
        overrides: [
          kitInstallSupportedProvider.overrideWithValue(false),
          kitReleaseProvider.overrideWith((ref) async => null),
          kitPythonProvider.overrideWith((ref) async => null),
          runnerBusyProvider.overrideWith((ref) async => false),
          hostKitProvider.overrideWith((ref) async => null),
          hostEnvProvider.overrideWith((ref) async => null),
          hostHealthProvider.overrideWith((ref) async => null),
          tunnelStatusProvider.overrideWith(
              (ref) async => const TunnelStatus(ProbeState.unknown, '', '沒有')),
          serviceStatusProvider
              .overrideWith((ref) async => const ServiceStatus(false, '沒註冊')),
          mcpKitProvider.overrideWith((ref) async => null),
          mcpEnvProvider.overrideWith((ref) async => null),
          mcpStatusProvider.overrideWith((ref) async => null),
          runnerKitProvider.overrideWith((ref) async => runnerKit),
          runnerConfigProvider.overrideWith((ref) async => config),
          runnerIdProvider.overrideWith((ref) async => null),
        ],
        child: MaterialApp(
          locale: kTestLocale,
          localizationsDelegates: kTestLocalizationsDelegates,
          supportedLocales: kTestSupportedLocales,
          theme: buildUepTheme(Brightness.dark),
          home: const HostConsoleScreen(),
        ),
      );

  void sizeUp(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// 卡片預設收合，內容要點開標題列才在。
  Future<void> expand(WidgetTester tester) async {
    await tester.tap(find.text('chatroom'));
    await tester.pumpAndSettle();
  }

  testWidgets('工作區卡：收合時只剩標題列，展開才有專案、預設標記與加減入口',
      (tester) async {
    sizeUp(tester);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    // 收合：標題列（key、資料夾、公開狀態）在，底下那一層不在
    expect(find.text('新增工作區'), findsOneWidget);
    expect(find.text('chatroom'), findsOneWidget);
    expect(find.text(r'C:\repos'), findsWidgets);
    expect(find.text('公開'), findsOneWidget);
    expect(find.text('加專案'), findsNothing);

    await expand(tester);

    expect(find.text('Chatroom'), findsOneWidget);
    expect(find.text(r'C:\repos\Chatroom'), findsOneWidget);
    expect(find.text('UEP'), findsOneWidget);
    expect(find.text(r'C:\repos\UEP'), findsOneWidget);
    // 預設的那一張掛「預設」標記，且不給「設為預設」，非預設的才有
    expect(find.text('預設'), findsOneWidget);
    expect(find.text('設為預設'), findsOneWidget);
    expect(find.text('加專案'), findsOneWidget);
    expect(find.text('優先載入 skill'), findsOneWidget);
  });

  testWidgets('🔴 掃不到的優先載入 skill 仍留在下拉裡，不無聲消失',
      (tester) async {
    sizeUp(tester);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    await expand(tester);

    expect(find.text('pm'), findsOneWidget,
        reason: '檔案裡寫著 pm，畫面卻看不到的話，存檔就會把它洗掉');
  });

  testWidgets('🔴 移除工作區要先確認；取消就什麼都沒發生', (tester) async {
    sizeUp(tester);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    // 移除搬進標題列的溢位選單
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除工作區'));
    await tester.pumpAndSettle();

    expect(find.text('要移除工作區「chatroom」嗎？'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('要移除工作區「chatroom」嗎？'), findsNothing);
    expect(find.text('chatroom'), findsOneWidget);
  });

  testWidgets('新增工作區：名稱與資料夾都填了才按得下去', (tester) async {
    sizeUp(tester);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.text('新增工作區'));
    await tester.pumpAndSettle();

    expect(find.text('工作區名稱'), findsOneWidget);
    expect(find.text('第一個專案路徑'), findsOneWidget);

    final add = find.widgetWithText(TextButton, '加入');
    expect(tester.widget<TextButton>(add).onPressed, isNull,
        reason: '空白的表單按下去只會得到一句錯誤訊息');

    await tester.enterText(
        find.widgetWithText(TextField, '工作區名稱'), 'demo');
    await tester.enterText(find.widgetWithText(TextField, '資料夾'), r'C:\demo');
    await tester.pumpAndSettle();

    expect(tester.widget<TextButton>(add).onPressed, isNotNull);
  });
}
