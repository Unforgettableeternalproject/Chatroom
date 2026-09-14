import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/host_kit.dart';
import 'package:chatroom_app/screens/host/host_console_screen.dart';
import 'package:chatroom_app/state/host_actions.dart';
import 'package:chatroom_app/state/host_kit_providers.dart';
import 'package:chatroom_app/state/host_probe.dart';
import 'package:chatroom_app/state/mcp_kit_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 按了按鈕要知道發生了什麼（艾斯維爾 09/14：「不確定按鈕按了是否有正常運作」）。
///
/// 這一組守的是兩件事，而它們是分開的：
/// 1. **有記錄結果**——09/12 已經為「停止」那半做了
/// 2. **結果出現在按鈕旁邊**——沒做。在這之前所有結果都只畫在頁尾的
///    「資料與安全」區塊裡，按「停止 Hub」的人得往下捲過兩個區塊去找
///
/// 只做第 1 件的話，測試看起來也會綠（`lastDataOpProvider` 確實有值），
/// 而使用者仍然看不到。所以這裡驗的是**畫面上的位置**。
class _SeededOp extends LastDataOp {
  _SeededOp(this.seed);

  final Map<String, dynamic>? seed;

  @override
  Map<String, dynamic>? build() => seed;
}

void main() {
  Widget wrap(Map<String, dynamic>? op) => ProviderScope(
        overrides: [
          hostKitProvider.overrideWith((ref) async => const HostKit(
                kitRoot: r'C:\kits\chatroom-host-kit',
                envFile: r'C:\kits\chatroom-host-kit\server\.env',
                installedHost: '127.0.0.1',
                installedPort: '8787',
              )),
          hostEnvProvider.overrideWith((ref) async => const HostEnv(
                host: '127.0.0.1',
                port: '8787',
                token: 'demo-agent-token-not-real',
                humanToken: 'demo-human-token-not-real',
              )),
          hostHealthProvider.overrideWith((ref) async => const HostHealth(
                process: Probe(ProbeState.ok, 'Hub 正在這台機器上跑'),
                reachable: Probe(ProbeState.ok, '綁定位址打得通'),
                auth: Probe(ProbeState.ok, 'token 可以通過認證'),
              )),
          tunnelStatusProvider.overrideWith((ref) async =>
              const TunnelStatus(ProbeState.unknown, '', '沒有開著的隧道')),
          serviceStatusProvider
              .overrideWith((ref) async => const ServiceStatus(false, '沒註冊')),
          hostActionsProvider.overrideWith(
              (ref) => const HostActions(r'C:\kits\chatroom-host-kit')),
          mcpKitProvider.overrideWith((ref) async => null),
          lastDataOpProvider.overrideWith(() => _SeededOp(op)),
        ],
        child: MaterialApp(
          theme: buildUepTheme(Brightness.dark),
          home: const HostConsoleScreen(),
        ),
      );

  group('進行中要看得出來', () {
    testWidgets('🔴 啟動 Hub 進行中：按鈕改字 + 講一句正在做什麼', (tester) async {
      tester.view.physicalSize = const Size(760, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrap({'kind': 'hub_start', 'pending': true}));
      await tester.pumpAndSettle();

      expect(find.text('啟動中…'), findsOneWidget);
      expect(find.text('啟動 Hub'), findsNothing,
          reason: '同一顆按鈕換字，不是多長一顆出來');
      expect(find.textContaining('正在啟動'), findsOneWidget);
    });

    testWidgets('🔴 開隧道進行中：講出「要跟 Cloudflare 要網址」這件事',
        (tester) async {
      tester.view.physicalSize = const Size(760, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrap({'kind': 'tunnel_start', 'pending': true}));
      await tester.pumpAndSettle();

      expect(find.text('開通中…'), findsOneWidget);
      // 這幾秒不講清楚，人會再按一次——而每按一次就多一條隧道
      expect(find.textContaining('Cloudflare'), findsOneWidget);
    });
  });

  group('結果要出現在按鈕旁邊，不是頁尾', () {
    testWidgets('🔴 本次修的：啟動結果畫在「啟動與自啟」區，不在「資料與安全」',
        (tester) async {
      tester.view.physicalSize = const Size(760, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrap({
        'kind': 'hub_start',
        'ok': true,
        'detail': 'Hub 起來了。',
      }));
      await tester.pumpAndSettle();

      // 只出現一次——出現兩次表示頁尾那份沒有被排除，使用者會以為
      // 剛剛那個動作發生了兩遍
      expect(find.text('Hub 起來了。'), findsOneWidget);

      final result = tester.getTopLeft(find.text('Hub 起來了。')).dy;
      final controlTitle = tester.getTopLeft(find.text('啟動與自啟')).dy;
      final dataTitle = tester.getTopLeft(find.text('資料與安全')).dy;
      expect(result, greaterThan(controlTitle));
      expect(result, lessThan(dataTitle),
          reason: '結果落在「資料與安全」標題之後＝它畫在別人的框裡');
    });

    testWidgets('資料類的結果仍然留在「資料與安全」區', (tester) async {
      tester.view.physicalSize = const Size(760, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrap({
        'kind': 'backup',
        'ok': true,
        'path': r'C:\kits\chatroom-host-kit\backups\2026-09-14.zip',
      }));
      await tester.pumpAndSettle();

      final dataTitle = tester.getTopLeft(find.text('資料與安全')).dy;
      final result = tester.getTopLeft(find.textContaining('backups')).dy;
      expect(result, greaterThan(dataTitle));
    });
  });
}
