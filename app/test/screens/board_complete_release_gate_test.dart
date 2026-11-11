import 'package:chatroom_app/api/board_api.dart';
import 'package:chatroom_app/core/errors/api_exception.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/models/release.dart';
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

/// 完成週期要等上板成功（Hub 對 complete 回 409 `release_not_done`）。
///
/// 🔴 判準是 `objective.release` 存在且 status != 'done'；從沒上板過的週期
/// 不受影響。按鈕停用之外，409 也要用 `code` 判斷並顯示短字。
BoardSnapshot _snap({Map<String, dynamic>? release}) =>
    const BoardSnapshot().merge(BoardDelta.fromJson({
      'board_seq': 10,
      'full': true,
      'board_id': 'b1',
      'my_role': 'editor',
      'objectives': [
        {
          'id': 'o1',
          'title': '完成閘測試週期',
          'status': 'verified',
          'release': ?release,
        },
      ],
      'checklists': const [],
      'tasks': const [],
    }));

Widget _wrap(BoardSnapshot snap) => ProviderScope(
      overrides: [
        initialConfigProvider.overrideWithValue(kTestInitialConfig),
        boardByIdProvider('b1').overrideWith((ref) async => snap),
      ],
      child: MaterialApp(
        locale: kTestLocale,
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: kTestSupportedLocales,
        theme: buildUepTheme(Brightness.dark),
        home: const BoardScreen(boardId: 'b1'),
      ),
    );

/// 結束週期那顆按鈕有沒有 onTap。
bool _completeEnabled(WidgetTester tester) {
  final ink = find.ancestor(
      of: find.text('結束週期'), matching: find.byType(InkWell));
  return tester.widget<InkWell>(ink.first).onTap != null;
}

void main() {
  Future<void> pumpFresh(WidgetTester tester, BoardSnapshot snap) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_wrap(snap));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Map<String, dynamic> run(String status) =>
      {'run_id': 'r1', 'status': status, 'reason': ''};

  testWidgets('從沒上板過：結束週期可按、沒有上板提示', (tester) async {
    await pumpFresh(tester, _snap());
    expect(_completeEnabled(tester), isTrue);
    expect(find.text('上板成功後才能結束'), findsNothing);
  });

  testWidgets('🔴 上板失敗／取消／還在跑：結束週期停用並說明原因', (tester) async {
    for (final r in ['failed', 'cancelled', 'queued', 'running']) {
      await pumpFresh(tester, _snap(release: run(r)));
      expect(_completeEnabled(tester), isFalse, reason: r);
      expect(find.text('上板成功後才能結束'), findsOneWidget, reason: r);
    }
  });

  testWidgets('上板成功（done）：結束週期可按', (tester) async {
    await pumpFresh(tester, _snap(release: run('done')));
    expect(_completeEnabled(tester), isTrue);
    expect(find.text('上板成功後才能結束'), findsNothing);
  });

  testWidgets('release 帶未知欄位（fix_run_id 之類）：照常解析', (tester) async {
    await pumpFresh(
        tester,
        _snap(release: {
          ...run('failed'),
          'fix_run_id': 'r2',
          'fix_status': 'running',
        }));
    expect(_completeEnabled(tester), isFalse);
  });

  testWidgets('🔴 409 release_not_done：用 code 判斷，顯示短字而非 Hub 原話',
      (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      locale: kTestLocale,
      localizationsDelegates: kTestLocalizationsDelegates,
      supportedLocales: kTestSupportedLocales,
      home: Scaffold(
        body: Builder(builder: (c) {
          ctx = c;
          return TextButton(
            onPressed: () => runBoardAction<void>(
                c,
                () async => throw const ConflictException(
                    'release_not_done', 'release is not done (server text)')),
            child: const Text('點'),
          );
        }),
      ),
    ));
    expect(ctx.mounted, isTrue);
    await tester.tap(find.text('點'));
    await tester.pump();
    expect(find.text('上板成功後才能結束'), findsOneWidget);
    expect(find.text('release is not done (server text)'), findsNothing);
  });

  test('createRelease：body 就是表單內容，不帶 retry', () async {
    final bodies = <dynamic>[];
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
      bodies.add(o.data);
      h.resolve(Response(requestOptions: o, data: <String, dynamic>{}));
    }));
    await BoardApi(dio).createRelease('o1',
        release: const ReleaseRequest(repos: [
          ReleaseRepoSelection(name: 'Chatroom', sourceBranch: 'develop')
        ], tag: 'v1'));
    expect((bodies[0] as Map).containsKey('retry'), isFalse);
    expect((bodies[0] as Map)['tag'], 'v1');
  });

  testWidgets('修復成功（status 已是 done、帶 fix 欄位）：結束週期解鎖、不再提示重新上板',
      (tester) async {
    await pumpFresh(
        tester,
        _snap(release: {
          'run_id': 'r1',
          'status': 'done',
          'reason': 'release_fixed',
          'fix_run_id': 'r2',
          'fix_status': 'done',
        }));
    expect(_completeEnabled(tester), isTrue);
    expect(find.text('重新上板'), findsNothing);
  });

  testWidgets('cancelled：沒有上板按鈕、只提示打回，結束週期仍停用', (tester) async {
    await pumpFresh(tester, _snap(release: run('cancelled')));
    expect(find.text('重新上板'), findsNothing);
    expect(find.text('上板失敗，打回後重新送審即可再次上板'), findsOneWidget);
    expect(_completeEnabled(tester), isFalse);
  });

  test('ObjectiveRelease 解析 fix_run_id／fix_status／blockedReopened；缺欄位為空', () {
    final fixed = ObjectiveRelease.fromJson({
      'run_id': 'r1',
      'status': 'failed',
      'reason': 'release_blocked_reopened',
      'fix_run_id': 'r2',
      'fix_status': 'queued'
    });
    expect(fixed.fixRunId, 'r2');
    expect(fixed.fixStatus, 'queued');
    expect(fixed.blockedReopened, isTrue);
    final old = ObjectiveRelease.fromJson({'run_id': 'r1', 'status': 'failed'});
    expect(old.fixRunId, '');
    expect(old.blockedReopened, isFalse);
  });

  test('createRelease：回應帶 run + fix_run 也不出錯', () async {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
      h.resolve(Response(requestOptions: o, data: <String, dynamic>{
        'run': {'id': 'r1', 'status': 'failed'},
        'fix_run': {'id': 'r2', 'status': 'queued'},
      }));
    }));
    await BoardApi(dio).createRelease('o1',
        release: const ReleaseRequest(repos: [
          ReleaseRepoSelection(name: 'Chatroom', sourceBranch: 'develop')
        ], tag: 'v1'),
        );
  });

  testWidgets('🔴 上板新錯誤碼：用 code 對應短字，不顯示 Hub 原話', (tester) async {
    const cases = {
      'objective_already_done': '週期已經結束了。',
      'release_in_progress': '上板進行中，等它結束。',
      'release_legacy_closed': '這個週期的舊上板紀錄已結案',
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

  testWidgets('legacy 上板紀錄：不算失敗、不擋結束、沒有上板入口與失敗提示',
      (tester) async {
    await pumpFresh(tester, _snap(release: run('legacy')));
    expect(_completeEnabled(tester), isTrue);
    expect(find.text('上板'), findsNothing);
    expect(find.text('上板失敗，打回後重新送審即可再次上板'), findsNothing);
    expect(find.text('上板成功後才能結束'), findsNothing);
  });

  test('ObjectiveRelease.legacy：failed／completeBlocked 都不成立', () {
    const r = ObjectiveRelease(status: 'legacy');
    expect(r.legacy, isTrue);
    expect(r.failed, isFalse);
    expect(r.inProgress, isFalse);
  });
}
