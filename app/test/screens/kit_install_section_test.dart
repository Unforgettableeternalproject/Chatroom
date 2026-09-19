import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/screens/host/kit_install_section.dart';
import 'package:chatroom_app/state/host_kit_providers.dart';
import 'package:chatroom_app/state/kit_installer.dart';
import 'package:chatroom_app/widgets/uep_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/l10n.dart';

/// 安裝／更新區塊上那顆按鈕**什麼時候按得動**。
///
/// 每一種按不動都要有自己的理由寫在旁邊：一顆灰掉而沒有說明的按鈕，
/// 與一個壞掉的功能在使用者眼裡是同一件事。
void main() {
  const release = KitRelease(tag: 'v1.2.3', assets: {
    'chatroom-hub-kit.zip': 'https://example.invalid/hub.zip',
    'chatroom-runner-kit.zip': 'https://example.invalid/runner.zip',
  });

  Widget wrap(
    KitInstallSection section, {
    KitRelease? found = release,
    PythonExe? python = const PythonExe(executable: 'py', prefixArgs: ['-3.12']),
    bool runnerBusy = false,
  }) =>
      ProviderScope(
        overrides: [
          kitInstallSupportedProvider.overrideWithValue(true),
          kitReleaseProvider.overrideWith((ref) async => found),
          kitPythonProvider.overrideWith((ref) async => python),
          runnerBusyProvider.overrideWith((ref) async => runnerBusy),
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

    expect(find.text('這台機器還沒裝這一包。'), findsOneWidget);
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

    expect(find.text('此版本沒有對應的 Release，請用安裝包'), findsOneWidget);
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
}
