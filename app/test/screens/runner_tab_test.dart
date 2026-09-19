import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/host_kit.dart';
import 'package:chatroom_app/screens/host/host_console_screen.dart';
import 'package:chatroom_app/state/host_actions.dart';
import 'package:chatroom_app/state/host_kit_providers.dart';
import 'package:chatroom_app/state/host_probe.dart';
import 'package:chatroom_app/state/mcp_kit_providers.dart';
import 'package:chatroom_app/state/runner_kit_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/l10n.dart';

/// 「這台機器」頁的執行器分頁**何時出現**。
///
/// 沿用既有慣例：沒裝那包 → 入口**整個不存在**，不是變灰；只有一種 kit →
/// 不畫分頁列（一個只有一個分頁的分頁列是純粹的雜訊）。
void main() {
  const runnerKit = RunnerKit(
    kitDir: r'E:\Chatroom\Runner',
    configPath: r'E:\Chatroom\Runner\config.json',
  );

  final config = RunnerConfigFile(
    path: r'E:\Chatroom\Runner\config.json',
    raw: const {},
    projects: const [
      RunnerProject(
        key: 'chatroom',
        skillDirs: [r'C:\repos'],
        repos: {'Chatroom': r'C:\repos\Chatroom'},
        defaultRepo: 'Chatroom',
      ),
    ],
    modified: DateTime(2026, 9, 18),
  );

  Widget wrap({HostKit? host, McpKit? mcp, RunnerKit? runner}) => ProviderScope(
        overrides: [
          hostKitProvider.overrideWith((ref) async => host),
          hostEnvProvider.overrideWith((ref) async => null),
          hostHealthProvider.overrideWith((ref) async => null),
          tunnelStatusProvider.overrideWith(
              (ref) async => const TunnelStatus(ProbeState.unknown, '', '沒有')),
          serviceStatusProvider
              .overrideWith((ref) async => const ServiceStatus(false, '沒註冊')),
          mcpKitProvider.overrideWith((ref) async => mcp),
          mcpEnvProvider.overrideWith((ref) async => null),
          mcpStatusProvider.overrideWith((ref) async => null),
          runnerKitProvider.overrideWith((ref) async => runner),
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
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('🔴 沒裝執行器 → 連分頁標籤都不存在', (tester) async {
    sizeUp(tester);
    await tester.pumpWidget(wrap(
      host: const HostKit(kitRoot: r'C:\kit', envFile: r'C:\kit\.env'),
      mcp: const McpKit(kitRoot: r'C:\mcp', envFile: r'C:\mcp\.env'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('執行器'), findsNothing,
        reason: '一個永遠按不動的入口比沒有這個功能更糟');
    // 分頁標籤與那一頁的大標各一份
    expect(find.text('Hub 主持'), findsWidgets);
  });

  testWidgets('裝了執行器 → 多一個分頁，點得進去', (tester) async {
    sizeUp(tester);
    await tester.pumpWidget(wrap(
      host: const HostKit(kitRoot: r'C:\kit', envFile: r'C:\kit\.env'),
      mcp: const McpKit(kitRoot: r'C:\mcp', envFile: r'C:\mcp\.env'),
      runner: runnerKit,
    ));
    await tester.pumpAndSettle();

    expect(find.text('執行器'), findsOneWidget);
    await tester.tap(find.text('執行器'));
    await tester.pumpAndSettle();

    expect(find.text('公開給他人派工'), findsOneWidget);
    expect(find.text('允許瀏覽器實機測試'), findsOneWidget);
    expect(find.text('chatroom'), findsOneWidget);
  });

  testWidgets('🔴 只有執行器一種 kit → 不畫分頁列，直接顯示那一頁',
      (tester) async {
    sizeUp(tester);
    await tester.pumpWidget(wrap(runner: runnerKit));
    await tester.pumpAndSettle();

    expect(find.byType(TabBar), findsNothing,
        reason: '只有一個分頁的分頁列會讓人以為另一邊還有東西可看');
    expect(find.text('公開給他人派工'), findsOneWidget);
  });
}
