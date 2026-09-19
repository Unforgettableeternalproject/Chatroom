import 'dart:io';

import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/core/util/env_file.dart';
import 'package:chatroom_app/models/host_kit.dart';
import 'package:chatroom_app/screens/host/env_settings_section.dart';
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

/// 「這台機器」頁改 `.env`。
///
/// 三件事要分開驗：**檔案有沒有被正確改到**（只動那一行，別人的註解還在）、
/// **存完之後說了什麼**（Hub 要重啟進程才生效，agent 那邊是下次連線才生效，
/// 混在一起的話照著做的人會去重啟一個不必重啟的東西），以及**哪些東西不准
/// 在這裡改**——位址、埠號與 token 改錯的代價是所有成員同時斷線，它們在這
/// 一頁上只能看。
void main() {
  late Directory dir;
  late File envFile;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('host_env_edit');
    envFile = File('${dir.path}${Platform.pathSeparator}.env');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Widget wrap({HostKit? host, McpKit? mcp, HostEnv? env}) => ProviderScope(
        overrides: [
          kitInstallSupportedProvider.overrideWithValue(false),
          kitReleaseProvider.overrideWith((ref) async => null),
          kitPythonProvider.overrideWith((ref) async => null),
          runnerBusyProvider.overrideWith((ref) async => false),
          hostKitProvider.overrideWith((ref) async => host),
          // 🔴 讀檔那一步在這裡是**同步**做掉的：`flutter_test` 的假時間裡
          // 真的檔案 I/O 不會完成，讓 provider 自己去讀會永遠停在「檢查中」。
          // provider 對真檔案的讀取另外在 `test/state/env_raw_test.dart` 驗。
          // 寫檔那一步是這支測試的題目，所以按鈕要在 `runAsync` 裡按。
          hostEnvRawProvider.overrideWith((ref) async =>
              host == null ? null : parseEnvText(envFile.readAsStringSync())),
          mcpEnvRawProvider.overrideWith((ref) async =>
              mcp == null ? null : parseEnvText(envFile.readAsStringSync())),
          hostEnvProvider.overrideWith((ref) async => env),
          hostHealthProvider.overrideWith((ref) async => null),
          tunnelStatusProvider.overrideWith(
              (ref) async => const TunnelStatus(ProbeState.unknown, '', '沒有')),
          serviceStatusProvider
              .overrideWith((ref) async => const ServiceStatus(false, '沒註冊')),
          mcpKitProvider.overrideWith((ref) async => mcp),
          mcpEnvProvider.overrideWith((ref) async => null),
          mcpStatusProvider.overrideWith((ref) async => null),
          mcpBridgeVersionProvider.overrideWith((ref) async => ''),
          runnerKitProvider.overrideWith((ref) async => null),
          runnerConfigProvider.overrideWith((ref) async => null),
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

  /// 表單在 `ListView` 的下半段，視窗要夠高才建得出來。
  void sizeUp(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// 欄位用 key 認：標籤現在是人話（「每日派工配額」），變數名只在 tooltip。
  Finder field(String key) => find.byKey(Key('env-field-$key'));

  Future<void> typeInto(WidgetTester tester, String key, String value) async {
    await tester.enterText(field(key), value);
    await tester.pump();
  }

  /// 存檔要走到真的檔案，那是真的 I/O——假時間裡它不會完成。
  Future<void> tapSave(WidgetTester tester, [Finder? button]) async {
    await tester.runAsync(() async {
      await tester.tap(button ?? find.text('儲存'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await tester.pump();
    });
    await tester.pumpAndSettle();
  }

  testWidgets('🔴 Hub：只改那一行，註解與別人的設定原樣留著', (tester) async {
    envFile.writeAsStringSync('# 我自己加的\n'
        'CHATROOM_HOST=127.0.0.1\n'
        'CHATROOM_RUN_DAILY_QUOTA=20\n'
        'CHATROOM_UNKNOWN_KEY=keep-me\n');
    sizeUp(tester);
    await tester.pumpWidget(
        wrap(host: HostKit(kitRoot: dir.path, envFile: envFile.path)));
    await tester.pumpAndSettle();

    await typeInto(tester, 'CHATROOM_RUN_DAILY_QUOTA', '50');
    await tapSave(tester);

    expect(
      envFile.readAsStringSync(),
      '# 我自己加的\n'
      'CHATROOM_HOST=127.0.0.1\n'
      'CHATROOM_RUN_DAILY_QUOTA=50\n'
      'CHATROOM_UNKNOWN_KEY=keep-me\n',
      reason: '這一版不認得的 key 在存檔那一刻消失是最難查的一種壞法',
    );
    expect(find.text('已存檔。要重啟 Hub 才生效。'), findsOneWidget);
  });

  testWidgets('Hub：本來沒有的 key 追加在尾端', (tester) async {
    envFile.writeAsStringSync('CHATROOM_RUN_QUEUE_CAP=5\n');
    sizeUp(tester);
    await tester.pumpWidget(
        wrap(host: HostKit(kitRoot: dir.path, envFile: envFile.path)));
    await tester.pumpAndSettle();

    // 畫面上是分鐘，檔案裡是秒——5 分鐘要寫成 300
    await typeInto(tester, 'CHATROOM_IDLE_TIMEOUT', '5');
    await tapSave(tester);

    expect(envFile.readAsStringSync(),
        'CHATROOM_RUN_QUEUE_CAP=5\nCHATROOM_IDLE_TIMEOUT=300\n');
  });

  testWidgets('🔴 填錯：欄位下面講原因，檔案一個字都不動', (tester) async {
    envFile.writeAsStringSync('CHATROOM_RUN_QUEUE_CAP=5\n');
    sizeUp(tester);
    await tester.pumpWidget(
        wrap(host: HostKit(kitRoot: dir.path, envFile: envFile.path)));
    await tester.pumpAndSettle();

    await typeInto(tester, 'CHATROOM_RUN_QUEUE_CAP', '五個');
    await tapSave(tester);

    expect(find.text('要填整數'), findsOneWidget);
    expect(envFile.readAsStringSync(), 'CHATROOM_RUN_QUEUE_CAP=5\n');
  });

  testWidgets('🔴 本來有值的欄位不准清空——空值會讓 Hub 起不來', (tester) async {
    envFile.writeAsStringSync('CHATROOM_IDLE_TIMEOUT=600\n');
    sizeUp(tester);
    await tester.pumpWidget(
        wrap(host: HostKit(kitRoot: dir.path, envFile: envFile.path)));
    await tester.pumpAndSettle();

    await typeInto(tester, 'CHATROOM_IDLE_TIMEOUT', '');
    await tapSave(tester);

    expect(find.text('不能留空'), findsOneWidget);
    expect(envFile.readAsStringSync(), 'CHATROOM_IDLE_TIMEOUT=600\n');
  });

  testWidgets('🔴 位址、埠號與 token 在這一頁改不了', (tester) async {
    envFile.writeAsStringSync('CHATROOM_HOST=127.0.0.1\n'
        'CHATROOM_PORT=8787\n'
        'CHATROOM_TOKEN=secret-value\n'
        'CHATROOM_IDLE_TIMEOUT=600\n');
    sizeUp(tester);
    await tester.pumpWidget(
        wrap(host: HostKit(kitRoot: dir.path, envFile: envFile.path)));
    await tester.pumpAndSettle();

    // 改錯它們的代價是所有成員同時斷線，而那是一顆滑鼠點得到的按鈕
    expect(field('CHATROOM_HOST'), findsNothing);
    expect(field('CHATROOM_PORT'), findsNothing);
    expect(field('CHATROOM_TOKEN'), findsNothing);
    // 收合區也沒有——藏起來的入口還是入口
    expect(find.text('進階'), findsNothing);
    expect(field('CHATROOM_IDLE_TIMEOUT'), findsOneWidget);
  });

  testWidgets('🔴 換 token 要先確認，取消就什麼都沒發生', (tester) async {
    envFile.writeAsStringSync('CHATROOM_TOKEN=secret-value\n');
    sizeUp(tester);
    await tester.pumpWidget(wrap(
      host: HostKit(kitRoot: dir.path, envFile: envFile.path),
      env: const HostEnv(
        host: '127.0.0.1',
        port: '8787',
        token: 'agent-token',
        humanToken: 'human-token',
      ),
    ));
    await tester.pumpAndSettle();

    // UepButton 的字是大寫的（英數才看得出來）
    await tester.tap(find.text('換 TOKEN'));
    await tester.pumpAndSettle();
    expect(find.text('重啟 Hub 後舊 token 失效，所有成員都要換成新的。'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(envFile.readAsStringSync(), 'CHATROOM_TOKEN=secret-value\n');
  });

  testWidgets('🔴 agent：存完講的是「下次連線」，不是重啟 Hub', (tester) async {
    envFile.writeAsStringSync('CHATROOM_URL=http://127.0.0.1:8787\n');
    sizeUp(tester);
    await tester.pumpWidget(
        wrap(mcp: McpKit(kitRoot: dir.path, envFile: envFile.path)));
    await tester.pumpAndSettle();

    await typeInto(tester, 'CHATROOM_DEFAULT_NAME', 'Novia');
    await tapSave(tester);

    expect(envFile.readAsStringSync(),
        'CHATROOM_URL=http://127.0.0.1:8787\nCHATROOM_DEFAULT_NAME=Novia\n');
    expect(find.text('已存檔。下次 agent 連線生效。'), findsOneWidget);
    expect(find.text('已存檔。要重啟 Hub 才生效。'), findsNothing);
  });

  testWidgets('🔴 agent：位址與 token 只能看，改不了', (tester) async {
    envFile.writeAsStringSync('CHATROOM_URL=http://127.0.0.1:8787\n'
        'CHATROOM_TOKEN=agent-token\n');
    sizeUp(tester);
    await tester.pumpWidget(
        wrap(mcp: McpKit(kitRoot: dir.path, envFile: envFile.path)));
    await tester.pumpAndSettle();

    expect(field('CHATROOM_URL'), findsNothing);
    expect(field('CHATROOM_TOKEN'), findsNothing);
    expect(find.text('進階'), findsNothing);
    // 看得到：位址照原樣，token 遮著
    expect(find.text('http://127.0.0.1:8787'), findsOneWidget);
    expect(find.text('agent-token'), findsNothing);
    expect(field('CHATROOM_DEFAULT_NAME'), findsOneWidget);
  });

  testWidgets('🔴 兩邊讀同一個檔：agent 那區連唯讀的位址與 token 都不重複',
      (tester) async {
    // 本機來源模式下 MCP 讀到的就是 Hub 那份 server/.env。同一個 key 在兩個
    // 區塊各出現一次的話，先存的那次會被後存的那次蓋回去
    envFile.writeAsStringSync(
        'CHATROOM_URL=http://127.0.0.1:8787\nCHATROOM_TOKEN=shared-token\n');
    sizeUp(tester);
    await tester.pumpWidget(wrap(
      host: HostKit(kitRoot: dir.path, envFile: envFile.path),
      mcp: McpKit(kitRoot: dir.path, envFile: envFile.path),
    ));
    await tester.pumpAndSettle();

    // 兩種 kit 都裝著時這頁有分頁，agent 那一半要先切過去
    await tester.tap(find.text('Agent 接入'));
    await tester.pumpAndSettle();

    final mcp = find.byType(McpEnvSection);
    expect(find.descendant(of: mcp, matching: find.text('http://127.0.0.1:8787')),
        findsNothing);
    expect(find.descendant(of: mcp, matching: field('CHATROOM_DEFAULT_NAME')),
        findsOneWidget);
    expect(find.text('與 Hub 共用同一份設定檔，連線位址與 token 在 Hub 分頁改。'),
        findsOneWidget);

    await typeInto(tester, 'CHATROOM_DEFAULT_NAME', 'Novia');
    await tapSave(tester, find.descendant(of: mcp, matching: find.text('儲存')));

    expect(
      envFile.readAsStringSync(),
      'CHATROOM_URL=http://127.0.0.1:8787\n'
      'CHATROOM_TOKEN=shared-token\n'
      'CHATROOM_DEFAULT_NAME=Novia\n',
      reason: 'agent 那區存檔不能把 Hub 的 token 一起蓋掉',
    );
  });
}
