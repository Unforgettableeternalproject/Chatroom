import 'package:chatroom_app/api/tokens_api.dart';
import 'package:chatroom_app/core/errors/api_exception.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/l10n/app_localizations.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/assignments_providers.dart';
import 'package:chatroom_app/widgets/invite_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

class _FakeTokensApi extends TokensApi {
  _FakeTokensApi() : super(Dio());

  final rotated = <String>[];

  @override
  Future<AccessToken> rotate(String token) async {
    rotated.add(token);
    throw const NetworkException();
  }
}

List<AccessToken> _tokens(int n, {String audience = 'human'}) => [
      for (var i = 0; i < n; i++)
        AccessToken(
          token: 'tok-$i',
          label: 'member-$i',
          audience: audience,
          createdAt: '2026-01-01T00:00:00Z',
        ),
    ];

Widget _host(List<AccessToken> tokens, _FakeTokensApi api) => ProviderScope(
      overrides: [
        tokensApiProvider.overrideWithValue(api),
        accessTokensProvider.overrideWith((ref) async => tokens),
      ],
      child: MaterialApp(
        theme: buildUepTheme(Brightness.dark),
        locale: const Locale('zh', 'TW'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 600, child: InviteManager()),
          ),
        ),
      ),
    );

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  final scrollKey = find.byKey(const ValueKey('invite-list-scroll'));

  testWidgets('4 筆以內維持自然高度，沒有捲動區塊', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(_tokens(4), _FakeTokensApi()));
    await tester.pumpAndSettle();
    expect(scrollKey, findsNothing);
    expect(find.text('member-3'), findsOneWidget);
    // 一列的實際高度要與捲動區塊假設的相符
    final step = tester.getCenter(find.text('member-1')).dy -
        tester.getCenter(find.text('member-0')).dy;
    expect(step, closeTo(inviteRowHeight, 2));
  });

  testWidgets('超過 4 筆時固定高度，滑鼠滾輪可捲到後面的列', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(_tokens(7), _FakeTokensApi()));
    await tester.pumpAndSettle();
    expect(scrollKey, findsOneWidget);
    expect(tester.getSize(scrollKey).height,
        inviteListMaxRows * inviteRowHeight);

    // 第 7 列在可視區外
    final viewport = tester.getRect(scrollKey);
    final last = find.text('member-6');
    expect(
        last.evaluate().isEmpty ||
            !viewport.contains(tester.getCenter(last)),
        isTrue);

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(viewport.center));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 600)));
    await tester.pumpAndSettle();
    expect(find.text('member-6'), findsOneWidget);
    expect(viewport.contains(tester.getCenter(find.text('member-6'))), isTrue);
  });

  testWidgets('重發憑證：先確認，取消不送；確認才送出', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = _FakeTokensApi();
    await tester.pumpWidget(_host(_tokens(2, audience: 'agent'), api));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('重發憑證').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('需要換上新憑證'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(api.rotated, isEmpty);

    await tester.tap(find.byTooltip('重發憑證').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(InkWell, '重發憑證').last);
    await tester.pumpAndSettle();
    expect(api.rotated, ['tok-0']);
  });
}
