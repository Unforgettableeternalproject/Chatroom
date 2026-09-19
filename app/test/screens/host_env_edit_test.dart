import 'dart:io';

import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/core/util/env_file.dart';
import 'package:chatroom_app/models/host_kit.dart';
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
/// 兩件事要分開驗：**檔案有沒有被正確改到**（只動那一行，別人的註解還在），
/// 與**存完之後說了什麼**——Hub 這邊要重啟進程才生效，MCP 那邊是下次連線
/// 才生效，兩句提示講的是不同的事，混在一起的話照著做的人會去重啟一個
/// 不必重啟的東西。
void main() {
  late Directory dir;
  late File envFile;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('host_env_edit');
    envFile = File('${dir.path}${Platform.pathSeparator}.env');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Widget wrap({HostKit? host, McpKit? mcp}) => ProviderScope(
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
          hostEnvProvider.overrideWith((ref) async => null),
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

  Future<void> typeInto(WidgetTester tester, String key, String value) async {
    await tester.enterText(find.widgetWithText(TextField, key), value);
    await tester.pump();
  }

  /// 存檔要走到真的檔案，那是真的 I/O——假時間裡它不會完成。
  Future<void> tapSave(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(find.text('儲存'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await tester.pump();
    });
    await tester.pumpAndSettle();
  }

  testWidgets('🔴 Hub：只改那一行，註解與別人的設定原樣留著', (tester) async {
    envFile.writeAsStringSync('# 我自己加的\n'
        'CHATROOM_HOST=127.0.0.1\n'
        'CHATROOM_PORT=8787\n'
        'CHATROOM_UNKNOWN_KEY=keep-me\n');
    sizeUp(tester);
    await tester.pumpWidget(
        wrap(host: HostKit(kitRoot: dir.path, envFile: envFile.path)));
    await tester.pumpAndSettle();

    await typeInto(tester, 'CHATROOM_PORT', '9000');
    await tapSave(tester);

    expect(
      envFile.readAsStringSync(),
      '# 我自己加的\n'
      'CHATROOM_HOST=127.0.0.1\n'
      'CHATROOM_PORT=9000\n'
      'CHATROOM_UNKNOWN_KEY=keep-me\n',
      reason: '這一版不認得的 key 在存檔那一刻消失是最難查的一種壞法',
    );
    expect(find.text('已存檔。要重啟 Hub 才生效。'), findsOneWidget);
  });

  testWidgets('Hub：本來沒有的 key 追加在尾端', (tester) async {
    envFile.writeAsStringSync('CHATROOM_PORT=8787\n');
    sizeUp(tester);
    await tester.pumpWidget(
        wrap(host: HostKit(kitRoot: dir.path, envFile: envFile.path)));
    await tester.pumpAndSettle();

    await typeInto(tester, 'CHATROOM_IDLE_TIMEOUT', '300');
    await tapSave(tester);

    expect(envFile.readAsStringSync(),
        'CHATROOM_PORT=8787\nCHATROOM_IDLE_TIMEOUT=300\n');
  });

  testWidgets('🔴 埠號填錯：欄位下面講原因，檔案一個字都不動', (tester) async {
    envFile.writeAsStringSync('CHATROOM_PORT=8787\n');
    sizeUp(tester);
    await tester.pumpWidget(
        wrap(host: HostKit(kitRoot: dir.path, envFile: envFile.path)));
    await tester.pumpAndSettle();

    await typeInto(tester, 'CHATROOM_PORT', '70000');
    await tapSave(tester);

    expect(find.text('要在 1–65535 之間'), findsOneWidget);
    expect(envFile.readAsStringSync(), 'CHATROOM_PORT=8787\n');
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

  testWidgets('token 預設遮起來，按眼睛才顯示', (tester) async {
    envFile.writeAsStringSync('CHATROOM_TOKEN=secret-value\n');
    sizeUp(tester);
    await tester.pumpWidget(
        wrap(host: HostKit(kitRoot: dir.path, envFile: envFile.path)));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
        find.widgetWithText(TextField, 'CHATROOM_TOKEN'));
    expect(field.obscureText, isTrue);

    await tester.tap(find.byIcon(Icons.visibility_off));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'CHATROOM_TOKEN'))
          .obscureText,
      isFalse,
    );
  });

  testWidgets('🔴 MCP kit：存完講的是「下次連線」，不是重啟 Hub', (tester) async {
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

  testWidgets('MCP kit：網址格式不對就不寫', (tester) async {
    envFile.writeAsStringSync('CHATROOM_URL=http://127.0.0.1:8787\n');
    sizeUp(tester);
    await tester.pumpWidget(
        wrap(mcp: McpKit(kitRoot: dir.path, envFile: envFile.path)));
    await tester.pumpAndSettle();

    await typeInto(tester, 'CHATROOM_URL', '127.0.0.1:8787');
    await tapSave(tester);

    expect(find.text('要是 http:// 或 https:// 開頭的網址'), findsOneWidget);
    expect(envFile.readAsStringSync(), 'CHATROOM_URL=http://127.0.0.1:8787\n');
  });
}
