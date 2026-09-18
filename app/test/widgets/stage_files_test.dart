import 'package:chatroom_app/api/board_api.dart';
import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/stage_file.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:chatroom_app/widgets/stage_files.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _file = StageFile(
  id: 'sf1',
  checklistId: 'c1',
  attachmentId: 'a1',
  filename: 'run.log',
  mime: 'text/plain',
  size: 900,
  addedBy: 'human:bernie',
  addedByName: '艾斯維爾',
  note: '這輪要對照的 log',
);

const _pdf = StageFile(
  id: 'sf2',
  checklistId: 'c1',
  attachmentId: 'a2',
  filename: 'spec.pdf',
  mime: 'application/pdf',
  size: 2048,
);

/// 記下「卸除打到哪一條」的假 API。素材的卸除用的是掛接關係的 id，
/// 拿 attachment_id 去刪會刪錯一列——那是這份假件要看住的東西。
class _FakeBoardsApi extends BoardsApi {
  _FakeBoardsApi() : super(Dio());

  final removed = <(String, String, String)>[];

  @override
  Future<void> removeStageFile(
    String boardId,
    String checklistId,
    String fileId, {
    String? participantId,
    String? sessionKey,
  }) async {
    removed.add((boardId, checklistId, fileId));
  }
}

/// 板軸的動作：測試裡沒有房，身分走 session key（[AppConfig.deviceKey]）。
final _probeActionsProvider =
    Provider<BoardActions>((ref) => BoardActions.forBoard(ref, 'b1'));

Widget _host(Widget child, {BoardsApi? boardsApi}) => ProviderScope(
      overrides: [
        if (boardsApi != null) boardsApiProvider.overrideWithValue(boardsApi),
        initialConfigProvider.overrideWithValue(const AppConfig(
          serverUrl: 'http://hub.test',
          token: 'tok',
          themeMode: ThemeModePref.dark,
          preferredName: 'Bernie',
          deviceKey: 'device-key',
        )),
      ],
      child: MaterialApp(
        theme: buildUepTheme(Brightness.dark),
        home: Scaffold(body: child),
      ),
    );

void main() {
  group('階段標題列的素材數', () {
    testWidgets('0 不顯示——沒有素材是常態，每一列都掛一個「素材 0」會讓真的有的那幾列不顯眼',
        (tester) async {
      await tester.pumpWidget(_host(const StageFileCount(count: 0)));

      expect(find.textContaining('素材'), findsNothing);
    });

    testWidgets('有素材時顯示數量', (tester) async {
      await tester.pumpWidget(_host(const StageFileCount(count: 3)));

      expect(find.text('素材 3'), findsOneWidget);
    });
  });

  group('素材清單', () {
    testWidgets('列出檔名、大小、掛的人與 note', (tester) async {
      await tester.pumpWidget(_host(const StageFilesList(
        boardId: 'b1',
        checklistId: 'c1',
        files: [_file],
        actions: null,
        participantId: 'p1',
      )));

      expect(find.text('run.log'), findsOneWidget);
      expect(find.text('900 B'), findsOneWidget);
      expect(find.text('· 艾斯維爾 掛上'), findsOneWidget);
      expect(find.text('這輪要對照的 log'), findsOneWidget);
    });

    testWidgets('圖示依 mime 分——一眼看得出哪一列是報告、哪一列是純文字',
        (tester) async {
      await tester.pumpWidget(_host(const StageFilesList(
        boardId: 'b1',
        checklistId: 'c1',
        files: [_file, _pdf],
        actions: null,
        participantId: 'p1',
      )));

      expect(find.byIcon(Icons.description_outlined), findsOneWidget);
      expect(find.byIcon(Icons.picture_as_pdf_outlined), findsOneWidget);
      expect(find.text('spec.pdf'), findsOneWidget);
    });

    testWidgets('加不了素材時空列表不佔版面——缺鍵的舊 Hub 就是這個樣子',
        (tester) async {
      await tester.pumpWidget(_host(const StageFilesList(
        boardId: 'b1',
        checklistId: 'c1',
        files: [],
        actions: null,
      )));

      expect(find.byType(SizedBox), findsWidgets);
      expect(find.textContaining('run.log'), findsNothing);
      expect(find.text('新增素材'), findsNothing);
    });

    testWidgets('空列表只留一顆「新增素材」，不放空狀態文案', (tester) async {
      await tester.pumpWidget(_host(StageFilesList(
        boardId: 'b1',
        checklistId: 'c1',
        files: const [],
        actions: null,
        onAdd: () {},
      )));

      expect(find.text('新增素材'), findsOneWidget);
    });

    testWidgets('「新增素材」在清單底部：先看過有什麼才決定加', (tester) async {
      await tester.pumpWidget(_host(StageFilesList(
        boardId: 'b1',
        checklistId: 'c1',
        files: const [_file],
        actions: null,
        participantId: 'p1',
        onAdd: () {},
      )));

      final listBottom = tester.getBottomLeft(find.text('run.log')).dy;
      expect(tester.getTopLeft(find.text('新增素材')).dy,
          greaterThanOrEqualTo(listBottom - 1));
    });
  });

  group('卸除素材', () {
    testWidgets('確認之後打卸除 API，帶的是掛接關係的 id', (tester) async {
      final api = _FakeBoardsApi();
      await tester.pumpWidget(_host(
        Consumer(
          builder: (context, ref, _) => StageFilesList(
            boardId: 'b1',
            checklistId: 'c1',
            files: const [_file],
            actions: ref.watch(_probeActionsProvider),
            participantId: 'p1',
          ),
        ),
        boardsApi: api,
      ));

      await tester.tap(find.byTooltip('從階段卸除'));
      await tester.pumpAndSettle();
      expect(find.text('移除這份素材？'), findsOneWidget);

      await tester.tap(find.text('卸除'));
      await tester.pumpAndSettle();

      // sf1 是掛接關係，a1 是附件——刪錯一個會把別的階段上的同一份素材
      // 一起帶走
      expect(api.removed, [('b1', 'c1', 'sf1')]);
    });

    testWidgets('按取消什麼都不打——確認框存在的意義就在這一條', (tester) async {
      final api = _FakeBoardsApi();
      await tester.pumpWidget(_host(
        Consumer(
          builder: (context, ref, _) => StageFilesList(
            boardId: 'b1',
            checklistId: 'c1',
            files: const [_file],
            actions: ref.watch(_probeActionsProvider),
            participantId: 'p1',
          ),
        ),
        boardsApi: api,
      ));

      await tester.tap(find.byTooltip('從階段卸除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(api.removed, isEmpty);
    });

    testWidgets('沒有動作可用時不畫卸除鈕——按下去只會是一個必定失敗的請求',
        (tester) async {
      await tester.pumpWidget(_host(const StageFilesList(
        boardId: 'b1',
        checklistId: 'c1',
        files: [_file],
        actions: null,
        participantId: 'p1',
        readOnly: true,
      )));

      expect(find.byTooltip('從階段卸除'), findsNothing);
    });
  });
}
