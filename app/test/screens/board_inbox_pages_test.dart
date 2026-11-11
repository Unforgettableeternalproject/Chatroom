import 'package:chatroom_app/api/board_api.dart';
import 'package:chatroom_app/core/errors/api_exception.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/screens/board/board_action_feedback.dart';
import 'package:chatroom_app/screens/board/board_screen.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/app_config.dart';
import '../helpers/l10n.dart';

/// 「未分類」以分頁運作：每一頁是一個 `kind == 'inbox'` 的週期，同一時間
/// 只有一頁使用中，其餘是已完成的歷史頁。

Map<String, dynamic> _inbox(String id, String status,
        {int pageNo = 1, String? completedAt, int order = 0}) =>
    {
      'id': id,
      'title': '未分類',
      'kind': 'inbox',
      'page_no': pageNo,
      'status': status,
      'order_index': order,
      'completed_at': ?completedAt,
    };

/// 兩頁歷史（page_no 1 與 3，第 2 頁被拆走了）＋ 使用中的第 4 頁。
BoardSnapshot _snap({List<Map<String, dynamic>> extraObjectives = const []}) =>
    const BoardSnapshot().merge(BoardDelta.fromJson({
      'board_seq': 10,
      'full': true,
      'board_id': 'b1',
      'my_role': 'editor',
      'objectives': [
        {'id': 'o1', 'title': 'Alpha', 'status': 'active', 'order_index': 0},
        {'id': 'o2', 'title': '舊的週期', 'status': 'done', 'order_index': 1},
        _inbox('i3', 'active', pageNo: 4, order: 2),
        // 刻意把較晚完成的排在前面：順序號要依完成時間，不是陣列或 page_no
        _inbox('i2', 'done',
            pageNo: 3, completedAt: '2026-11-10T11:00:00Z', order: 3),
        _inbox('i1', 'done',
            pageNo: 1, completedAt: '2026-11-08T11:00:00Z', order: 4),
        ...extraObjectives,
      ],
      'checklists': [
        {'id': 'c3', 'objective_id': 'i3', 'title': '未分類', 'status': 'open'},
        {'id': 'c2', 'objective_id': 'i2', 'title': '未分類', 'status': 'done'},
        {'id': 'c1', 'objective_id': 'i1', 'title': '未分類', 'status': 'done'},
      ],
      'tasks': [
        {'id': 't3', 'checklist_id': 'c3', 'title': '目前頁的卡', 'status': 'todo'},
        {'id': 't2', 'checklist_id': 'c2', 'title': '第二頁的卡', 'status': 'done'},
        {'id': 't1', 'checklist_id': 'c1', 'title': '第一頁的卡', 'status': 'done'},
      ],
    }));

class _FakeBoardApi extends BoardApi {
  _FakeBoardApi() : super(Dio());

  final calls = <({String id, String title})>[];
  ApiException? error;

  @override
  Future<SplitInboxResult> splitInbox(String objectiveId,
      {String? participantId,
      String? sessionKey,
      required String title}) async {
    calls.add((id: objectiveId, title: title));
    final e = error;
    if (e != null) throw e;
    return const SplitInboxResult(
        objectiveId: 'o9', newInboxObjectiveId: 'i5');
  }
}

Widget _app(Widget child) => MaterialApp(
      locale: kTestLocale,
      localizationsDelegates: kTestLocalizationsDelegates,
      supportedLocales: kTestSupportedLocales,
      theme: buildUepTheme(Brightness.dark),
      home: child,
    );

Widget _wrap(BoardSnapshot Function() snap, {BoardApi? api}) => ProviderScope(
      overrides: [
        initialConfigProvider.overrideWithValue(kTestInitialConfig),
        boardByIdProvider('b1').overrideWith((ref) async => snap()),
        if (api != null) boardApiProvider.overrideWithValue(api),
      ],
      child: _app(const BoardScreen(boardId: 'b1')),
    );

void _wide(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _openInbox(WidgetTester tester) async {
  await tester.tap(find.text('未分類'));
  await tester.pumpAndSettle();
}

void main() {
  group('model', () {
    test('kind 為 inbox 才是未分類頁；page_no 照解', () {
      final o = BoardObjective.fromJson(_inbox('i', 'active', pageNo: 7));
      expect(o.isInbox, isTrue);
      expect(o.pageNo, 7);
    });

    test('新 Hub 明說 kind 為空字串：即使標題叫「未分類」也不是', () {
      final o = BoardObjective.fromJson(
          {'id': 'x', 'title': '未分類', 'kind': '', 'status': 'active'});
      expect(o.isInbox, isFalse);
    });

    test('舊 Hub 沒有 kind：退回標題判斷', () {
      final legacy = BoardObjective.fromJson(
          {'id': 'x', 'title': '未分類', 'status': 'active'});
      final normal = BoardObjective.fromJson(
          {'id': 'y', 'title': 'Alpha', 'status': 'active'});
      expect(legacy.kind, isNull);
      expect(legacy.isInbox, isTrue);
      expect(normal.isInbox, isFalse);
    });

    test('inbox 底下的未分類階段與 isUncategorised 一致', () {
      final snap = _snap();
      expect(snap.objectives['i3']!.isInbox, isTrue);
      expect(snap.checklistsOf('i3').single.isUncategorised, isTrue);
    });

    test('歷史頁依完成時間排，不依 page_no 或輸入順序', () {
      final snap = _snap();
      expect([for (final o in snap.inboxHistory) o.id], ['i1', 'i2']);
      expect(snap.currentInbox!.id, 'i3');
    });
  });

  group('左欄', () {
    testWidgets('未分類只出現一次，歷史頁不在已完成名單', (tester) async {
      _wide(tester);
      await tester.pumpWidget(_wrap(() => _snap()));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // 預設選的是 Alpha：整個畫面上的「未分類」只有左欄那一列
      expect(find.text('未分類'), findsOneWidget);
      // 已完成名單只有一般週期那一條
      expect(find.text('已完成 · 1'), findsOneWidget);
      expect(find.text('舊的週期'), findsOneWidget);
    });

    testWidgets('舊 Hub 無 kind：標題叫未分類的已完成週期同樣不進名單',
        (tester) async {
      _wide(tester);
      final snap = const BoardSnapshot().merge(BoardDelta.fromJson({
        'board_seq': 1,
        'full': true,
        'board_id': 'b1',
        'my_role': 'editor',
        'objectives': [
          {'id': 'o1', 'title': 'Alpha', 'status': 'active', 'order_index': 0},
          {'id': 'n1', 'title': '未分類', 'status': 'active', 'order_index': 1},
          {'id': 'n0', 'title': '未分類', 'status': 'done', 'order_index': 2},
        ],
      }));
      await tester.pumpWidget(_wrap(() => snap));
      await tester.pumpAndSettle();

      expect(find.text('未分類'), findsOneWidget);
      expect(find.textContaining('已完成 ·'), findsNothing);
    });

    testWidgets('窄版切換器的清單同樣只有一個未分類', (tester) async {
      tester.view.physicalSize = const Size(600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_wrap(() => _snap()));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('board-objective-switcher')));
      await tester.pumpAndSettle();

      expect(find.text('未分類'), findsOneWidget);
      expect(find.text('已完成 · 1'), findsOneWidget);
    });
  });

  group('頁面切換', () {
    testWidgets('列出目前與歷史頁：順序號依完成時間、附完成日期', (tester) async {
      _wide(tester);
      await tester.pumpWidget(_wrap(() => _snap()));
      await tester.pumpAndSettle();
      await _openInbox(tester);

      // 目前頁
      expect(find.text('目前頁的卡'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('inbox-page-switcher')));
      await tester.pumpAndSettle();

      // i1（page_no 1）最早完成 → 第 1 頁；i2（page_no 3）→ 第 2 頁
      expect(find.text('第 1 頁 · 11/08 完成'), findsOneWidget);
      expect(find.text('第 2 頁 · 11/10 完成'), findsOneWidget);
      expect(find.text('目前'), findsWidgets);
    });

    testWidgets('切到歷史頁顯示該頁自己的內容，且唯讀', (tester) async {
      _wide(tester);
      await tester.pumpWidget(_wrap(() => _snap()));
      await tester.pumpAndSettle();
      await _openInbox(tester);

      await tester.tap(find.byKey(const ValueKey('inbox-page-switcher')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第 2 頁 · 11/10 完成'));
      await tester.pumpAndSettle();

      expect(find.text('第二頁的卡'), findsOneWidget);
      expect(find.text('第一頁的卡'), findsNothing);
      expect(find.text('目前頁的卡'), findsNothing);
      expect(find.text('週期已完成，無法修改'), findsOneWidget);
      // 左欄仍亮著「未分類」那一列（只此一列）
      expect(find.text('未分類'), findsWidgets);
      expect(find.text('已完成 · 1'), findsOneWidget);

      // 切回目前
      await tester.tap(find.byKey(const ValueKey('inbox-page-switcher')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('目前').last);
      await tester.pumpAndSettle();
      expect(find.text('目前頁的卡'), findsOneWidget);
      expect(find.text('第二頁的卡'), findsNothing);
    });
  });

  group('未分類頁的週期操作', () {
    testWidgets('沒有取消週期，也沒有改名（編輯）入口', (tester) async {
      _wide(tester);
      await tester.pumpWidget(_wrap(() => _snap()));
      await tester.pumpAndSettle();
      await _openInbox(tester);

      expect(find.text('取消週期'), findsNothing);
      expect(find.text('編輯'), findsNothing);
      // 改名的入口是拆成獨立週期
      await tester.tap(find.byKey(const ValueKey('inbox-page-menu')));
      await tester.pumpAndSettle();
      expect(find.text('拆成獨立週期'), findsOneWidget);
    });

    testWidgets('一般週期照舊有編輯，也沒有頁面切換', (tester) async {
      _wide(tester);
      await tester.pumpWidget(_wrap(() => _snap()));
      await tester.pumpAndSettle();

      expect(find.text('編輯'), findsOneWidget);
      expect(find.byKey(const ValueKey('inbox-page-menu')), findsNothing);
      expect(find.byKey(const ValueKey('inbox-page-switcher')), findsNothing);
    });
  });

  group('拆成獨立週期', () {
    Future<void> openDialog(WidgetTester tester) async {
      await _openInbox(tester);
      await tester.tap(find.byKey(const ValueKey('inbox-page-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('拆成獨立週期'));
      await tester.pumpAndSettle();
    }

    testWidgets('名稱必填、不可為「未分類」，過了才送出 {title}，並選到新週期',
        (tester) async {
      _wide(tester);
      final api = _FakeBoardApi();
      var snap = _snap();
      await tester.pumpWidget(_wrap(() => snap, api: api));
      await tester.pumpAndSettle();
      await openDialog(tester);

      // 空白
      await tester.tap(find.text('拆出'));
      await tester.pumpAndSettle();
      expect(find.text('請填週期名稱。'), findsOneWidget);
      expect(api.calls, isEmpty);

      // 保留字
      await tester.enterText(
          find.byKey(const ValueKey('split-inbox-title')), ' 未分類 ');
      await tester.tap(find.text('拆出'));
      await tester.pumpAndSettle();
      expect(find.text('「未分類」是保留名稱，請換一個。'), findsOneWidget);
      expect(api.calls, isEmpty);

      // 合法：Hub 拆完後板上多了新週期（與補的新空白頁）
      snap = _snap(extraObjectives: [
        {'id': 'o9', 'title': '新週期', 'kind': '', 'status': 'active',
          'order_index': 9},
      ]);
      await tester.enterText(
          find.byKey(const ValueKey('split-inbox-title')), ' 新週期 ');
      await tester.tap(find.text('拆出'));
      await tester.pumpAndSettle();

      expect(api.calls, hasLength(1));
      expect(api.calls.single.id, 'i3');
      expect(api.calls.single.title, '新週期');
      // 選到拆出的新週期：抬頭是它，不再有頁面切換
      expect(find.text('新週期'), findsWidgets);
      expect(find.byKey(const ValueKey('inbox-page-menu')), findsNothing);
    });

    testWidgets('歷史頁也能拆', (tester) async {
      _wide(tester);
      final api = _FakeBoardApi();
      await tester.pumpWidget(_wrap(() => _snap(), api: api));
      await tester.pumpAndSettle();
      await _openInbox(tester);
      await tester.tap(find.byKey(const ValueKey('inbox-page-switcher')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第 1 頁 · 11/08 完成'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('inbox-page-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('拆成獨立週期'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('split-inbox-title')), '獨立出來');
      await tester.tap(find.text('拆出'));
      await tester.pumpAndSettle();

      expect(api.calls.single.id, 'i1');
      expect(api.calls.single.title, '獨立出來');
    });

    testWidgets('Hub 退回時用短訊息說話', (tester) async {
      _wide(tester);
      final api = _FakeBoardApi()
        ..error = const BoardAccessException(
            'not_inbox_page', 'hub raw message');
      await tester.pumpWidget(_wrap(() => _snap(), api: api));
      await tester.pumpAndSettle();
      await openDialog(tester);
      await tester.enterText(
          find.byKey(const ValueKey('split-inbox-title')), '甲');
      await tester.tap(find.text('拆出'));
      await tester.pumpAndSettle();

      expect(find.text('這個週期不是未分類頁。'), findsOneWidget);
      expect(find.text('hub raw message'), findsNothing);
    });
  });

  testWidgets('錯誤碼對應短訊息', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(_app(Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    })));
    String say(String code) =>
        boardActionMessage(ctx, BoardAccessException(code, '原話'));

    expect(say('not_inbox_page'), '這個週期不是未分類頁。');
    expect(say('inbox_title_reserved'), '「未分類」是保留名稱，請換一個。');
    expect(say('title_required'), '請填週期名稱。');
    expect(say('inbox_page_not_cancellable'), '未分類頁不能取消。');
    expect(say('inbox_rename_forbidden'), '未分類不能改名，請拆成獨立週期。');
    // 不認得的 code 仍用 Hub 的原話
    expect(say('something_else'), '原話');
  });
}
