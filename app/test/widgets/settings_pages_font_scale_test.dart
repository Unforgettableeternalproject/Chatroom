import 'package:chatroom_app/api/board_api.dart';
import 'package:chatroom_app/api/rooms_api.dart';
import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/models/board_contributions.dart';
import 'package:chatroom_app/models/participant.dart';
import 'package:chatroom_app/models/room.dart';
import 'package:chatroom_app/screens/board/board_settings_screen.dart';
import 'package:chatroom_app/screens/rooms/room_settings_screen.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:chatroom_app/state/rooms_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/l10n.dart';

/// 任務板設定與房間設定兩頁的字級與版面（艾斯維爾 2026-09-24：「字太小、
/// 不跟字級設定走；每人統計的名字和件數黏在一起；紀錄無限撐高頁面」）。
///
/// **App 字級設定的每一檔都跑**（[FontScalePref.values]，縮放倍率取自
/// [fontScaleFactor]，與 `app.dart` 套在 MediaQuery 上的是同一個值）。

const _config = AppConfig(
  serverUrl: 'http://test',
  token: 'token',
  themeMode: ThemeModePref.dark,
  preferredName: 'Bernie',
  deviceKey: 'device-key',
);

const _longName = '去澳洲留學的超級長名字的那一位代理人-很長很長很長';

ContributionEntry _entry(int i) => ContributionEntry.fromJson({
      'at': DateTime.now()
          .toUtc()
          .subtract(Duration(minutes: i + 1))
          .toIso8601String(),
      'action': i.isEven ? 'task_created' : 'task_done',
      'actor_key': 'k$i',
      'actor_name': '成員$i',
      'actor_kind': 'claude',
      'item_kind': 'task',
      'item_id': 't$i',
      'title': '第 $i 張卡：一個不算短的標題，字級放大時要能換行',
      'derived': i % 7 == 0,
    });

BoardContributions _page(int offset, int count,
        {required int total, required bool hasMore}) =>
    BoardContributions.fromJson({
      'board_id': 'b1',
      'board': {
        'name': 'JSAI 開發旅途',
        'description': '',
        'status': 'active',
        'my_role': 'owner',
        'owner_name': 'Bernie',
      },
      'entries': [
        for (var i = offset; i < offset + count; i++) _entry(i).toJsonForTest(),
      ],
      'total': total,
      'has_more': hasMore,
      'stats': [
        {
          'actor_key': 'h1',
          'actor_name': '馬克思',
          'actor_kind': 'human',
          'total': 7,
          'counts': {
            'checklist_created': 2,
            'checklist_done': 1,
            'objective_review': 1,
            'objective_reopened': 1,
            'task_done': 1,
            'objective_created': 1,
          },
          'last_at': '2026-09-24T00:00:00+00:00',
        },
        {
          'actor_key': 'a1',
          'actor_name': _longName,
          'actor_kind': 'claude',
          'total': 2,
          'counts': {'task_created': 1, 'task_done': 1},
          'last_at': '2026-09-24T00:00:00+00:00',
        },
      ],
    });

extension on ContributionEntry {
  Map<String, dynamic> toJsonForTest() => {
        'at': at,
        'action': action,
        'actor_name': actorName,
        'actor_kind': actorKind,
        'item_kind': itemKind,
        'item_id': itemId,
        'title': title,
        'derived': derived,
      };
}

/// 兩頁：第一頁 50 筆、還有；第二頁 10 筆、沒了。
class _FakeBoardsApi extends BoardsApi {
  _FakeBoardsApi() : super(Dio());

  final List<int> offsets = [];

  @override
  Future<BoardContributions> contributions(
    String boardId, {
    required String sessionKey,
    int limit = 50,
    int offset = 0,
  }) async {
    offsets.add(offset);
    return offset == 0
        ? _page(0, 50, total: 60, hasMore: true)
        : _page(offset, 10, total: 60, hasMore: false);
  }
}

Widget _scaled(FontScalePref pref, Widget home, List<Override> overrides) =>
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: kTestSupportedLocales,
        locale: kTestLocale,
        theme: buildUepTheme(Brightness.dark),
        // 與 app.dart 同一種套法：整個換掉 textScaler
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(fontScaleFactor(pref))),
          child: child!,
        ),
        home: home,
      ),
    );

Future<List<Override>> _base() async {
  SharedPreferences.setMockInitialValues({'chatroom.participant.r1': 'p-me'});
  final settings = SettingsRepository(await SharedPreferences.getInstance());
  return [
    settingsRepoProvider.overrideWithValue(settings),
    initialConfigProvider.overrideWithValue(_config),
  ];
}

void _setView(WidgetTester tester, double width) {
  tester.view.physicalSize = Size(width, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

double _fontSize(WidgetTester tester, Finder f) =>
    tester.widget<Text>(f).style!.fontSize!;

/// 畫面上實際的字級：樣式字級乘上這段文字吃到的 textScaler。
double _rendered(WidgetTester tester, Finder f) {
  final p = tester.renderObject<RenderParagraph>(
      find.descendant(of: f, matching: find.byType(RichText)).first);
  return p.textScaler.scale(_fontSize(tester, f));
}

/// 區段標題對「選項標題」（私人對話、每人統計那一級，sans 13.5）的比值。
/// 下限 1.1：再小就跟選項分不出層級；上限 1.5：pageTitle（26／13.5≈1.93）
/// 那種頁面級大標會把同頁的選項與按鈕襯得過小（艾斯維爾 2026-09-24 截圖）。
const _minSectionRatio = 1.1;
const _maxSectionRatio = 1.5;

void _expectBalanced(WidgetTester tester, FontScalePref pref,
    {required Finder section,
    required Finder option,
    required Finder button,
    required Finder hint}) {
  final ratio = _rendered(tester, section) / _rendered(tester, option);
  expect(ratio, inInclusiveRange(_minSectionRatio, _maxSectionRatio),
      reason: '$pref: 區段標題／選項標題 = $ratio');
  expect(_rendered(tester, button),
      greaterThanOrEqualTo(_rendered(tester, hint)),
      reason: '$pref: 按鈕文字不小於選項說明');
}

void main() {
  group('任務板設定頁', () {
    for (final width in [900.0, 560.0]) {
      testWidgets('每一檔字級（寬 $width）：不溢出、標題不小於內文、統計不重疊、'
          '紀錄區塊高度固定', (tester) async {
        _setView(tester, width);
        final base = await _base();
        final heights = <double>[];
        for (final pref in FontScalePref.values) {
          await tester.pumpWidget(_scaled(
            pref,
            const BoardSettingsScreen(boardId: 'b1'),
            [...base, boardsApiProvider.overrideWithValue(_FakeBoardsApi())],
          ));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$pref');

          // 區段標題 ≥ 內文與欄位標籤
          final title = find.text('貢獻紀錄');
          final detail = find.text('建立卡片 1 · 完成卡片 1');
          expect(_fontSize(tester, title),
              greaterThanOrEqualTo(_fontSize(tester, detail)));
          expect(_fontSize(tester, find.text('每人統計')),
              greaterThanOrEqualTo(_fontSize(tester, detail)));
          expect(_fontSize(tester, find.text('名稱')),
              greaterThanOrEqualTo(12));
          _expectBalanced(tester, pref,
              section: title,
              option: find.text('每人統計'),
              // 這頁沒有選項說明，拿同級的欄位標籤（fieldLabel 12）當下限
              button: find.text('儲存'),
              hint: find.text('名稱'));
          heights.add(tester.getSize(title).height);

          // 名字（省略號）與件數不重疊，件數也不壓到明細
          final name = tester.getRect(find.text(_longName));
          final count = tester.getRect(find.text('2 件'));
          final details = tester.getRect(detail);
          expect(name.overlaps(count), isFalse,
              reason: '$pref: $name vs $count');
          expect(count.overlaps(details), isFalse,
              reason: '$pref: $count vs $details');
          expect(count.left, greaterThanOrEqualTo(name.right));
          // 件數欄靠右對齊：兩列的右緣一致
          expect(tester.getRect(find.text('7 件')).right,
              moreOrLessEquals(count.right, epsilon: 0.5));

          // 紀錄在固定高度的區塊裡，不隨 50 筆撐高頁面
          expect(
              tester
                  .getSize(find.byKey(const ValueKey('board-contrib-log')))
                  .height,
              kContributionLogHeight);
        }
        // 字級設定真的有作用：每一檔都比前一檔大
        for (var i = 1; i < heights.length; i++) {
          expect(heights[i], greaterThan(heights[i - 1]),
              reason: '${FontScalePref.values[i]}');
        }
      });
    }

    testWidgets('捲到紀錄底部才載下一頁；has_more=false 之後不再請求',
        (tester) async {
      _setView(tester, 900);
      final base = await _base();
      final api = _FakeBoardsApi();
      await tester.pumpWidget(_scaled(
        FontScalePref.medium,
        const BoardSettingsScreen(boardId: 'b1'),
        [...base, boardsApiProvider.overrideWithValue(api)],
      ));
      await tester.pumpAndSettle();
      // 一次只拉一頁，不是全部
      expect(api.offsets, [0]);
      expect(find.textContaining('成員55'), findsNothing);

      final log = find.descendant(
          of: find.byKey(const ValueKey('board-contrib-log')),
          matching: find.byType(Scrollable));
      await tester.drag(log, const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(api.offsets, [0]);

      await tester.fling(log, const Offset(0, -20000), 5000);
      await tester.pumpAndSettle();
      expect(api.offsets, [0, 50]);

      await tester.fling(log, const Offset(0, -20000), 5000);
      await tester.pumpAndSettle();
      expect(find.textContaining('成員59'), findsOneWidget);
      expect(api.offsets, [0, 50]);
    });
  });

  group('房間設定頁', () {
    RoomDetail detail() => RoomDetail(
          room: Room.fromJson({
            'id': 'r1',
            'name': '房',
            'topic': '',
            'status': 'active',
            'created_at': '2026-09-23T00:00:00+00:00',
            'you_are_admin': true,
          }),
          youAreAdmin: true,
          participants: [
            Participant.fromJson({
              'id': 'p-me',
              'kind': 'human',
              'display_name': 'Me',
              'role': 'human',
              'status': 'active',
              'joined_at': '2026-09-23T00:00:00+00:00',
            }),
          ],
        );

    for (final width in [900.0, 560.0]) {
      testWidgets('每一檔字級（寬 $width）：不溢出、區段標題不小於內文',
          (tester) async {
        _setView(tester, width);
        final base = await _base();
        final heights = <double>[];
        for (final pref in FontScalePref.values) {
          await tester.pumpWidget(_scaled(
            pref,
            const RoomSettingsScreen(roomId: 'r1'),
            [
              ...base,
              roomDetailProvider('r1').overrideWith((ref) async => detail()),
              boardProvider('r1')
                  .overrideWith((ref) async => const BoardSnapshot(boardId: 'b1')),
            ],
          ));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$pref');

          // 按鈕上也是「封存」：第一個是區段標題
          final section = find.text('封存').first;
          final hint = find.text('必須受邀才能加入');
          expect(_fontSize(tester, section),
              greaterThanOrEqualTo(_fontSize(tester, hint)));
          expect(_fontSize(tester, find.text('私人對話')),
              greaterThanOrEqualTo(_fontSize(tester, hint)));
          expect(_fontSize(tester, find.text('說話方式')),
              greaterThanOrEqualTo(12));
          for (final button in [
            find.text('儲存'),
            find.text('更換任務板…'),
            find.text('封存').last,
          ]) {
            _expectBalanced(tester, pref,
                section: section,
                option: find.text('私人對話'),
                button: button,
                hint: hint);
          }
          heights.add(tester.getSize(section).height);
        }
        for (var i = 1; i < heights.length; i++) {
          expect(heights[i], greaterThan(heights[i - 1]),
              reason: '${FontScalePref.values[i]}');
        }
      });
    }
  });
}
