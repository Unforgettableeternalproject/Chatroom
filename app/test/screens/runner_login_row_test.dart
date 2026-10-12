import 'dart:io';

import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/screens/host/runner_login_row.dart';
import 'package:chatroom_app/state/runner_kit_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import '../helpers/l10n.dart';

/// 執行器裝好了不等於它動得了：claude 沒登入（或登入過期）的話，第一筆單
/// 就會炸。
///
/// 檔案判準與 `runner-kit/install.py` 的 `has_claude_login()` 是同一份——
/// probe 回 `null`（叫不起 claude）時驗的就是那一份。`claude auth status`
/// 與終端視窗一律覆寫：測試裡不叫這台機器的 claude、不開視窗。
void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('runner-login'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String path(String name) => '${dir.path}${Platform.pathSeparator}$name';

  // stateDir 一定要指到暫存目錄：不然 token 檔會寫到這台機器真正的執行器
  RunnerConfigFile config() => RunnerConfigFile(
        path: path('config.json'),
        raw: const {},
        workspaces: const [],
        modified: DateTime(2026),
        stateDir: dir.path,
        claudeConfigDir: dir.path,
      );

  Widget wrap({
    bool? probed,
    bool mcpExpired = false,
    List<List<String>>? launched,
    List<String?>? probedTokens,
  }) =>
      ProviderScope(
        overrides: [
          runnerConfigProvider.overrideWith((ref) async => config()),
          claudeAuthProbeProvider.overrideWithValue((cfg, {oauthToken}) async {
            probedTokens?.add(oauthToken);
            return probed;
          }),
          machineMcpServersProvider.overrideWith((ref) async =>
              MachineMcpServers(error: 'x', authExpired: mcpExpired)),
          claudeTerminalLauncherProvider
              .overrideWithValue((configDir, args) async {
            launched?.add([configDir, ...args]);
          }),
        ],
        child: MaterialApp(
          locale: kTestLocale,
          localizationsDelegates: kTestLocalizationsDelegates,
          supportedLocales: kTestSupportedLocales,
          theme: buildUepTheme(Brightness.dark),
          home: const Scaffold(
              body: SingleChildScrollView(child: RunnerLoginRow())),
        ),
      );

  /// 登入狀態讀的是真的檔案，那些 future 在測試的 fake async 裡不會自己
  /// 走完——`runAsync` 裡放它們跑，再 pump。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  void sizeUp(WidgetTester tester) {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('🔴 沒有憑證 → 尚未登入，並給帶得上設定目錄的那一行指令',
      (tester) async {
    sizeUp(tester);
    await tester.pumpWidget(wrap());
    await settle(tester);

    expect(find.text('尚未登入'), findsOneWidget);
    expect(
        find.text('\$env:CLAUDE_CONFIG_DIR = "${dir.path}"; claude auth login'),
        findsOneWidget,
        reason: '在別的設定目錄登入等於沒登入，指令一定要帶 CLAUDE_CONFIG_DIR');
    expect(find.byIcon(Icons.copy), findsOneWidget);
    expect(find.text('登入'), findsOneWidget);
  });

  testWidgets('有 .credentials.json → 已登入，不再叫人去登', (tester) async {
    sizeUp(tester);
    File(path('.credentials.json'))
        .writeAsStringSync('{"claudeAiOauth": {"accessToken": "x"}}');

    await tester.pumpWidget(wrap());
    await settle(tester);

    expect(find.text('已登入'), findsOneWidget);
    expect(find.byIcon(Icons.copy), findsNothing);
    expect(find.text('登入'), findsNothing);
  });

  testWidgets('🔴 空的 .credentials.json 不算登入', (tester) async {
    sizeUp(tester);
    File(path('.credentials.json')).writeAsStringSync('{}');

    await tester.pumpWidget(wrap());
    await settle(tester);

    expect(find.text('尚未登入'), findsOneWidget,
        reason: '寧可多叫一次登入，也不要顯示「已登入」而執行器第一筆單就炸');
  });

  testWidgets('🔴 憑證檔在但 claude 說沒登入 → 登入已過期，給登入按鈕',
      (tester) async {
    sizeUp(tester);
    File(path('.credentials.json'))
        .writeAsStringSync('{"claudeAiOauth": {"accessToken": "x"}}');

    await tester.pumpWidget(wrap(probed: false));
    await settle(tester);

    expect(find.text('登入已過期'), findsOneWidget);
    expect(find.text('已登入'), findsNothing);
    expect(find.text('登入'), findsOneWidget);
  });

  testWidgets('🔴 mcp list 說 OAuth 過期 → 登入已過期，即使 auth status 說已登入',
      (tester) async {
    sizeUp(tester);
    await tester.pumpWidget(wrap(probed: true, mcpExpired: true));
    await settle(tester);

    expect(find.text('登入已過期'), findsOneWidget);
  });

  testWidgets('按登入 → 以執行器的設定目錄開終端跑 claude auth login',
      (tester) async {
    sizeUp(tester);
    final launched = <List<String>>[];
    await tester.pumpWidget(wrap(probed: false, launched: launched));
    await settle(tester);

    await tester.tap(find.text('登入'));
    await settle(tester);

    expect(launched, [
      [dir.path, 'auth', 'login']
    ]);
  });

  testWidgets('按產生 → 開終端跑 claude setup-token', (tester) async {
    sizeUp(tester);
    final launched = <List<String>>[];
    await tester.pumpWidget(wrap(probed: true, launched: launched));
    await settle(tester);

    await tester.tap(find.text('產生'));
    await settle(tester);

    expect(launched, [
      [dir.path, 'setup-token']
    ]);
  });

  testWidgets('🔴 存 token：寫進 claude-oauth-token，畫面只說已設定、不回顯',
      (tester) async {
    sizeUp(tester);
    final tokens = <String?>[];
    const secret = 'sk-ant-oat01-secret';
    await tester.pumpWidget(wrap(probed: true, probedTokens: tokens));
    await settle(tester);
    expect(find.text('未設定'), findsOneWidget);

    await tester.enterText(
        find.byKey(const ValueKey('runner-oauth-token')), '  $secret\n');
    await tester.tap(find.text('儲存'));
    await settle(tester);

    final file = File(path('claude-oauth-token'));
    expect(file.readAsStringSync(), secret);
    expect(find.text('已設定'), findsOneWidget);
    expect(find.textContaining(secret), findsNothing,
        reason: 'token 不得出現在畫面上');
    expect(tokens.last, secret, reason: '判斷登入時要帶上 token');

    await tester.tap(find.text('清除'));
    await settle(tester);

    expect(file.existsSync(), isFalse);
    expect(find.text('未設定'), findsOneWidget);
  });

  testWidgets('中間有空白的不是 token：不寫檔，說一句', (tester) async {
    sizeUp(tester);
    await tester.pumpWidget(wrap(probed: true));
    await settle(tester);

    await tester.enterText(
        find.byKey(const ValueKey('runner-oauth-token')), 'not a token');
    await tester.tap(find.text('儲存'));
    await settle(tester);

    expect(File(path('claude-oauth-token')).existsSync(), isFalse);
    expect(find.text('這不像 token'), findsOneWidget);
  });
}
