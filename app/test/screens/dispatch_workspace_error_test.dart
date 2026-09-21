import 'package:chatroom_app/api/runs_api.dart';
import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/errors/api_exception.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/agent_run.dart';
import 'package:chatroom_app/screens/ops/ops_actions.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/runs_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../helpers/l10n.dart';

/// 綁定工作區之後 Hub 多出來的兩種退法（契約 2026-09-21）。
///
/// **處置不一樣，所以話也要不一樣**：沒綁是去找房主，綁錯邊是這張卡根本
/// 不該派到這間房。壓成同一句「派工失敗」的話，兩種情況的人都不知道下一步
/// 要做什麼。
class _FakeRunsApi extends RunsApi {
  _FakeRunsApi(this.error) : super(Dio());

  final ApiException error;

  @override
  Future<RoomRunnerBoard> dashboard(String roomId,
          {String? participantId}) async =>
      const RoomRunnerBoard(runners: [
        AgentRunner(id: 'runner-1', status: 'online', projects: ['ai-website']),
      ]);

  @override
  Future<AgentRun> create(
    String roomId, {
    required String kind,
    required String project,
    required String ref,
    String brief = '',
    String boardId = '',
    int priority = 0,
    String? participantId,
  }) async =>
      throw error;
}

Future<void> _dispatch(WidgetTester tester, ApiException error,
    SettingsRepository settings) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      runsApiProvider.overrideWithValue(_FakeRunsApi(error)),
      settingsRepoProvider.overrideWithValue(settings),
    ],
    child: MaterialApp(
      localizationsDelegates: kTestLocalizationsDelegates,
      supportedLocales: kTestSupportedLocales,
      theme: buildUepTheme(Brightness.dark),
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) => TextButton(
            onPressed: () => dispatchRun(context, ref,
                roomId: 'room-1',
                targetRef: 'task-1',
                targetLabel: '卡：一張卡'),
            child: const Text('派工'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('派工'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('送出'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late SettingsRepository settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsRepository(await SharedPreferences.getInstance());
  });

  testWidgets('還沒綁工作區：下一步在房主那裡', (tester) async {
    await _dispatch(
        tester,
        const ConflictException('workspace_not_bound', 'room has no workspace'),
        settings);

    expect(find.text('這個房間還沒綁定工作區，請房主先綁。'), findsOneWidget);
  });

  testWidgets('專案對不上綁定：講出這個房間只收哪一個 key', (tester) async {
    await _dispatch(
        tester,
        const ConflictException('workspace_project_mismatch', 'mismatch',
            detail: {'workspace_key': 'ai-website'}),
        settings);

    expect(find.text('這個房間只派工到「ai-website」。'), findsOneWidget);
  });
}
