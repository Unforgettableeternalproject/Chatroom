import 'package:chatroom_app/core/config/build_info.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/widgets/version_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/l10n.dart';

/// 橫幅要講的是**下一步做什麼**：哪一邊舊、去更新哪一邊。
/// commit hash 回答不了那一題，所以它不在橫幅上（只留在 tooltip）。
BuildInfo _appBuild(String builtAt) => BuildInfo(
      version: '1.2.3',
      commit: 'fb150bdccc11',
      builtAt: builtAt,
    );

Widget _host({
  required String appBuiltAt,
  Map<String, dynamic>? hubBuild,
}) =>
    ProviderScope(
      overrides: [
        appBuildProvider.overrideWithValue(_appBuild(appBuiltAt)),
        hubBuildProvider.overrideWith((ref) async => hubBuild),
      ],
      child: MaterialApp(
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: kTestSupportedLocales,
        theme: buildUepTheme(Brightness.dark),
        home: const Scaffold(body: VersionBanner()),
      ),
    );

String _allText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .join(' | ');

void main() {
  testWidgets('App 的建置時間比較早時，叫人更新 App', (tester) async {
    await tester.pumpWidget(_host(
      appBuiltAt: '2026-09-01T00:00:00Z',
      hubBuild: {
        'version': '1.2.3',
        'commit': 'f9d4322aaa22',
        'built_at': '2026-09-10T00:00:00Z',
      },
    ));
    await tester.pumpAndSettle();

    final text = _allText(tester);
    expect(text, contains('App 版本較舊，請更新 App'));
    // 🔴 hash 不上橫幅
    expect(text, isNot(contains('fb150bd')));
    expect(text, isNot(contains('f9d4322')));
  });

  testWidgets('Hub 的建置時間比較早時，叫人更新 Hub', (tester) async {
    await tester.pumpWidget(_host(
      appBuiltAt: '2026-09-10T00:00:00Z',
      hubBuild: {
        'version': '1.2.3',
        'commit': 'f9d4322aaa22',
        'built_at': '2026-09-01T00:00:00Z',
      },
    ));
    await tester.pumpAndSettle();

    expect(_allText(tester), contains('Hub 版本較舊，請更新 Hub'));
  });

  testWidgets('比不出建置時間時只說無法確認', (tester) async {
    // 舊版 Hub 不回 build，或根本連不上——那不是「相符」
    await tester.pumpWidget(_host(appBuiltAt: '2026-09-10T00:00:00Z'));
    await tester.pumpAndSettle();

    expect(_allText(tester), contains('無法確認版本'));
  });

  testWidgets('對不上但兩邊建置時間一樣，也只說無法確認', (tester) async {
    await tester.pumpWidget(_host(
      appBuiltAt: '2026-09-10T00:00:00Z',
      hubBuild: {
        'version': '1.2.3',
        'commit': 'f9d4322aaa22',
        'built_at': '2026-09-10T00:00:00Z',
      },
    ));
    await tester.pumpAndSettle();

    expect(_allText(tester), contains('無法確認版本'));
  });

  testWidgets('相符時完全不畫', (tester) async {
    await tester.pumpWidget(_host(
      appBuiltAt: '2026-09-10T00:00:00Z',
      hubBuild: {'version': '1.2.3', 'commit': 'fb150bd'},
    ));
    await tester.pumpAndSettle();

    expect(find.byType(Text), findsNothing);
  });
}
