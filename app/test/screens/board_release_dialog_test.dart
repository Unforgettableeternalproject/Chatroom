import 'package:chatroom_app/api/board_api.dart';
import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/release.dart';
import 'package:chatroom_app/screens/board/board_release_dialog.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/l10n.dart';

/// 週期確認對話框的上板那一段（C6）。
///
/// 守住兩件事：
/// 1. **`possible` 為 false 就完全沒有上板區塊**——畫一個必定被 Hub 擋下來
///    的開關，只是讓人多按一次。
/// 2. 勾選、來源分支、tag 要原封不動組進 verify 的 `release`：這裡送錯一個
///    分支名，後果是**推到穩定分支上的東西不是使用者選的那個**。
class _FakeBoardApi extends BoardApi {
  _FakeBoardApi(this.candidates) : super(Dio());

  final ReleaseCandidates candidates;

  ReleaseRequest? sent;
  int verifyCalls = 0;

  @override
  Future<ReleaseCandidates> releaseCandidates(String objectiveId,
          {String? participantId, String? sessionKey}) async =>
      candidates;

  @override
  Future<void> verifyObjective(String objectiveId,
      {String? participantId,
      String? sessionKey,
      ReleaseRequest? release}) async {
    verifyCalls++;
    sent = release;
  }
}

void main() {
  const config = AppConfig(
    serverUrl: 'http://test',
    token: 'root-token',
    themeMode: ThemeModePref.dark,
    preferredName: 'Bernie',
    deviceKey: 'device-key',
  );

  Widget wrap(_FakeBoardApi api) => ProviderScope(
        overrides: [
          initialConfigProvider.overrideWithValue(config),
          boardApiProvider.overrideWithValue(api),
        ],
        child: MaterialApp(
          locale: kTestLocale,
          localizationsDelegates: kTestLocalizationsDelegates,
          supportedLocales: kTestSupportedLocales,
          theme: buildUepTheme(Brightness.dark),
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showObjectiveVerifyDialog(
                    context,
                    actions: ref.read(boardActionsByIdProvider('b1')),
                    objectiveId: 'o1',
                  ),
                  child: const Text('開'),
                ),
              ),
            ),
          ),
        ),
      );

  Future<void> open(WidgetTester tester, _FakeBoardApi api) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(api));
    await tester.tap(find.text('開'));
    await tester.pumpAndSettle();
  }

  final twoRepos = ReleaseCandidates.fromJson(const {
    'workspace_key': 'chatroom',
    'possible': true,
    'repos': [
      {
        'name': 'Chatroom',
        'stable_branch': 'master',
        'stable_branch_exists': true,
        'branches': ['develop'],
        'last_branch': 'develop',
        'commits': 3,
      },
      {
        'name': 'UEP',
        'stable_branch': '',
        'branches': ['main'],
        'last_branch': 'main',
        'commits': 1,
      },
    ],
    'release_settings': {'merge_method': 'squash'},
  });

  testWidgets('🔴 possible 為 false：沒有上板開關，確認照樣送得出去', (tester) async {
    final api = _FakeBoardApi(ReleaseCandidates.fromJson(const {
      'workspace_key': 'chatroom',
      'possible': false,
      'repos': [],
    }));
    await open(tester, api);

    expect(find.text('同時上板'), findsNothing);
    expect(find.byType(Switch), findsNothing);

    await tester.tap(find.text('確認'));
    await tester.pumpAndSettle();

    expect(api.verifyCalls, 1);
    // 不帶 release ＝ 只是確認週期
    expect(api.sent, isNull);
  });

  testWidgets('possible 為 false＋reason=board_axis：講一句要從工作房按', (tester) async {
    final api = _FakeBoardApi(ReleaseCandidates.fromJson(const {
      'workspace_key': 'chatroom',
      'possible': false,
      'reason': 'board_axis',
      'repos': [],
    }));
    await open(tester, api);

    expect(find.text('上板要從掛著這塊板的工作房進行'), findsOneWidget);
    // 提示歸提示，上板區還是不畫
    expect(find.byType(Switch), findsNothing);
  });

  testWidgets('🔴 reason=workspace_not_bound：不講那句（換個地方按也沒用）',
      (tester) async {
    final api = _FakeBoardApi(ReleaseCandidates.fromJson(const {
      'workspace_key': 'chatroom',
      'possible': false,
      'reason': 'workspace_not_bound',
      'repos': [],
    }));
    await open(tester, api);

    expect(find.text('上板要從掛著這塊板的工作房進行'), findsNothing);
    expect(find.byType(Switch), findsNothing);
  });

  testWidgets('possible 為 true：開關預設關著，不開就不帶 release', (tester) async {
    final api = _FakeBoardApi(twoRepos);
    await open(tester, api);

    expect(find.text('同時上板'), findsOneWidget);
    // 關著的時候候選清單不佔畫面
    expect(find.text('Chatroom'), findsNothing);

    await tester.tap(find.text('確認'));
    await tester.pumpAndSettle();
    expect(api.sent, isNull);
  });

  testWidgets('勾選、來源分支、tag 組進 verify 的 release', (tester) async {
    final api = _FakeBoardApi(twoRepos);
    await open(tester, api);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    // 工作區的合併方式是唯讀的，只顯示
    expect(find.text('合併方式：squash'), findsOneWidget);
    // 沒設穩定分支的 repo 留在清單裡，但講得出原因
    expect(find.text('未設穩定分支'), findsOneWidget);

    // 預設納入有穩定分支的那個，來源分支預設 last_branch
    final source = find.widgetWithText(TextField, 'develop');
    expect(source, findsOneWidget);
    await tester.enterText(source, 'feature/release');
    await tester.enterText(
        find.widgetWithText(TextField, 'tag（選填）'), 'v1.3.0');
    await tester.pumpAndSettle();

    await tester.tap(find.text('確認'));
    await tester.pumpAndSettle();

    final sent = api.sent!;
    expect(sent.tag, 'v1.3.0');
    // 🔴 沒設穩定分支的那個不該混進來
    expect(sent.repos.length, 1);
    expect(sent.repos.single.name, 'Chatroom');
    expect(sent.repos.single.sourceBranch, 'feature/release');
  });

  testWidgets('開了上板卻把唯一能勾的取消：擋下來，不送出', (tester) async {
    final api = _FakeBoardApi(twoRepos);
    await open(tester, api);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    // 可勾的只有 Chatroom 那一個（UEP 的 checkbox 是死的）
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('確認'));
    await tester.pumpAndSettle();

    expect(api.verifyCalls, 0);
    expect(find.text('至少要選一個 repo'), findsOneWidget);
  });
}
