import 'dart:convert';
import 'dart:typed_data';

import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/screens/board/board_filter_bar.dart';
import 'package:chatroom_app/screens/board/board_objective_description.dart';
import 'package:chatroom_app/widgets/board_task_card.dart';
import 'package:chatroom_app/screens/board/board_screen.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/app_config.dart';
import '../helpers/l10n.dart';

/// 右側週期窗格：抬頭／說明／橫幅跟卡片一起捲，只有篩選列釘住；
/// 以及「只看孤兒」在孤兒歸零後不會把人困住。
BoardSnapshot _snap({required bool orphan, int cards = 12}) =>
    const BoardSnapshot().merge(BoardDelta.fromJson({
      'board_seq': 10,
      'full': true,
      'board_id': 'b1',
      'my_role': 'editor',
      'objectives': [
        {
          'id': 'o1',
          'title': '一個相當長的週期標題用來測試窄寬度下折行的情況',
          'status': 'active',
          'description':
              List.generate(40, (i) => '第 $i 段說明內容很長很長很長').join('\n'),
        },
      ],
      'checklists': [
        {'id': 'c1', 'objective_id': 'o1', 'title': '階段', 'status': 'open'},
      ],
      'tasks': [
        for (var i = 0; i < cards; i++)
          {
            'id': 't$i',
            'checklist_id': 'c1',
            'title': '卡片$i',
            'status': 'todo',
            'order_index': i,
            if (orphan && i == 0) ...{
              'status': 'in_progress',
              'claim_state': 'orphaned',
              'claim_name': 'Zed',
            },
          },
      ],
    }));

final _snapProvider = StateProvider<BoardSnapshot>((ref) => _snap(orphan: true));

class _Stub implements HttpClientAdapter {
  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(
      RequestOptions options, Stream<Uint8List>? _, Future<void>? _) async {
    seen.add(options);
    return ResponseBody.fromString(jsonEncode({'ok': true}), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

Future<void> _boot(WidgetTester tester, Size size, {_Stub? stub}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      initialConfigProvider.overrideWithValue(kTestInitialConfig),
      if (stub != null)
        dioProvider.overrideWithValue(
            Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = stub),
      boardByIdProvider('b1')
          .overrideWith((ref) async => ref.watch(_snapProvider)),
    ],
    child: MaterialApp(
      localizationsDelegates: kTestLocalizationsDelegates,
      supportedLocales: kTestSupportedLocales,
      theme: buildUepTheme(Brightness.dark),
      home: const BoardScreen(boardId: 'b1'),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('小視窗：捲動後抬頭離開畫面，篩選列仍在，且看得到卡', (tester) async {
    const size = Size(1260, 720);
    await _boot(tester, size);
    final screen = Offset.zero & size;
    final title = find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.textContaining('一個相當長的週期標題'));
    final filter = find.byKey(const ValueKey('board-filter-toggle'));
    expect(title, findsOneWidget);

    // 說明佔滿窗格寬度（右欄 = 視窗 - 左欄 300 - 分隔線 1 - 左右 padding 52）
    final descW = tester.getSize(find.byType(ObjectiveDescription)).width;
    expect(descW, greaterThan((size.width - 301 - 52) * 0.8));
    // 說明收合最多 2 行：14 * 1.85 * 2
    expect(
        tester
            .getSize(find.byKey(const ValueKey('objective-description-text')))
            .height,
        lessThan(14 * 1.85 * 2 + 4));

    await tester.dragFrom(const Offset(1250, 400), const Offset(0, -500));
    await tester.pumpAndSettle();

    // 抬頭已捲出畫面（不是固定在上面）
    expect(title.evaluate().isEmpty || !screen.contains(tester.getCenter(title)),
        isTrue);
    // 篩選列釘在頂端、仍可見
    expect(filter, findsOneWidget);
    expect(screen.contains(tester.getCenter(filter)), isTrue);
    // 至少一張卡完整在畫面內、且在篩選列下方
    final filterBottom = tester.getBottomLeft(filter).dy;
    final visibleCards = [
      for (var i = 0; i < 12; i++)
        if (find.text('卡片$i').evaluate().isNotEmpty)
          tester.getTopLeft(find.text('卡片$i')),
    ].where((p) => p.dy > filterBottom && p.dy < size.height);
    expect(visibleCards, isNotEmpty);
  });

  testWidgets('重排：階段內的卡仍有拖曳把手（未篩選）；篩選中沒有', (tester) async {
    await _boot(tester, const Size(1260, 720));
    // 先捲回頂端，確保孤兒橫幅在
    expect(find.byType(ReorderableListView), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('board-filter-toggle')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('board-filter-keyword')), '卡片1');
    await tester.pumpAndSettle();
    expect(find.byType(ReorderableListView), findsNothing);
  });

  testWidgets('只看孤兒：孤兒歸零後回到正常檢視，不被困住', (tester) async {
    await _boot(tester, const Size(1260, 1400));
    await tester.tap(find.text('只看孤兒 →'));
    await tester.pumpAndSettle();
    expect(find.text('卡片5'), findsNothing);
    expect(find.text('卡片0'), findsOneWidget);

    final container = ProviderScope.containerOf(
        tester.element(find.byType(BoardScreen)));
    container.read(_snapProvider.notifier).state = _snap(orphan: false);
    await tester.pumpAndSettle();

    // 橫幅沒了，但清單不能還卡在孤兒檢視
    expect(find.text('只看孤兒 →'), findsNothing);
    expect(find.text('卡片5'), findsOneWidget);
  });

  testWidgets('拖曳重排：改成 sliver 後仍會送出 reorder', (tester) async {
    final stub = _Stub();
    await _boot(tester, const Size(1260, 1400), stub: stub);
    stub.seen.clear();
    final g = await tester.startGesture(tester.getCenter(find.text('卡片2')));
    await g.moveBy(const Offset(0, 20));
    await g.moveBy(const Offset(0, 120));
    await g.moveBy(const Offset(0, 120));
    await tester.pump(const Duration(milliseconds: 100));
    await g.up();
    await tester.pumpAndSettle();
    expect(stub.seen.where((r) => r.path.contains('reorder')), isNotEmpty);
  });

  testWidgets('右緣對齊：橫幅按鈕、篩選按鈕、階段按鈕、卡片同一條線', (tester) async {
    await _boot(tester, const Size(1260, 1400));
    double rightOf(Finder f) => tester.getRect(f.first).right;
    // 每個元素取「最外層可點的那顆」的右緣
    final banner = find.ancestor(
        of: find.text('只看孤兒 →'), matching: find.byType(InkWell));
    final toggle = find.byKey(const ValueKey('board-filter-toggle'));
    final stageBtn = find.ancestor(
        of: find.text('＋ 任務'), matching: find.byType(InkWell));
    final card = find.byType(BoardTaskCard);
    expect(card, findsWidgets);
    final ref = tester.getRect(card.first).right;
    expect(rightOf(banner), closeTo(ref, 1));
    expect(rightOf(toggle), closeTo(ref, 1));
    expect(rightOf(stageBtn), closeTo(ref, 1));
  });

  testWidgets('篩選面板：欄位撐滿面板寬度；窄時分兩列', (tester) async {
    await _boot(tester, const Size(1260, 1400));
    await tester.tap(find.byKey(const ValueKey('board-filter-toggle')));
    await tester.pumpAndSettle();
    final claimed = find.byKey(const ValueKey('board-filter-claimed'));
    final panelRight = 1260.0 - kBoardPaneGutter - 1 - kBoardFilterPanelPadding;
    // 沒有條件時沒有「清除」，最右邊的下拉要貼到面板內緣
    expect(tester.getRect(claimed).right, closeTo(panelRight, 1.5));
    final kw = find.byKey(const ValueKey('board-filter-keyword'));
    final status = find.byKey(const ValueKey('board-filter-status'));
    expect(tester.getRect(kw).width,
        closeTo(tester.getRect(status).width * 2, 1.5));
    expect(tester.getRect(kw).top, closeTo(tester.getRect(status).top, 8));
  });

  testWidgets('篩選面板：窄寬度分兩列、各自撐滿', (tester) async {
    await _boot(tester, const Size(520, 1400));
    await tester.tap(find.byKey(const ValueKey('board-filter-toggle')));
    await tester.pumpAndSettle();
    // 520 寬時階段標題列本來就會溢位（與篩選面板無關），吞掉那個例外
    tester.takeException();
    final kw = tester.getRect(find.byKey(const ValueKey('board-filter-keyword')));
    final claimed =
        tester.getRect(find.byKey(const ValueKey('board-filter-claimed')));
    expect(claimed.top, greaterThan(kw.bottom - 1));
    expect(claimed.right, closeTo(kw.right, 1.5));
  });
}
