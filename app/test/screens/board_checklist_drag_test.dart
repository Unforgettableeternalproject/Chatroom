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

/// 階段長按拖到其他週期：可拖條件、落點條件、API body、錯誤碼對應。
BoardChecklist _stage(String id, String objectiveId,
        {String title = '階段', String status = 'open'}) =>
    BoardChecklist(
        id: id,
        roomId: '',
        objectiveId: objectiveId,
        title: title,
        boardSeq: 1,
        status: status);

BoardObjective _obj(String id, String status, {String title = '週期'}) =>
    BoardObjective(id: id, roomId: '', title: title, boardSeq: 1, status: status);

BoardSnapshot _snap() => const BoardSnapshot().merge(BoardDelta.fromJson({
      'board_seq': 10,
      'full': true,
      'board_id': 'b1',
      'my_role': 'editor',
      'objectives': [
        {'id': 'o1', 'title': '來源週期', 'status': 'active', 'order_index': 0},
        {'id': 'o2', 'title': '目的週期', 'status': 'active', 'order_index': 1},
        {'id': 'o3', 'title': '審核中週期', 'status': 'review', 'order_index': 2},
      ],
      'checklists': [
        {'id': 'c1', 'objective_id': 'o1', 'title': '要搬的階段', 'status': 'open'},
        {
          'id': 'cu',
          'objective_id': 'o1',
          'title': kUncategorisedTitle,
          'status': 'open'
        },
      ],
      'tasks': const [],
    }));

void main() {
  group('可拖／落點條件', () {
    test('未分類、已刪除、凍結週期的階段不可拖', () {
      final active = _obj('o1', 'active');
      expect(canDragChecklist(_stage('c', 'o1'), active), isTrue);
      expect(
          canDragChecklist(_stage('c', 'o1', title: kUncategorisedTitle), active),
          isFalse);
      for (final st in ['review', 'verified', 'done', 'cancelled']) {
        expect(canDragChecklist(_stage('c', 'o1'), _obj('o1', st)), isFalse,
            reason: st);
      }
    });

    test('只能落在 active 且非原週期的週期；review 收卡但不收階段', () {
      final c = _stage('c', 'o1');
      expect(canMoveChecklistInto(c, _obj('o2', 'active')), isTrue);
      expect(canMoveChecklistInto(c, _obj('o1', 'active')), isFalse);
      for (final st in ['review', 'verified', 'done', 'cancelled']) {
        expect(canMoveChecklistInto(c, _obj('o2', st)), isFalse, reason: st);
      }
    });
  });

  test('moveChecklist：POST /checklists/{id}/move，body 只有 objective_id', () async {
    String? path;
    dynamic body;
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
      path = o.path;
      body = o.data;
      h.resolve(Response(requestOptions: o, data: <String, dynamic>{}));
    }));
    await BoardApi(dio)
        .moveChecklist('c1', sessionKey: 'k', objectiveId: 'o2');
    expect(path, '/api/board/checklists/c1/move');
    expect(body, {'objective_id': 'o2'});
  });

  testWidgets('🔴 搬階段的錯誤碼：用 code 對應短字', (tester) async {
    const cases = {
      'checklist_has_active_run': '派工進行中，先等它結束。',
      'checklist_uncategorised_immovable': '「未分類」不能移動。',
      'objective_closed': '週期已收尾，先打回才能改動。',
      'move_same_objective': '階段已經在這個週期了。',
      'move_cross_board': '不能移到其他看板的週期。',
    };
    for (final e in cases.entries) {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(MaterialApp(
        locale: kTestLocale,
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: kTestSupportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (c) => TextButton(
              onPressed: () => runBoardAction<void>(c,
                  () async => throw ConflictException(e.key, 'server text')),
              child: const Text('點'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('點'));
      await tester.pump();
      expect(find.text(e.value), findsOneWidget, reason: e.key);
      expect(find.text('server text'), findsNothing);
    }
  });

  group('畫面', () {
    late List<RequestOptions> sent;
    late DioException? failWith;

    Widget app() {
      final dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        sent.add(o);
        final f = failWith;
        if (f != null) {
          h.reject(DioException(requestOptions: o, response: f.response));
        } else {
          h.resolve(Response(requestOptions: o, data: <String, dynamic>{}));
        }
      }));
      return ProviderScope(
        overrides: [
          initialConfigProvider.overrideWithValue(kTestInitialConfig),
          boardByIdProvider('b1').overrideWith((ref) async => _snap()),
          boardApiProvider.overrideWithValue(BoardApi(dio)),
        ],
        child: MaterialApp(
          locale: kTestLocale,
          localizationsDelegates: kTestLocalizationsDelegates,
          supportedLocales: kTestSupportedLocales,
          theme: buildUepTheme(Brightness.dark),
          home: const BoardScreen(boardId: 'b1'),
        ),
      );
    }

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      sent = [];
      failWith = null;
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
    }

    Future<void> longPressDrag(
        WidgetTester tester, Finder from, Finder to) async {
      final g = await tester.startGesture(tester.getCenter(from));
      await tester.pump(const Duration(milliseconds: 400));
      await g.moveTo(tester.getCenter(to));
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
    }

    testWidgets('一般階段可長按拖、未分類不可拖', (tester) async {
      await pump(tester);
      expect(find.byType(LongPressDraggable<BoardChecklist>), findsWidgets);
      // 只有「要搬的階段」有拖曳源（標題＋可能的把手）；未分類沒有
      final dragTitles = find.descendant(
          of: find.byType(LongPressDraggable<BoardChecklist>),
          matching: find.text('要搬的階段'));
      expect(dragTitles, findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(LongPressDraggable<BoardChecklist>),
              matching: find.text(kUncategorisedTitle)),
          findsNothing);
    });

    testWidgets('🔴 拖到 active 的其他週期：打 move、body 帶 objective_id、顯示成功字',
        (tester) async {
      await pump(tester);
      await longPressDrag(
          tester,
          find.descendant(
              of: find.byType(LongPressDraggable<BoardChecklist>),
              matching: find.text('要搬的階段')),
          find.text('目的週期'));
      expect(sent.map((o) => o.path),
          contains('/api/board/checklists/c1/move'));
      final req =
          sent.firstWhere((o) => o.path == '/api/board/checklists/c1/move');
      expect(req.data, {'objective_id': 'o2'});
      expect(find.text('已移到〈目的週期〉'), findsOneWidget);
    });

    testWidgets('🔴 拖到 review 的週期或原週期：不接受、不打 API', (tester) async {
      await pump(tester);
      final from = find.descendant(
          of: find.byType(LongPressDraggable<BoardChecklist>),
          matching: find.text('要搬的階段'));
      await longPressDrag(tester, from, find.text('審核中週期'));
      await longPressDrag(tester, from, find.text('來源週期').first);
      expect(sent.where((o) => o.path.endsWith('/move')), isEmpty);
    });

    testWidgets('Hub 擋下（checklist_has_active_run）：顯示短訊息、不顯示成功字',
        (tester) async {
      await pump(tester);
      failWith = DioException(
        requestOptions: RequestOptions(),
        response: Response(
          requestOptions: RequestOptions(),
          statusCode: 409,
          data: {
            'detail': {'code': 'checklist_has_active_run', 'message': 'x'}
          },
        ),
      );
      await longPressDrag(
          tester,
          find.descendant(
              of: find.byType(LongPressDraggable<BoardChecklist>),
              matching: find.text('要搬的階段')),
          find.text('目的週期'));
      expect(find.text('派工進行中，先等它結束。'), findsOneWidget);
      expect(find.text('已移到〈目的週期〉'), findsNothing);
    });
  });
}
