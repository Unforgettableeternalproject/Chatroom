import 'dart:convert';
import 'dart:typed_data';

import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/screens/board/board_screen.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/l10n.dart';

/// 拖放搬卡：長按卡片拖到別的階段 ⇒ 走 `moveTask`（先建新卡、再把舊卡
/// 推成 moved）；不合法的落點什麼都不送。
class _Stub implements HttpClientAdapter {
  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(
      RequestOptions options, Stream<Uint8List>? _, Future<void>? _) async {
    seen.add(options);
    final body = options.path.endsWith('/tasks')
        ? {'ok': true, 'id': 'new1'}
        : {'ok': true};
    return ResponseBody.fromString(jsonEncode(body), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

final _snap = const BoardSnapshot().merge(BoardDelta.fromJson({
  'board_seq': 10,
  'full': true,
  'board_id': 'b1',
  'my_role': 'editor',
  'objectives': [
    {'id': 'o1', 'title': '第一個週期', 'status': 'active'},
    {'id': 'o2', 'title': '第二個週期', 'status': 'active'},
  ],
  'checklists': [
    {
      'id': 'c1',
      'objective_id': 'o1',
      'title': '甲階段',
      'status': 'open',
      'order_index': 0
    },
    {
      'id': 'c2',
      'objective_id': 'o1',
      'title': '乙階段',
      'status': 'open',
      'order_index': 1
    },
    {
      'id': 'c3',
      'objective_id': 'o1',
      'title': '丙階段',
      'status': 'done',
      'order_index': 2
    },
    {
      'id': 'c9',
      'objective_id': 'o2',
      'title': '外階段',
      'status': 'open',
      'order_index': 0
    },
  ],
  'tasks': [
    {'id': 't1', 'checklist_id': 'c1', 'title': '要搬的卡', 'priority': 'high'},
    {'id': 't2', 'checklist_id': 'c1', 'title': '另一張卡'},
  ],
}));

void main() {
  late _Stub stub;

  Future<void> boot(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    stub = _Stub();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        boardByIdProvider('b1').overrideWith((ref) async => _snap),
        dioProvider.overrideWithValue(
            Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = stub),
        initialConfigProvider.overrideWithValue(const AppConfig(
          serverUrl: 'http://test',
          token: 't',
          themeMode: ThemeModePref.dark,
          preferredName: '',
          deviceKey: 'dev-1',
        )),
      ],
      child: MaterialApp(
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: kTestSupportedLocales,
        theme: buildUepTheme(Brightness.dark),
        home: const BoardScreen(boardId: 'b1'),
      ),
    ));
    await tester.pumpAndSettle();
    stub.seen.clear();
  }

  /// 長按後拖到 [to] 放開。
  Future<void> dragCardTo(WidgetTester tester, Offset to) async {
    final g = await tester.startGesture(tester.getCenter(find.text('要搬的卡')));
    await tester.pump(const Duration(milliseconds: 400));
    await g.moveTo(to);
    await tester.pump(const Duration(milliseconds: 50));
    await g.up();
    await tester.pumpAndSettle();
  }

  testWidgets('拖到同週期另一個開著的階段 ⇒ 建新卡再標 moved', (tester) async {
    await boot(tester);
    await dragCardTo(tester, tester.getCenter(find.text('乙階段')));

    expect(stub.seen.length, greaterThanOrEqualTo(2));
    expect(stub.seen[0].path, '/api/board/checklists/c2/tasks');
    expect((stub.seen[0].data as Map)['title'], '要搬的卡');
    expect((stub.seen[0].data as Map)['priority'], 'high');
    expect(stub.seen[1].path, '/api/board/tasks/t1/status');
    expect((stub.seen[1].data as Map)['moved_to'], 'new1');
  });

  testWidgets('拖到已收尾的階段 ⇒ 不送任何請求', (tester) async {
    await boot(tester);
    await dragCardTo(tester, tester.getCenter(find.text('丙階段')));
    expect(stub.seen, isEmpty);
  });

  testWidgets('拖到左欄的週期 ⇒ 開對話框、週期已預選', (tester) async {
    await boot(tester);
    await dragCardTo(tester, tester.getCenter(find.text('第二個週期')));

    expect(find.byType(AlertDialog), findsOneWidget);
    // 預選的週期顯示在下拉裡
    expect(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.text('第二個週期')),
        findsWidgets);
    expect(stub.seen, isEmpty);
  });
  testWidgets('拖階段把手 ⇒ 送出該週期的完整階段順序', (tester) async {
    await boot(tester);
    final handles = find.byIcon(Icons.drag_indicator);
    expect(handles, findsNWidgets(3));
    final g = await tester.startGesture(tester.getCenter(handles.at(1)));
    await tester.pump(const Duration(milliseconds: 50));
    final to = tester.getCenter(handles.at(0)) - const Offset(0, 20);
    for (var i = 1; i <= 8; i++) {
      await g.moveTo(Offset.lerp(tester.getCenter(handles.at(1)), to, i / 8)!);
      await tester.pump(const Duration(milliseconds: 50));
    }
    await g.up();
    await tester.pumpAndSettle();

    final r = stub.seen.singleWhere((o) => o.path.endsWith('/reorder'));
    final data = r.data as Map;
    expect(data['kind'], 'checklist');
    expect([for (final i in data['items'] as List) (i as Map)['id']],
        ['c2', 'c1', 'c3']);
  });
}
