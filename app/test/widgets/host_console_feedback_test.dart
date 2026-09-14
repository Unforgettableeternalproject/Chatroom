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
  _SeededOp(this.seeds);

  /// 每種操作各自一格（key = kind）。**收多筆**——跨區同時有事在跑是
  /// 這組測試要守的情境之一，單筆的 harness 表達不出來。
  final List<Map<String, dynamic>> seeds;

  @override
  Map<String, Map<String, dynamic>> build() => {
        for (var i = 0; i < seeds.length; i++)
          '${seeds[i]['kind']}': {...seeds[i], '_seq': i + 1},
      };
}

void main() {
  Widget wrap(Map<String, dynamic>? op, {List<Map<String, dynamic>>? ops}) =>
      ProviderScope(
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
          lastDataOpProvider.overrideWith(
              () => _SeededOp(ops ?? (op == null ? const [] : [op]))),
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

  group('一格一種操作：跨區的動作不能把還在跑的那個蓋掉', () {
    testWidgets('🔴 啟動輪詢中去按備份，啟動那格不能消失', (tester) async {
      tester.view.physicalSize = const Size(760, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // 單格的時候：backup 會把 hub_start 整筆換掉 ⇒ 啟動區讀到 null ⇒
      // 按鈕從「啟動中…」變回「啟動 Hub」⇒ 再按一次就啟第二個 Hub 進程。
      // 那比沒有回饋更糟——沒有回饋時至少沒有人以為可以再按
      await tester.pumpWidget(wrap(null, ops: [
        {'kind': 'hub_start', 'pending': true},
        {'kind': 'backup', 'ok': true, 'path': r'C:\kits\backups\x.zip'},
      ]));
      await tester.pumpAndSettle();

      expect(find.text('啟動中…'), findsOneWidget,
          reason: '按鈕復活就代表可以再按一次，而那會啟第二個 Hub');
      expect(find.text('啟動 Hub'), findsNothing);
      expect(find.textContaining('正在啟動'), findsOneWidget);
      // 兩區各畫各的，互不影響
      expect(find.textContaining('backups'), findsOneWidget);
    });

    testWidgets('同一區有多筆時顯示最近那一筆', (tester) async {
      tester.view.physicalSize = const Size(760, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrap(null, ops: [
        {'kind': 'hub_start', 'ok': true, 'detail': '舊的那筆'},
        {'kind': 'hub_stop', 'ok': true, 'detail': '新的那筆'},
      ]));
      await tester.pumpAndSettle();

      expect(find.text('新的那筆'), findsOneWidget);
      expect(find.text('舊的那筆'), findsNothing);
    });
  });

  group('按鈕只看自己那一格', () {
    testWidgets('🔴 啟動輪詢中按了停止，啟動鈕不能復活', (tester) async {
      tester.view.physicalSize = const Size(760, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // 同一區、hub_stop 比較新。用「這一區最新一筆」判 pending 的話，
      // 啟動鈕會看到 hub_stop（沒有 pending）而變回可按 —— 再按一次
      // 就是第二個 Hub 進程（審核用Codex 09/14）
      await tester.pumpWidget(wrap(null, ops: [
        {'kind': 'hub_start', 'pending': true},
        {'kind': 'hub_stop', 'ok': true, 'detail': '已送出停止指令。'},
      ]));
      await tester.pumpAndSettle();

      expect(find.text('啟動中…'), findsOneWidget);
      expect(find.text('啟動 Hub'), findsNothing);
      // 顯示的是這一區最近那一筆（停止的結果）——那是另一個問題，不衝突
      expect(find.text('已送出停止指令。'), findsOneWidget);
    });
  });
}
