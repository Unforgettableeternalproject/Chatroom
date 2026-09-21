import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/agent_run.dart';
import 'package:chatroom_app/screens/ops/ops_dashboard_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/l10n.dart';

/// 儀表板上的「同一專案一次只跑一筆」。
///
/// 這顆開關關掉之後，同一個工作區的多筆 run 會同時動同一份 repo，所以畫面
/// 上的位置必須就是 Hub 上的狀態：Hub 退回來時停在切過去那一邊，下一個人
/// 看畫面會以為鎖已經關了（或已經開了），而那是假的。
/// 非房主的 PATCH 是 403 `room_owner_required`——給他一顆必定失敗的開關
/// 跟不給一樣。

RoomRunnerBoard _board() => RoomRunnerBoard(
    roomId: 'room-1',
    runners: const [],
    workspaceCandidates: const ['ai-website']);

Widget _wrap(Widget child) => MaterialApp(
      localizationsDelegates: kTestLocalizationsDelegates,
      supportedLocales: kTestSupportedLocales,
      theme: buildUepTheme(Brightness.dark),
      home: Scaffold(body: child),
    );

Finder get _toggle => find.byType(Switch);

void main() {
  testWidgets('房主切得動，而且送出去的就是切過去那一邊', (tester) async {
    final sent = <bool>[];
    await tester.pumpWidget(_wrap(OpsDashboardView(
      board: _board(),
      workspaceKey: 'ai-website',
      workspaceServed: true,
      youAreAdmin: true,
      singleWriter: true,
      onSetSingleWriter: (v) async {
        sent.add(v);
        return true;
      },
    )));

    expect(find.text('同一專案一次只跑一筆'), findsOneWidget);
    expect(find.text('關閉後多筆派工會同時改同一個 repo，可能互相衝突。'),
        findsOneWidget);
    expect(tester.widget<Switch>(_toggle).value, isTrue);

    await tester.tap(_toggle);
    await tester.pumpAndSettle();

    expect(sent, [false]);
    // 成功就停在切過去那一邊，不等重抓才動
    expect(tester.widget<Switch>(_toggle).value, isFalse);
  });

  testWidgets('Hub 說的是關著的，開關就畫成關著的', (tester) async {
    await tester.pumpWidget(_wrap(OpsDashboardView(
      board: _board(),
      workspaceKey: 'ai-website',
      youAreAdmin: true,
      singleWriter: false,
      onSetSingleWriter: (_) async => true,
    )));

    expect(tester.widget<Switch>(_toggle).value, isFalse);
  });

  testWidgets('非房主只看得到狀態，切不動', (tester) async {
    final sent = <bool>[];
    await tester.pumpWidget(_wrap(OpsDashboardView(
      board: _board(),
      workspaceKey: 'ai-website',
      youAreAdmin: false,
      singleWriter: true,
      onSetSingleWriter: (v) async {
        sent.add(v);
        return true;
      },
    )));

    // 狀態要看得到——「一次只跑一筆」是派工前要知道的事
    expect(find.text('同一專案一次只跑一筆'), findsOneWidget);
    final sw = tester.widget<Switch>(_toggle);
    expect(sw.value, isTrue);
    expect(sw.onChanged, isNull);

    await tester.tap(_toggle);
    await tester.pumpAndSettle();
    expect(sent, isEmpty);
  });

  testWidgets('🔴 Hub 退回來就回復原值——停在 Hub 沒有答應的位置，'
      '下一個人會以為鎖已經關了', (tester) async {
    await tester.pumpWidget(_wrap(OpsDashboardView(
      board: _board(),
      workspaceKey: 'ai-website',
      youAreAdmin: true,
      singleWriter: true,
      onSetSingleWriter: (_) async => false,
    )));

    await tester.tap(_toggle);
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(_toggle).value, isTrue);
  });
}
