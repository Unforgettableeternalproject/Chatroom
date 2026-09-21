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

import '../helpers/fake_kit_backend.dart';
import '../helpers/l10n.dart';

/// 安裝／更新區塊上那顆按鈕**什麼時候按得動**。
///
/// 每一種按不動都要有自己的理由寫在旁邊：一顆灰掉而沒有說明的按鈕，
/// 與一個壞掉的功能在使用者眼裡是同一件事。
void main() {
  // runAsync 會讓 google_fonts 真的去抓字型；測試不打網路
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  const release = KitRelease(tag: 'v1.2.3', assets: {
    'chatroom-hub-kit.zip': 'https://example.invalid/hub.zip',
    'chatroom-runner-kit.zip': 'https://example.invalid/runner.zip',
  });

  Widget wrap(
    KitInstallSection section, {
    KitRelease? found = release,
    PythonExe? python = const PythonExe(executable: 'py', prefixArgs: ['-3.12']),
    bool runnerBusy = false,
    KitInstaller? installer,
    List<KitPrereq> prereqs = const [KitPrereq(KitPrereqKind.python)],
  }) =>
      ProviderScope(
        overrides: [
          kitInstallSupportedProvider.overrideWithValue(true),
          initialConfigProvider.overrideWithValue(const AppConfig(
            serverUrl: '',
            token: '',
            themeMode: ThemeModePref.dark,
            preferredName: '',
            deviceKey: 'k',
          )),
          if (installer != null) kitInstallerProvider.overrideWithValue(installer),
          kitReleaseProvider.overrideWith((ref) async => found),
          kitPythonProvider.overrideWith((ref) async => python),
          runnerBusyProvider.overrideWith((ref) async => runnerBusy),
          // 前置條件在這一組測試裡不是被測的東西——不覆寫的話，它會去
          // 跑真的 `claude --version` 並打真的 Hub
          kitPrereqsProvider.overrideWith((ref, kit) async => prereqs),
          hostKitProvider.overrideWith((ref) async => null),
        ],
        child: MaterialApp(
          locale: kTestLocale,
          localizationsDelegates: kTestLocalizationsDelegates,
          supportedLocales: kTestSupportedLocales,
          theme: buildUepTheme(Brightness.dark),
          home: Scaffold(body: SingleChildScrollView(child: section)),
        ),
      );

  /// 安裝走的是**真的**檔案 I/O（檢查位置、解壓、寫檔），那些 future 在
  /// 測試的 fake async 裡不會自己走完——`runAsync` 裡放它們跑，再 pump。
  Future<void> settleIo(WidgetTester tester, bool Function() done) async {
    // 一次 runAsync 讓真的 I/O 走一段，一次 pump 讓它的後續（排在測試那顆
    // fake async 佇列上）跑起來——只做其中一邊的話會永遠等不到結果。
    for (var i = 0; i < 80 && !done(); i++) {
      await tester
          .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  void sizeUp(WidgetTester tester) {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  UepButton buttonNamed(WidgetTester tester, String label) => tester
      .widgetList<UepButton>(find.byType(UepButton))
      .firstWhere((b) => b.label == label);

  bool hasButton(WidgetTester tester, String label) => tester
      .widgetList<UepButton>(find.byType(UepButton))
      .any((b) => b.label == label);

  testWidgets('沒裝 → 按鈕講「安裝」，按得動', (tester) async {
    await tester.pumpWidget(wrap(
        const KitInstallSection(kit: KitId.hub, installed: false)));
    await tester.pumpAndSettle();

    expect(find.text('尚未安裝 Hub 主持包。'), findsOneWidget);
    expect(find.textContaining('v1.2.3'), findsOneWidget);
    expect(buttonNamed(tester, '安裝').onPressed, isNotNull);
  });

  testWidgets('已裝但版本不同 → 按鈕講「更新」', (tester) async {
    await tester.pumpWidget(wrap(const KitInstallSection(
        kit: KitId.runner, installed: true, installedVersion: '1.2.2')));
    await tester.pumpAndSettle();

    expect(buttonNamed(tester, '更新').onPressed, isNotNull);
  });

  testWidgets('🔴 已經是 Release 那一版 → 按不動，理由寫在旁邊', (tester) async {
    await tester.pumpWidget(wrap(const KitInstallSection(
        kit: KitId.runner, installed: true, installedVersion: '1.2.3+abc123')));
    await tester.pumpAndSettle();

    expect(buttonNamed(tester, '更新').onPressed, isNull,
        reason: '同一版再裝一次只會讓人以為出了什麼事');
    expect(find.text('已經是 Release 上那一版'), findsOneWidget);
  });

  testWidgets('🔴 這一版沒有對應的 Release → 沒有按鈕，只有說明', (tester) async {
    await tester.pumpWidget(wrap(
      const KitInstallSection(kit: KitId.hub, installed: false),
      found: null,
    ));
    await tester.pumpAndSettle();

    expect(
        find.text('這份 App 沒有對應的 Release。請在 repo 執行 host-kit/build.py '
            '打包，再手動安裝。'),
        findsOneWidget);
    expect(find.byType(UepButton), findsNothing,
        reason: 'dev build 裝不了東西，不該畫一顆按不動的按鈕在那裡');
  });

  testWidgets('Release 裡沒有這包的資產 → 講出缺的是哪一個', (tester) async {
    await tester.pumpWidget(wrap(
        const KitInstallSection(kit: KitId.mcp, installed: false)));
    await tester.pumpAndSettle();

    expect(find.text('這個 Release 裡沒有 chatroom-mcp-kit.zip'), findsOneWidget);
    expect(find.byType(UepButton), findsNothing);
  });

  testWidgets('🔴 沒有 Python 3.12 → 按不動，給下載連結（不代裝）', (tester) async {
    await tester.pumpWidget(wrap(
      const KitInstallSection(kit: KitId.hub, installed: false),
      python: null,
    ));
    await tester.pumpAndSettle();

    expect(buttonNamed(tester, '安裝').onPressed, isNull);
    expect(hasButton(tester, '前往 python.org 下載'), isTrue);
  });

  testWidgets('🔴 執行器手上還有 run → 擋住更新，叫人去儀表板 drain', (tester) async {
    await tester.pumpWidget(wrap(
      const KitInstallSection(
          kit: KitId.runner, installed: true, installedVersion: '1.2.2'),
      runnerBusy: true,
    ));
    await tester.pumpAndSettle();

    expect(buttonNamed(tester, '更新').onPressed, isNull);
    expect(find.text('執行器手上還有 run，請先到儀表板按 drain'), findsOneWidget);
  });

  testWidgets('執行器忙不忙只擋執行器，不擋 Hub', (tester) async {
    await tester.pumpWidget(wrap(
      const KitInstallSection(kit: KitId.hub, installed: false),
      runnerBusy: true,
    ));
    await tester.pumpAndSettle();

    expect(buttonNamed(tester, '安裝').onPressed, isNotNull);
  });

  group('安裝位置', () {
    late Directory root;
    late FakeKitBackend backend;
    late KitInstaller installer;

    setUp(() {
      root = Directory.systemTemp.createTempSync('kit-install-ui');
      backend = FakeKitBackend();
      installer = KitInstaller(
        http: backend,
        processRunner: backend,
        installRoot: root.path,
      );
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    testWidgets('預設值＝原本的固定位置，按下去就裝到那裡', (tester) async {
      sizeUp(tester);
      await tester.pumpWidget(wrap(
        const KitInstallSection(kit: KitId.hub, installed: false),
        installer: installer,
      ));
      await tester.pumpAndSettle();

      final expected = '${root.path}${Platform.pathSeparator}hub-kit';
      expect(find.text(expected), findsOneWidget,
          reason: '欄位上寫的位置要與安裝器實際用的是同一個');

      await tester.tap(find.text('安裝'));
      await settleIo(tester, () => backend.installScript != null);

      expect(backend.extractedTo, expected);
      expect(backend.installScript, startsWith(expected));
    });

    testWidgets('🔴 自訂位置：解壓與安裝器參數都走那一個', (tester) async {
      sizeUp(tester);
      await tester.pumpWidget(wrap(
        const KitInstallSection(kit: KitId.runner, installed: false),
        installer: installer,
      ));
      await tester.pumpAndSettle();

      final custom = '${root.path}${Platform.pathSeparator}elsewhere';
      await tester.enterText(find.byType(TextField).first, custom);
      await tester.tap(find.text('安裝'));
      await settleIo(tester, () => backend.installScript != null);

      expect(backend.extractedTo, custom);
      // runner-kit 會再搬一次，所以同一個位置要用 `--dir` 告訴它
      expect(backend.installArgs, containsAllInOrder(['--dir', custom]));
    });

    testWidgets('🔴 位置不能用 → 連下載都不開始，理由寫在欄位下面',
        (tester) async {
      sizeUp(tester);
      await tester.pumpWidget(wrap(
        const KitInstallSection(kit: KitId.hub, installed: false),
        installer: installer,
      ));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'hub-kit');
      await tester.tap(find.text('安裝'));
      await settleIo(tester, () => false);

      expect(find.text('請填完整路徑（含磁碟機代號）'), findsOneWidget);
      expect(backend.extractedTo, isNull,
          reason: '解壓到一半才發現位置不能用的話，磁碟上會留下半包東西');
    });
  });
}
