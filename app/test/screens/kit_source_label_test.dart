import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/host_kit.dart';
import 'package:chatroom_app/screens/host/host_console_screen.dart';
import 'package:chatroom_app/state/host_kit_providers.dart';
import 'package:chatroom_app/state/host_probe.dart';
import 'package:chatroom_app/state/kit_installer.dart';
import 'package:chatroom_app/state/mcp_kit_providers.dart';
import 'package:chatroom_app/state/runner_kit_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/l10n.dart';

/// 分頁上要講清楚**這些東西是怎麼找到的**。
///
/// 安裝包與本機來源能做的事一樣，但出問題時要找的地方完全不同——
/// 升級安裝包救不了「偵測到你 repo 裡那份」的那一種。
void main() {
  testWidgets('本機來源：兩個分頁都標明來源，執行器還講得出版本', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(overrides: [
      // 這一題問的是「來源標示」，不是安裝入口：關掉安裝分頁，畫面就是
      // 加這個功能之前的兩分頁樣子。**也擋住真網路**——kitReleaseProvider
      // 沒有覆寫的話，這支測試會去打 GitHub
      kitInstallSupportedProvider.overrideWithValue(false),
      kitReleaseProvider.overrideWith((ref) async => null),
      kitPythonProvider.overrideWith((ref) async => null),
      hostKitProvider.overrideWith((ref) async => null),
      hostEnvProvider.overrideWith((ref) async => null),
      hostHealthProvider.overrideWith((ref) async => null),
      mcpKitProvider.overrideWith((ref) async => const McpKit(
          kitRoot: r'C:\repo', envFile: r'C:\repo\server\.env',
          source: KitSource.local, bridgeDir: r'C:\repo\bridge')),
      mcpEnvProvider.overrideWith((ref) async => null),
      mcpStatusProvider.overrideWith((ref) async => null),
      mcpBridgeVersionProvider.overrideWith((ref) async => '1.2.3+abc'),
      runnerKitProvider.overrideWith((ref) async => const RunnerKit(
          kitDir: r'E:\Runner', configPath: r'C:\cfg.json',
          source: KitSource.local)),
      runnerConfigProvider.overrideWith((ref) async => null),
      runnerVersionProvider.overrideWith((ref) async => '1.2.3+325617dd34b5'),
      runnerIdProvider.overrideWith((ref) async => null),
    ], child: MaterialApp(
      locale: kTestLocale,
      localizationsDelegates: kTestLocalizationsDelegates,
      supportedLocales: kTestSupportedLocales,
      theme: buildUepTheme(Brightness.dark),
      home: const HostConsoleScreen(),
    )));
    await tester.pumpAndSettle();
    expect(find.text('來源：本機來源'), findsOneWidget);
    await tester.tap(find.text('執行器').first);
    await tester.pumpAndSettle();
    expect(find.text('來源：本機來源'), findsOneWidget);
    expect(find.text('執行器版本 1.2.3+325617dd34b5'), findsOneWidget);
  });
}
