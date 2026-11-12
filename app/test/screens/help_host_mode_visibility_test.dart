import 'package:chatroom_app/api/rooms_api.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/l10n/l10n.dart';
import 'package:chatroom_app/screens/help/help_screen.dart';
import 'package:chatroom_app/state/rooms_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../helpers/l10n.dart';

/// 說明頁的「主持人模式」一節，只在主持人模式開關會出現時才有。
/// 條件與房間列表的開關相同（`RoomListResult.youAreHost`），這裡走真的
/// roomListProvider，不直接蓋掉判斷用的 provider。

Widget _app({required bool youAreHost}) => ProviderScope(
      overrides: [
        roomListProvider.overrideWith((ref, status) async =>
            RoomListResult(rooms: const [], youAreHost: youAreHost)),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(routes: [
          GoRoute(
              path: '/',
              builder: (_, _) => const HelpScreen(topic: HelpTopic.main)),
        ]),
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: const [Locale('zh', 'TW')],
        locale: kTestLocale,
        theme: buildUepTheme(Brightness.dark),
      ),
    );

void main() {
  final l10n = lookupAppLocalizations(kTestLocale);

  testWidgets('持主 token：有主持人模式說明與導覽項', (tester) async {
    tester.view.physicalSize = const Size(1200, 40000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(youAreHost: true));
    await tester.pumpAndSettle();
    // 導覽一筆＋內文標題一筆
    expect(find.text(l10n.helpSecModTitle), findsNWidgets(2));
    expect(find.text(l10n.helpMod1), findsOneWidget);
  });

  testWidgets('不是主 token：整段（含導覽項）都不顯示', (tester) async {
    tester.view.physicalSize = const Size(1200, 40000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(youAreHost: false));
    await tester.pumpAndSettle();
    expect(find.text(l10n.helpSecModTitle), findsNothing);
    expect(find.text(l10n.helpMod1), findsNothing);
    // 其他節仍在
    expect(find.text(l10n.helpSecNotifyTitle), findsWidgets);
  });
}
