import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/screens/boards/board_list_screen.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/app_config.dart';
import '../helpers/l10n.dart';

/// 板的封存已移除（2026-11-12）：清單只有「進行中」「已收尾」兩個分頁，
/// 「永久刪除」只出現在已收尾的板上。
Future<void> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsRepository(await SharedPreferences.getInstance());
  await tester.pumpWidget(ProviderScope(
    overrides: [
      settingsRepoProvider.overrideWithValue(settings),
      initialConfigProvider.overrideWithValue(kTestInitialConfig),
      boardLibraryProvider.overrideWith((ref, view) async => BoardListResult(
            boards: view == 'settled'
                ? const [
                    BoardSummary(
                        id: 'done',
                        name: '收尾的板',
                        myRole: 'owner',
                        outcome: 'completed'),
                  ]
                : const [
                    BoardSummary(id: 'live', name: '進行的板', myRole: 'owner'),
                  ],
          )),
    ],
    child: MaterialApp(
      locale: kTestLocale,
      localizationsDelegates: kTestLocalizationsDelegates,
      supportedLocales: kTestSupportedLocales,
      theme: buildUepTheme(Brightness.dark),
      home: const Scaffold(body: BoardListPane()),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('分頁只有進行中與已收尾，沒有已封存', (tester) async {
    await _pump(tester);
    expect(find.text('進行中'), findsOneWidget);
    expect(find.text('已收尾'), findsOneWidget);
    expect(find.text('已封存'), findsNothing);
  });

  testWidgets('進行中的板選單沒有永久刪除，也沒有封存', (tester) async {
    await _pump(tester);
    expect(find.text('進行的板'), findsOneWidget);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    expect(find.text('重新命名…'), findsOneWidget);
    expect(find.text('永久刪除…'), findsNothing);
    expect(find.text('封存'), findsNothing);
    expect(find.text('解除封存'), findsNothing);
  });

  testWidgets('已收尾的板選單有永久刪除，按下要二次確認', (tester) async {
    await _pump(tester);
    await tester.tap(find.text('已收尾'));
    await tester.pumpAndSettle();
    expect(find.text('收尾的板'), findsOneWidget);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    expect(find.text('永久刪除…'), findsOneWidget);
    await tester.tap(find.text('永久刪除…'));
    await tester.pumpAndSettle();

    // 確認 dialog：標題與取消／永久刪除兩顆按鈕；取消後板還在
    expect(find.text('永久刪除任務板？'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('永久刪除任務板？'), findsNothing);
    expect(find.text('收尾的板'), findsOneWidget);
  });
}
