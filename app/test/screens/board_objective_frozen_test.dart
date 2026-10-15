import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/screens/board/board_screen.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/l10n.dart';

/// 週期凍結（Hub 2026-09-21）：週期只有 `active` 時，它自己與底下的階段、
/// 任務才可寫；`review` / `verified` / `done` / `cancelled` 一律 409
/// `objective_closed`。
///
/// 🔴 釘的是**入口的存在**，不是 API 有沒有被呼叫。留著一顆按下去必然 409
/// 的按鈕，畫面上與能用的按鈕長得一模一樣——尤其「重新開啟階段」：它看起來
/// 正是那個解凍的動作，而真正的解凍在上面一層（打回週期）。
BoardSnapshot _snap(String status, {Map<String, dynamic>? release}) =>
    const BoardSnapshot().merge(BoardDelta.fromJson({
      'board_seq': 10,
      'full': true,
      'board_id': 'b1',
      'my_role': 'editor',
      'objectives': [
        {
          'id': 'o1',
          'title': '凍結測試週期',
          'status': status,
          'release': ?release,
        },
      ],
      'checklists': [
        {'id': 'c1', 'objective_id': 'o1', 'title': '收好的階段',
          'status': 'done'},
        {'id': 'c2', 'objective_id': 'o1', 'title': '還開著的階段',
          'status': 'open'},
      ],
      'tasks': [
        {'id': 't1', 'checklist_id': 'c1', 'title': '卡', 'status': 'done'},
      ],
    }));

Widget _app(Widget child) => MaterialApp(
      localizationsDelegates: kTestLocalizationsDelegates,
      supportedLocales: kTestSupportedLocales,
      theme: buildUepTheme(Brightness.dark),
      home: child,
    );

Widget _wrap(BoardSnapshot snap) => ProviderScope(
      overrides: [
        boardByIdProvider('b1').overrideWith((ref) async => snap),
      ],
      child: _app(const BoardScreen(boardId: 'b1')),
    );

void main() {
  testWidgets('done 的週期底下沒有「重新開啟階段」——解凍不在這一層',
      (tester) async {
    await tester.pumpWidget(_wrap(_snap('done')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('重新開啟階段'), findsNothing);
    // 階段的其餘寫入入口也一起收
    expect(find.text('收尾階段'), findsNothing);
    expect(find.text('取消階段'), findsNothing);
    expect(find.text('＋ 任務'), findsNothing);
    // 收掉之後要說出為什麼
    expect(find.text('週期已完成，無法修改'), findsOneWidget);
  });

  testWidgets('done 的週期沒有打回入口，提示也不叫人打回', (tester) async {
    await tester.pumpWidget(_wrap(_snap('done')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // 完成是終點：Hub 只讓 review／verified 走 reopen，畫一顆打回就是畫一顆
    // 必然 409 的按鈕
    expect(find.text('打回'), findsNothing);
    // 提示也不能指過去——沒有那條路了
    final hint = tester.widget<Text>(find.text('週期已完成，無法修改'));
    expect(hint.data, isNot(contains('打回')));
  });

  testWidgets('verified 的週期還有打回入口', (tester) async {
    await tester.pumpWidget(_wrap(_snap('verified')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('打回'), findsOneWidget);
    expect(find.text('週期已確認，先打回才能修改'), findsOneWidget);
  });

  testWidgets('review 的週期沒有任何編輯入口（週期自己的也沒有）',
      (tester) async {
    await tester.pumpWidget(_wrap(_snap('review')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('編輯'), findsNothing);
    expect(find.text('＋ 階段'), findsNothing);
    expect(find.text('週期已送審，先打回才能修改'), findsOneWidget);
  });

  testWidgets('對照組：active 的週期入口都在', (tester) async {
    await tester.pumpWidget(_wrap(_snap('active')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // 週期一顆（抬頭）＋ 兩個階段各一顆
    expect(find.text('編輯'), findsNWidgets(3));
    expect(find.text('＋ 階段'), findsOneWidget);
    expect(find.text('重新開啟階段'), findsOneWidget);
    expect(find.text('收尾階段'), findsOneWidget);
    expect(find.text('＋ 任務'), findsOneWidget);
    // 沒凍結就沒有那行提示
    expect(find.text('週期已完成，無法修改'), findsNothing);
  });

  testWidgets('打回之後入口回來', (tester) async {
    // 從 `verified` 起算——`done` 打不回，那條路不存在
    var status = 'verified';
    final container = ProviderContainer(overrides: [
      boardByIdProvider('b1').overrideWith((ref) async => _snap(status)),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: _app(const BoardScreen(boardId: 'b1')),
    ));
    await tester.pumpAndSettle();
    expect(find.text('重新開啟階段'), findsNothing);

    // 打回：Hub 改了週期狀態，板重拉一次
    status = 'active';
    container.invalidate(boardByIdProvider('b1'));
    await tester.pumpAndSettle();

    expect(find.text('重新開啟階段'), findsOneWidget);
    expect(find.text('編輯'), findsNWidgets(3));
    expect(find.text('週期已確認，先打回才能修改'), findsNothing);
  });

  Future<void> pumpFresh(WidgetTester tester, BoardSnapshot snap) async {
    // 先清掉上一份，免得同型別的 widget 沿用舊的 provider 狀態
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_wrap(snap));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Map<String, dynamic> run(String status, [String reason = '']) =>
      {'run_id': 'r1', 'status': status, 'reason': reason};

  testWidgets('上板入口：從沒上板過（release 為 null）→ 有按鈕、沒有失敗字樣',
      (tester) async {
    for (final status in ['verified', 'done']) {
      await pumpFresh(tester, _snap(status));
      expect(find.text('上板'), findsOneWidget, reason: status);
      expect(find.text('上次上板失敗'), findsNothing, reason: status);
    }
  });

  testWidgets('上板入口：上次失敗／取消 → 有按鈕＋失敗字樣', (tester) async {
    for (final status in ['verified', 'done']) {
      for (final r in ['failed', 'cancelled']) {
        await pumpFresh(
            tester, _snap(status, release: run(r, 'release_partial')));
        expect(find.text('上板'), findsOneWidget, reason: '$status/$r');
        expect(find.text('上次上板失敗'), findsOneWidget, reason: '$status/$r');
      }
    }
  });

  testWidgets('🔴 上板入口：已上板成功（done）→ 沒有按鈕', (tester) async {
    for (final status in ['verified', 'done']) {
      await pumpFresh(tester, _snap(status, release: run('done')));
      expect(find.text('上板'), findsNothing, reason: status);
      expect(find.text('上次上板失敗'), findsNothing, reason: status);
    }
  });

  testWidgets('🔴 上板入口：還在跑（queued／running…）→ 沒有按鈕', (tester) async {
    for (final r in ['queued', 'claimed', 'running', 'limited', 'handoff']) {
      await pumpFresh(tester, _snap('verified', release: run(r)));
      expect(find.text('上板'), findsNothing, reason: r);
      expect(find.text('上次上板失敗'), findsNothing, reason: r);
    }
  });

  testWidgets('上板入口：active／review 的週期不出現（就算帶著 release）',
      (tester) async {
    for (final status in ['active', 'review']) {
      await pumpFresh(tester, _snap(status, release: run('failed')));
      expect(find.text('上板'), findsNothing, reason: status);
    }
  });
}
