import 'package:chatroom_app/api/runs_api.dart';
import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/agent_run.dart';
import 'package:chatroom_app/screens/ops/ops_actions.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/runs_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../helpers/l10n.dart';

/// 🔴 2026-09-17 實機：第一次按「派工」填完送出，Hub 上什麼都沒有，App 的
/// log 只留下一行「派工沒有送出：畫面已經不在了」；第二次按同一張卡才真的
/// 建單。
///
/// 根因不是對話框，是送出的前提：`dispatchRun` 在對話框關掉之後檢查
/// `context.mounted`，而入口（階段列、卡片抽屜的選單）在對話框關掉時自己
/// 已經被重建或移除，那個 context 當然失效。**送不送 API 不可以取決於畫面
/// 還在不在**——顯示不了 snackbar 只代表那句話沒人看到。
class _FakeRunsApi extends RunsApi {
  _FakeRunsApi() : super(Dio());

  int creates = 0;
  String? lastRef;
  String? lastProject;

  @override
  Future<RoomRunnerBoard> dashboard(String roomId, {String? participantId}) async =>
      const RoomRunnerBoard(runners: [
        // 只宣告一個專案：對話框會直接選它，測試不必去點下拉
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
  }) async {
    creates++;
    lastRef = ref;
    lastProject = project;
    return AgentRun(
        id: 'run-1', roomId: roomId, kind: kind, project: project, ref: ref);
  }

  @override
  Future<List<AgentRun>> list(String roomId,
          {List<String> statuses = const [], String? participantId}) async =>
      const [];
}

Widget _host({
  required _FakeRunsApi api,
  required SettingsRepository settings,
  required ValueListenable<bool> entryVisible,
}) =>
    ProviderScope(
      overrides: [
        runsApiProvider.overrideWithValue(api),
        settingsRepoProvider.overrideWithValue(settings),
      ],
      child: MaterialApp(
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: kTestSupportedLocales,
        theme: buildUepTheme(Brightness.dark),
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: entryVisible,
            builder: (context, visible, _) => visible
                ? Consumer(
                    builder: (context, ref, _) => TextButton(
                      onPressed: () => dispatchRun(
                        context,
                        ref,
                        roomId: 'room-1',
                        targetRef: 'chk-1',
                        targetLabel: '階段：JSAI-2377',
                      ),
                      child: const Text('派工'),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ),
    );

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late _FakeRunsApi api;
  late SettingsRepository settings;
  late ValueNotifier<bool> entryVisible;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsRepository(await SharedPreferences.getInstance());
    api = _FakeRunsApi();
    entryVisible = ValueNotifier<bool>(true);
  });

  tearDown(() => entryVisible.dispose());

  Future<void> openAndSubmit(WidgetTester tester,
      {required bool removeEntry}) async {
    await tester.pumpWidget(
        _host(api: api, settings: settings, entryVisible: entryVisible));
    await tester.tap(find.text('派工'));
    await tester.pumpAndSettle();
    expect(find.text('目標：階段：JSAI-2377'), findsOneWidget);

    if (removeEntry) {
      // 入口從樹上消失——階段列重建、抽屜關掉，實機上就是這件事
      entryVisible.value = false;
      await tester.pump();
    }

    await tester.tap(find.text('送出'));
    await tester.pumpAndSettle();
  }

  testWidgets('🔴 入口在送出前就不在樹上了，create_run 還是要送出去', (tester) async {
    await openAndSubmit(tester, removeEntry: true);

    expect(api.creates, 1);
    expect(api.lastRef, 'chk-1');
    expect(api.lastProject, 'ai-website');
    expect(tester.takeException(), isNull);
  });

  testWidgets('入口還在時照舊送出，並且講得出排隊結果', (tester) async {
    await openAndSubmit(tester, removeEntry: false);

    expect(api.creates, 1);
    expect(find.text('已排隊。'), findsOneWidget);
  });
}
