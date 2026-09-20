import 'dart:convert';
import 'dart:io';

import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/screens/host/runner_mcp_section.dart';
import 'package:chatroom_app/state/runner_kit_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/l10n.dart';

/// 執行器層的「允許派工使用的 MCP」勾選介面。
///
/// 三件事：
/// 1. **清單是本機列到的 ∪ 設定裡已經有的**——只畫本機那一份的話，存檔那一刻
///    會把別人設的允許項目一起拿掉，而畫面上不會有任何跡象。
/// 2. **chatroom 取消不了**：run 沒有它就進不了房，那一輪只會盲做。
/// 3. **問不到清單時不准說「本機找不到」**：那是「我們沒問到」，不是
///    「這台機器沒有」。
///
/// 檔案 I/O 在 widget 測試的假時間裡不會自己走完，所以讀設定與按存檔都放在
/// `runAsync`（與 `host_env_edit_test` 同一個做法）。
void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('runner_mcp_section');
    path = '${dir.path}${Platform.pathSeparator}config.json';
    File(path).writeAsStringSync(jsonEncode({
      'hub_url': 'http://127.0.0.1:8787',
      'allowed_mcp_servers': ['chatroom', 'claude.ai Atlassian Rovo'],
      'workspaces': <String, dynamic>{},
    }));
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Map<String, dynamic> raw() =>
      (jsonDecode(File(path).readAsStringSync()) as Map)
          .cast<String, dynamic>();

  Widget wrap(
    RunnerConfigFile config, {
    List<String>? machine,
    String machineError = '',
    Map<String, McpServerOrigin> origins = const {},
    String globalError = '',
    bool complete = true,
  }) =>
      ProviderScope(
        overrides: [
          runnerConfigProvider.overrideWith((ref) async => config),
          runnerIdProvider.overrideWith((ref) async => null),
          machineMcpServersProvider.overrideWith((ref) async =>
              MachineMcpServers(
                  names: machine,
                  error: machineError,
                  origins: origins,
                  globalError: globalError,
                  complete: complete)),
        ],
        child: MaterialApp(
          locale: kTestLocale,
          localizationsDelegates: kTestLocalizationsDelegates,
          supportedLocales: kTestSupportedLocales,
          theme: buildUepTheme(Brightness.dark),
          home: const Scaffold(
            body: SingleChildScrollView(child: RunnerMcpSection()),
          ),
        ),
      );

  Future<RunnerConfigFile> load(WidgetTester tester) async =>
      (await tester.runAsync(() => readRunnerConfig(path)))!;

  testWidgets('🔴 設定裡有、本機沒列到的名字照樣要畫出來，並標「本機找不到」',
      (tester) async {
    await tester.pumpWidget(
        wrap(await load(tester), machine: const ['chatroom', 'fff']));
    await tester.pumpAndSettle();

    expect(find.text('claude.ai Atlassian Rovo'), findsOneWidget);
    expect(find.text('本機找不到'), findsOneWidget);
    expect(find.text('fff'), findsOneWidget);
  });

  testWidgets('🔴 chatroom 那一列勾著而且按不動', (tester) async {
    await tester.pumpWidget(
        wrap(await load(tester), machine: const ['chatroom', 'fff']));
    await tester.pumpAndSettle();

    final required = tester.widgetList<Checkbox>(find.byType(Checkbox)).first;
    expect(find.text('必要'), findsOneWidget);
    expect(required.value, isTrue);
    expect(required.onChanged, isNull, reason: '沒有 chatroom 就連不上聊天室');
  });

  testWidgets('🔴 問不到清單：不標「本機找不到」，只說讀不到', (tester) async {
    await tester.pumpWidget(
        wrap(await load(tester), machineError: 'claude mcp list 逾時'));
    await tester.pumpAndSettle();

    expect(find.text('本機找不到'), findsNothing,
        reason: '「查不到他在」不等於「他不在」');
    expect(find.textContaining('讀不到本機 MCP 清單'), findsOneWidget);
    expect(find.text('正在讀這台機器的 MCP 清單…'), findsNothing,
        reason: '一直停在「正在讀」＝「讀不到」永遠不會被說出來');
    expect(find.text('claude.ai Atlassian Rovo'), findsOneWidget);
  });

  testWidgets('🔴 兩邊的伺服器都列得出來，而且各標各的來源', (tester) async {
    // 連接器只有 `claude mcp list` 問得到，fff 只在全域 .claude.json 裡；
    // 少列一邊的症狀是「勾不到」，而畫面上不會有任何跡象
    await tester.pumpWidget(wrap(
      await load(tester),
      machine: const ['chatroom', 'claude.ai Atlassian Rovo', 'fff'],
      origins: const {
        'chatroom': McpServerOrigin.connector,
        'claude.ai Atlassian Rovo': McpServerOrigin.connector,
        'fff': McpServerOrigin.global,
      },
    ));
    await tester.pumpAndSettle();

    expect(find.text('fff'), findsOneWidget);
    expect(find.text('全域 .claude.json'), findsOneWidget);
    expect(find.text('claude.ai 連接器'), findsNWidgets(2));
    expect(find.text('本機找不到'), findsNothing);
  });

  testWidgets('🔴 兩邊都有的名字只列一次，來源以全域為準', (tester) async {
    // run 帶進去的是全域那一份定義，標示要跟實際載入的一致
    final merged = mergeMcpServers(
        const MachineMcpServers(names: ['chatroom', 'fff']),
        const MachineMcpServers(names: ['fff', 'mempal']));
    await tester.pumpWidget(wrap(await load(tester),
        machine: merged.names, origins: merged.origins));
    await tester.pumpAndSettle();

    expect(find.text('fff'), findsOneWidget);
    expect(merged.origins['fff'], McpServerOrigin.global);
    expect(find.text('全域 .claude.json'), findsNWidgets(2));
  });

  testWidgets('🔴 讀不到全域檔：只列另一邊，說一句，不說「本機找不到」',
      (tester) async {
    await tester.pumpWidget(wrap(
      await load(tester),
      machine: const ['chatroom', 'claude.ai Atlassian Rovo'],
      origins: const {
        'chatroom': McpServerOrigin.connector,
        'claude.ai Atlassian Rovo': McpServerOrigin.connector,
      },
      globalError: 'C:/Users/x/.claude.json',
      complete: false,
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('讀不到全域 .claude.json'), findsOneWidget);
    expect(find.text('claude.ai Atlassian Rovo'), findsOneWidget);
    expect(find.text('本機找不到'), findsNothing,
        reason: '缺的那些很可能就在沒問到的那一邊');
  });

  testWidgets('勾一台本機伺服器 → 存檔寫進 allowed_mcp_servers', (tester) async {
    await tester.pumpWidget(
        wrap(await load(tester), machine: const ['chatroom', 'fff']));
    await tester.pumpAndSettle();

    await tester.tap(find.text('fff'));
    await tester.pumpAndSettle();
    // 寫檔那一步是這支測試的題目，所以按鈕要在 `runAsync` 裡按
    await tester.runAsync(() async {
      await tester.tap(find.text('儲存並套用'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();

    expect(raw()['allowed_mcp_servers'],
        ['chatroom', 'claude.ai Atlassian Rovo', 'fff']);
    expect(raw()['hub_url'], 'http://127.0.0.1:8787',
        reason: '整份重組的話，沒碰到的欄位會在存檔那一刻消失');
  });
}
