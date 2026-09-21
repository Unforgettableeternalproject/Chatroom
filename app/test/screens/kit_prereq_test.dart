import 'dart:io';

import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/screens/host/kit_install_section.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/host_kit_providers.dart';
import 'package:chatroom_app/state/kit_installer.dart';
import 'package:chatroom_app/state/kit_prereq.dart';
import 'package:chatroom_app/widgets/uep_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import '../helpers/l10n.dart';

/// 裝之前先查這台機器：**缺哪一項就擋哪一包，並講出缺的是什麼**。
///
/// 三包之間沒有相依（runner-kit 自帶 bridge），相依的是外部環境——所以
/// 這裡的每一條都是「外面少了一個東西」，沒有一條是「你要先裝另一包」。
void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  const release = KitRelease(tag: 'v1.2.3', assets: {
    'chatroom-hub-kit.zip': 'https://example.invalid/hub.zip',
    'chatroom-mcp-kit.zip': 'https://example.invalid/mcp.zip',
    'chatroom-runner-kit.zip': 'https://example.invalid/runner.zip',
  });

  Widget wrap(
    KitId kit, {
    PythonExe? python = const PythonExe(executable: 'py', prefixArgs: ['-3.12']),
    Set<String> clis = const {'claude', 'codex'},
    String serverUrl = 'http://hub.invalid:8787',
    bool hubReachable = true,
  }) =>
      ProviderScope(
        overrides: [
          kitInstallSupportedProvider.overrideWithValue(true),
          initialConfigProvider.overrideWithValue(AppConfig(
            serverUrl: serverUrl,
            token: '',
            themeMode: ThemeModePref.dark,
            preferredName: '',
            deviceKey: 'k',
          )),
          kitReleaseProvider.overrideWith((ref) async => release),
          kitPythonProvider.overrideWith((ref) async => python),
          // 真的 `_probeCli` 走這個假子進程：叫不起來時它**丟例外**，
          // 而畫面要把那個例外當「找不到」，不是當錯誤
          kitProcessRunnerProvider.overrideWithValue(_FakeCliRunner(clis)),
          kitHubReachableProvider.overrideWith((ref) async => hubReachable),
          runnerBusyProvider.overrideWith((ref) async => false),
          hostKitProvider.overrideWith((ref) async => null),
        ],
        child: MaterialApp(
          locale: kTestLocale,
          localizationsDelegates: kTestLocalizationsDelegates,
          supportedLocales: kTestSupportedLocales,
          theme: buildUepTheme(Brightness.dark),
          home: Scaffold(
            body: SingleChildScrollView(
              child: KitInstallSection(kit: kit, installed: false),
            ),
          ),
        ),
      );

  UepButton install(WidgetTester tester) => tester
      .widgetList<UepButton>(find.byType(UepButton))
      .firstWhere((b) => b.label == '安裝');

  group('Hub 主持包：只要 Python', () {
    testWidgets('全過 → 裝得了', (tester) async {
      await tester.pumpWidget(wrap(KitId.hub));
      await tester.pumpAndSettle();

      expect(find.text('找到 py -3.12'), findsOneWidget);
      expect(install(tester).onPressed, isNotNull);
      expect(find.text('先處理上面的項目'), findsNothing);
    });

    testWidgets('🔴 沒有 Python → 擋住，並講出缺的是什麼', (tester) async {
      await tester.pumpWidget(wrap(KitId.hub, python: null));
      await tester.pumpAndSettle();

      expect(find.text('找不到 Python 3.12'), findsOneWidget);
      expect(install(tester).onPressed, isNull);
      expect(find.text('先處理上面的項目'), findsOneWidget);
    });

    testWidgets('Hub 包不管 CLI 與 Hub 位址', (tester) async {
      await tester.pumpWidget(
          wrap(KitId.hub, clis: const {}, serverUrl: '', hubReachable: false));
      await tester.pumpAndSettle();

      expect(install(tester).onPressed, isNotNull,
          reason: 'Hub 自己就是那個位址，不必先連得到一個還不存在的 Hub');
      expect(find.text('Hub 位址'), findsNothing);
    });
  });

  group('Agent 接入包：Python、claude 或 codex、Hub 連得到', () {
    testWidgets('全過 → 裝得了', (tester) async {
      await tester.pumpWidget(wrap(KitId.mcp));
      await tester.pumpAndSettle();

      expect(find.text('http://hub.invalid:8787 連得上'), findsOneWidget);
      expect(install(tester).onPressed, isNotNull);
    });

    testWidgets('只有 codex 也算過', (tester) async {
      await tester.pumpWidget(wrap(KitId.mcp, clis: const {'codex'}));
      await tester.pumpAndSettle();

      expect(install(tester).onPressed, isNotNull,
          reason: '兩種 agent 都接得上這座橋，要一個就夠');
    });

    testWidgets('🔴 兩個 CLI 都沒有 → 擋住', (tester) async {
      await tester.pumpWidget(wrap(KitId.mcp, clis: const {}));
      await tester.pumpAndSettle();

      expect(find.text('claude 與 codex 都叫不起來'), findsOneWidget);
      expect(install(tester).onPressed, isNull);
      expect(find.text('先處理上面的項目'), findsOneWidget);
    });

    testWidgets('🔴 Hub 位址沒填 → 擋住，講的是「去填」不是「連不上」',
        (tester) async {
      await tester.pumpWidget(wrap(KitId.mcp, serverUrl: ''));
      await tester.pumpAndSettle();

      expect(find.text('設定頁還沒填 Hub 位址'), findsOneWidget);
      expect(install(tester).onPressed, isNull);
    });
  });

  group('執行器包：Python、claude、Hub 連得到', () {
    testWidgets('全過 → 裝得了', (tester) async {
      await tester.pumpWidget(wrap(KitId.runner));
      await tester.pumpAndSettle();

      expect(install(tester).onPressed, isNotNull);
    });

    testWidgets('🔴 只有 codex 不夠 → 擋住', (tester) async {
      await tester.pumpWidget(wrap(KitId.runner, clis: const {'codex'}));
      await tester.pumpAndSettle();

      expect(find.text('claude 叫不起來'), findsOneWidget);
      expect(install(tester).onPressed, isNull);
    });

    testWidgets('🔴 Hub 連不上 → 擋住，位址寫在原因裡', (tester) async {
      await tester.pumpWidget(wrap(KitId.runner, hubReachable: false));
      await tester.pumpAndSettle();

      expect(find.text('http://hub.invalid:8787 連不上'), findsOneWidget);
      expect(install(tester).onPressed, isNull);
      expect(find.text('先處理上面的項目'), findsOneWidget);
    });
  });
}

/// 只認得清單裡那幾個執行檔的假子進程。
///
/// 🔴 認不得的**丟例外**（`Process.run` 找不到執行檔就是這樣）：這一條就是
/// 要驗「探測把例外吞成『找不到』」——吞不住的話 provider 會被標成 error，
/// 畫面永遠停在「檢查中」，而 PATH 裡沒有 claude 這件事一個字都不會出現。
class _FakeCliRunner implements KitProcessRunner {
  _FakeCliRunner(this.available);

  final Set<String> available;

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    if (!available.contains(executable)) {
      throw ProcessException(executable, arguments, '找不到執行檔', 2);
    }
    return ProcessResult(0, 0, '$executable 1.0.0', '');
  }
}
