import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/screens/chat/chat_screen.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/messages_providers.dart';
import 'package:chatroom_app/widgets/copyable_id.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/app_config.dart';
import '../helpers/l10n.dart';

const _roomId = 'fefb6ad6691749cf9c8cfa02b1bbcc6b';
const _roomName = '測試房間名稱';

/// 開發者模式下房 id 是次要資訊：窄視窗時房名必須保留，id 讓位。
Widget _wrap({required double width, bool dev = true}) => ProviderScope(
      overrides: [
        initialConfigProvider
            .overrideWithValue(kTestInitialConfig.copyWith(devMode: dev)),
        identityProvider(_roomId).overrideWith(
            (ref) async => (participantId: 'p1', displayName: '測試')),
      ],
      child: MaterialApp(
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: kTestSupportedLocales,
        locale: const Locale('zh', 'TW'),
        theme: buildUepTheme(Brightness.dark),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: const RoomHeader(
                roomId: _roomId,
                roomName: _roomName,
                topic: '',
                archived: false,
                pinnedCount: 0,
                memberCount: 2,
                showMembersButton: false,
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  Future<void> open(WidgetTester tester, double width, {bool dev = true}) async {
    await tester.pumpWidget(_wrap(width: width, dev: dev));
  }

  testWidgets('寬視窗：房名與完整 id 都在', (tester) async {
    await open(tester, 1400);
    expect(find.text(_roomName), findsOneWidget);
    expect(find.text(_roomId), findsOneWidget);
  });

  for (final w in [360.0, 480.0, 600.0]) {
    testWidgets('寬 $w：房名保留且完整、id 可縮短或隱藏', (tester) async {
      await open(tester, w);
      final name = find.text(_roomName);
      expect(name, findsOneWidget);
      // 房名沒被擠成零寬，也沒有溢出例外
      expect(tester.getSize(name).width, greaterThan(100));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('id 縮短時點擊仍複製完整 id', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    // 掃一段寬度：id 會從完整→縮短→消失，只要還畫著，點了就複製完整 id
    var sawShortened = false;
    for (var w = 520.0; w <= 900; w += 20) {
      await open(tester, w);
      expect(find.text(_roomName), findsOneWidget, reason: '寬 $w 房名要在');
      final id = find.text(_roomId);
      if (id.evaluate().isEmpty) continue;
      if (tester.getSize(id).width < 150) sawShortened = true;
      copied = null;
      await tester.tap(id);
      await tester.pump();
      expect(copied, _roomId, reason: '寬 $w 複製完整 id');
    }
    expect(sawShortened, isTrue);
  });

  testWidgets('開發者模式關：沒有 id', (tester) async {
    await open(tester, 480, dev: false);
    expect(find.text(_roomName), findsOneWidget);
    expect(find.text(_roomId), findsNothing);
  });

  testWidgets('開發者模式關：房名不加 maxLines，不改版面', (tester) async {
    await open(tester, 560, dev: false);
    final t = tester.widget<Text>(find.text(_roomName));
    expect(t.maxLines, isNull);
    expect(t.overflow, TextOverflow.ellipsis);
    // 沒有橫向捲動的按鈕列：維持原本的單列 Row
    expect(find.byType(SingleChildScrollView), findsNothing);
  });

  testWidgets('TitleWithId 關閉 id：標題 widget 與原本一致', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: TitleWithId(
          title: '很長很長的階段標題',
          titleStyle: TextStyle(fontSize: 15),
          id: 'abc',
          showId: false,
          plainOverflow: null,
        ),
      ),
    ));
    final t = tester.widget<Text>(find.text('很長很長的階段標題'));
    expect(t.maxLines, isNull);
    expect(t.overflow, isNull);
    expect(find.text('abc'), findsNothing);
  });
}
