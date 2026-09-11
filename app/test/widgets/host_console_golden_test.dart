@Tags(['golden'])
library;

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

/// 主機控制台的驗收圖。
///
/// 刻意畫**混合狀態**而不是全綠：三盞燈裡有一盞 `unknown`、隧道也是
/// `unknown`——那才看得出「不確定」與「壞掉」在畫面上真的分得開，
/// 而那是這一頁最關鍵的一個設計決定（`docs/KIT-UI-DESIGN-BRIEF.md` §5）。
///
/// ⚠️ 與 `focus_pulse_golden_test` 同一個性質：它會跟著一般 `flutter test`
/// 跑，而 golden 對字型與平台敏感。紅的時候先分辨——版面真的改了，
/// 還是只是環境變了（後者用 `--update-goldens` 重產）。
void main() {
  testWidgets('主機控制台：好／壞／不確定三種狀態並存', (tester) async {
    // 高度要容得下整頁：新增「資料與安全」那一區之後，1900 會把它
    // 推到畫面外——ListView 不會 overflow，所以那種漏拍**不會報錯**，
    // 只是驗收圖裡默默少了一塊
    tester.view.physicalSize = const Size(760, 2250);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        hostKitProvider.overrideWith((ref) async => const HostKit(
              kitRoot: r'C:\kits\chatroom-host-kit',
              envFile: r'C:\kits\chatroom-host-kit\server\.env',
              installedHost: '26.176.231.43',
              installedPort: '8787',
            )),
        // 畫**憑證分離**的狀態：那是安裝器現在的預設，也是「發給成員」
        // 那一區唯一會出現兩把鑰匙的樣子。legacy（只有一把）是過渡狀態，
        // 新裝的 Hub 不會長那樣
        hostEnvProvider.overrideWith((ref) async => const HostEnv(
              host: '26.176.231.43',
              port: '8787',
              token: 'demo-agent-token-not-real',
              humanToken: 'demo-human-token-not-real',
            )),
        hostHealthProvider.overrideWith((ref) async => const HostHealth(
              process: Probe(ProbeState.ok, 'Hub 正在這台機器上跑'),
              reachable: Probe(ProbeState.ok, '綁定位址打得通',
                  caveat: '這只證明本機打得到；別台機器還要防火牆放行與網路可達'),
              auth: Probe(ProbeState.bad, 'server/.env 裡的 token 不被接受',
                  caveat: 'Hub 可能還跑著舊的那份——改完 .env 要重啟才生效'),
            )),
        tunnelStatusProvider.overrideWith((ref) async => const TunnelStatus(
              ProbeState.unknown,
              'https://demo-example.trycloudflare.com',
              '有網址，但從這台機器打不通',
              caveat: '兩種可能，本機分不出來：①隧道其實活著，只是這台機器繞不回自己的'
                  '公網網址（很常見）②隧道已經關了、這個檔案是殘留的。'
                  '請成員或手機開一次那個網址',
            )),
        serviceStatusProvider.overrideWith((ref) async => const ServiceStatus(
              true,
              '狀態：Ready　上次執行：2026/9/9 上午 10:12:00（結果 0）\n'
              'Hub 進程：PID 24680',
            )),
        hostActionsProvider.overrideWith(
            (ref) => const HostActions(r'C:\kits\chatroom-host-kit')),
        // 同一台機器同時是主持人與成員——多半就是這樣，所以圖要涵蓋兩塊
        mcpKitProvider.overrideWith((ref) async => const McpKit(
              kitRoot: r'C:\kits\chatroom-mcp-kit',
              envFile: r'C:\kits\chatroom-mcp-kit\.env',
              installedAt: '2026-09-09T06:30:00+00:00',
              targets: ['claude', 'codex'],
            )),
        mcpEnvProvider.overrideWith((ref) async =>
            const McpEnv(url: 'http://26.176.231.43:8787', token: 'demo')),
        mcpBridgeVersionProvider
            .overrideWith((ref) async => '1.2.1+c123507f9c6f'),
        mcpStatusProvider.overrideWith((ref) async => const McpStatus(
              reach: Probe(ProbeState.ok, 'Hub 連得到'),
              auth: Probe(ProbeState.ok, 'token 可以通過認證'),
              bridgeVersion: '1.2.1+c123507f9c6f',
            )),
      ],
      child: MaterialApp(
        theme: buildUepTheme(Brightness.dark),
        home: const HostConsoleScreen(),
      ),
    ));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/host_console.png'),
    );
  });
}
