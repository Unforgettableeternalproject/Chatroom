import 'package:chatroom_app/core/config/build_info.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/widgets/version_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 橫幅要印出**兩邊**的 commit。
///
/// 只印自己那一半的話，看到的人知道「對不上」卻答不出「哪一邊舊」——而那
/// 才是決定下一步（重新 build App？還是 Hub 沒更新）的依據。
const _appBuild =
    BuildInfo(version: '1.2.3', commit: 'fb150bdccc11', builtAt: '');

Widget _host({Map<String, dynamic>? hubBuild}) => ProviderScope(
      overrides: [
        appBuildProvider.overrideWithValue(_appBuild),
        hubBuildProvider.overrideWith((ref) async => hubBuild),
      ],
      child: MaterialApp(
        theme: buildUepTheme(Brightness.dark),
        home: const Scaffold(body: VersionBanner()),
      ),
    );

/// 畫面上所有文字接成一串——訊息本文與右側 mono 是兩個 Text，
/// 要驗的是「看得到嗎」，不是「在哪一個 widget 裡」。
String _allText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .join(' | ');

void main() {
  testWidgets('🔴 對不上時兩邊的 commit 都要印出來', (tester) async {
    await tester.pumpWidget(_host(
      hubBuild: {'version': '1.2.3', 'commit': 'f9d4322aaa22'},
    ));
    await tester.pumpAndSettle();

    final text = _allText(tester);
    expect(text, contains('fb150bd'), reason: 'App 這邊的 commit 不見了');
    expect(text, contains('f9d4322'),
        reason: '只印 App 自己那一半，看的人答不出哪一邊舊');
    expect(text, contains('通常是 App 還沒換新版'));
  });

  testWidgets('⚠️ Hub 講不出自己是哪一份時印「未知」', (tester) async {
    // 舊版 Hub 不回 build，或根本連不上——那不是「相符」
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    final text = _allText(tester);
    expect(text, contains('fb150bd'));
    expect(text, contains('Hub 未知'));
    expect(text, contains('無法確認'));
  });

  testWidgets('相符時完全不畫', (tester) async {
    await tester.pumpWidget(_host(
      hubBuild: {'version': '1.2.3', 'commit': 'fb150bd'},
    ));
    await tester.pumpAndSettle();

    expect(find.byType(Text), findsNothing);
  });
}
