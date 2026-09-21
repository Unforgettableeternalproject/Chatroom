import 'dart:io';

import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/screens/host/runner_login_row.dart';
import 'package:chatroom_app/state/runner_kit_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import '../helpers/l10n.dart';

/// 執行器裝好了不等於它動得了：claude 沒登入的話，第一筆單就會炸。
///
/// 判準與 `runner-kit/install.py` 的 `has_claude_login()` 是同一份——這裡驗
/// 的就是那一份，不是驗一個 override 進去的布林值。
void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('runner-login'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  RunnerConfigFile config() => RunnerConfigFile(
        path: '${dir.path}${Platform.pathSeparator}config.json',
        raw: const {},
        workspaces: const [],
        modified: DateTime(2026),
        claudeConfigDir: dir.path,
      );

  Widget wrap() => ProviderScope(
        overrides: [
          runnerConfigProvider.overrideWith((ref) async => config()),
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

  testWidgets('🔴 沒有憑證 → 尚未登入，並給帶得上設定目錄的那一行指令',
      (tester) async {
    await tester.pumpWidget(wrap());
    await settle(tester);

    expect(find.text('尚未登入'), findsOneWidget);
    expect(
        find.text('\$env:CLAUDE_CONFIG_DIR = "${dir.path}"; claude auth login'),
        findsOneWidget,
        reason: '在別的設定目錄登入等於沒登入，指令一定要帶 CLAUDE_CONFIG_DIR');
    expect(find.byIcon(Icons.copy), findsOneWidget);
  });

  testWidgets('有 .credentials.json → 已登入，不再叫人去登', (tester) async {
    File('${dir.path}${Platform.pathSeparator}.credentials.json')
        .writeAsStringSync('{"claudeAiOauth": {"accessToken": "x"}}');

    await tester.pumpWidget(wrap());
    await settle(tester);

    expect(find.text('已登入'), findsOneWidget);
    expect(find.byIcon(Icons.copy), findsNothing);
  });

  testWidgets('🔴 空的 .credentials.json 不算登入', (tester) async {
    File('${dir.path}${Platform.pathSeparator}.credentials.json')
        .writeAsStringSync('{}');

    await tester.pumpWidget(wrap());
    await settle(tester);

    expect(find.text('尚未登入'), findsOneWidget,
        reason: '寧可多叫一次登入，也不要顯示「已登入」而執行器第一筆單就炸');
  });
}
