import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/widgets/pane_divider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/l10n.dart';

/// 分隔線拖曳 → 寬度改變 → 落盤，以及夾取與雙擊還原。
///
/// 這裡重現的是 `app_shell` / `chat_screen` 的接法（以**當下畫出來的寬度**
/// 加位移），不是那兩個畫面本身——它們要一整套 provider 才起得來，而這條
/// 鏈要驗的是手勢、notifier 與 prefs 三者接得上。版面依視窗再夾一次那半
/// 由 `clampLeftPaneWidth(available:)` 單獨驗（pane_width_pref_test）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsRepository settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsRepository(await SharedPreferences.getInstance());
  });

  Widget harness() => ProviderScope(
        overrides: [
          settingsRepoProvider.overrideWithValue(settings),
          initialConfigProvider.overrideWithValue(
            AppConfig.fromSettings(settings, token: '', deviceKey: 'dev-1'),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: kTestLocalizationsDelegates,
          supportedLocales: kTestSupportedLocales,
          theme: buildUepTheme(Brightness.dark),
          home: Scaffold(
            body: Consumer(builder: (context, ref, _) {
              final width = ref
                  .watch(appConfigProvider.select((c) => c.leftPaneWidth));
              return Row(children: [
                SizedBox(
                    key: const Key('left-pane'),
                    width: width,
                    child: const SizedBox.expand()),
                PaneDivider(
                  tooltip: '拖曳調整寬度',
                  onDelta: (dx) => ref
                      .read(appConfigProvider.notifier)
                      .setLeftPaneWidth(width + dx),
                  onReset: () => ref
                      .read(appConfigProvider.notifier)
                      .setLeftPaneWidth(kLeftPaneDefaultWidth),
                ),
                const Expanded(child: SizedBox.expand()),
              ]);
            }),
          ),
        ),
      );

  double drawnWidth(WidgetTester tester) =>
      tester.getSize(find.byKey(const Key('left-pane'))).width;

  testWidgets('拖曳讓寬度跟著改，並且落盤', (tester) async {
    await tester.pumpWidget(harness());
    expect(drawnWidth(tester), kLeftPaneDefaultWidth);

    await tester.drag(find.byType(PaneDivider), const Offset(60, 0));
    await tester.pumpAndSettle();

    // 手勢起步要先走掉一段 slop（kDragSlopDefault = 20），之後的位移才
    // 算進寬度——真的用滑鼠拖也是這樣，不是誤差
    const expected = kLeftPaneDefaultWidth + 60 - kDragSlopDefault;
    expect(drawnWidth(tester), expected);
    expect(settings.leftPaneWidth, expected,
        reason: '拖完沒落盤的話，下次開 App 又回到預設');
  });

  testWidgets('往左拖變窄，最多到下限', (tester) async {
    await tester.pumpWidget(harness());

    await tester.drag(find.byType(PaneDivider), const Offset(-500, 0));
    await tester.pumpAndSettle();

    expect(drawnWidth(tester), kLeftPaneMinWidth);
    expect(settings.leftPaneWidth, kLeftPaneMinWidth);
  });

  testWidgets('往右拖最多到上限', (tester) async {
    await tester.pumpWidget(harness());

    await tester.drag(find.byType(PaneDivider), const Offset(1000, 0));
    await tester.pumpAndSettle();

    expect(drawnWidth(tester), kLeftPaneMaxWidth);
    expect(settings.leftPaneWidth, kLeftPaneMaxWidth);
  });

  testWidgets('雙擊回預設寬', (tester) async {
    await settings.setLeftPaneWidth(440);
    await tester.pumpWidget(harness());
    expect(drawnWidth(tester), 440);

    await tester.tap(find.byType(PaneDivider));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byType(PaneDivider));
    await tester.pumpAndSettle();

    expect(drawnWidth(tester), kLeftPaneDefaultWidth);
    expect(settings.leftPaneWidth, kLeftPaneDefaultWidth);
  });

  testWidgets('游標在分隔線上是左右箭頭', (tester) async {
    await tester.pumpWidget(harness());

    final region = tester.widget<MouseRegion>(find.descendant(
      of: find.byType(PaneDivider),
      matching: find.byType(MouseRegion),
    ).first);
    expect(region.cursor, SystemMouseCursors.resizeLeftRight);
  });
}
