import 'dart:async';
import 'dart:typed_data';

import 'package:chatroom_app/api/attachments_api.dart';
import 'package:chatroom_app/api/board_api.dart';
import 'package:chatroom_app/core/errors/api_exception.dart';
import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/stage_file.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:chatroom_app/state/messages_providers.dart';
import 'package:chatroom_app/widgets/stage_files.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/l10n.dart';

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
  final noteEdits = <(String, String, String, String)>[];

  @override
  Future<StageFile?> updateStageFileNote(
    String boardId,
    String checklistId,
    String fileId, {
    required String note,
    String? participantId,
    String? sessionKey,
  }) async {
    noteEdits.add((boardId, checklistId, fileId, note));
    return null;
  }

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

/// 記下「取附件時報上的是哪一種身分」。板庫路由（`/boards/:id`）沒有房，
/// 身分只有 session key——這份假件要看住那條路不會在還沒發請求就短路。
class _FakeAttachmentsApi extends AttachmentsApi {
  _FakeAttachmentsApi() : super(Dio());

  final calls = <(String?, String?)>[];

  @override
  Future<Uint8List> download(
    String attachmentId, {
    String? participantId,
    String? sessionKey,
    ProgressCallback? onProgress,
  }) async {
    calls.add((participantId, sessionKey));
    // 測試環境沒有「交給系統程式開」的下一步，記完就讓它走失敗路徑
    throw const AttachmentGoneException();
  }
}

/// 板軸的動作：測試裡沒有房，身分走 session key（[AppConfig.deviceKey]）。
final _probeActionsProvider =
    Provider<BoardActions>((ref) => BoardActions.forBoard(ref, 'b1'));

Widget _host(Widget child,
        {BoardsApi? boardsApi, AttachmentsApi? attachmentsApi}) =>
    ProviderScope(
      overrides: [
        if (boardsApi != null) boardsApiProvider.overrideWithValue(boardsApi),
        if (attachmentsApi != null)
          attachmentsApiProvider.overrideWithValue(attachmentsApi),
        initialConfigProvider.overrideWithValue(const AppConfig(
          serverUrl: 'http://hub.test',
          token: 'tok',
          themeMode: ThemeModePref.dark,
          preferredName: 'Bernie',
          deviceKey: 'device-key',
        )),
      ],
      child: MaterialApp(
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: kTestSupportedLocales,
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

    testWidgets('編輯備註：帶現有那句當預設值，確認之後打 PATCH',
        (tester) async {
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

      await tester.tap(find.byTooltip('編輯備註'));
      await tester.pumpAndSettle();
      // 現有備註是預設值：編輯不是重打
      expect(
          find.descendant(
              of: find.byType(TextField), matching: find.text('這輪要對照的 log')),
          findsOneWidget);

      await tester.enterText(find.byType(TextField), '改過的說明');
      await tester.tap(find.text('儲存'));
      await tester.pumpAndSettle();

      expect(api.noteEdits, [('b1', 'c1', 'sf1', '改過的說明')]);
    });

    testWidgets('編輯備註按取消什麼都不打', (tester) async {
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

      await tester.tap(find.byTooltip('編輯備註'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(api.noteEdits, isEmpty);
    });

    testWidgets('沒有動作可用時不畫編輯鈕', (tester) async {
      await tester.pumpWidget(_host(const StageFilesList(
        boardId: 'b1',
        checklistId: 'c1',
        files: [_file],
        actions: null,
        participantId: 'p1',
        readOnly: true,
      )));

      expect(find.byTooltip('編輯備註'), findsNothing);
    });
  });

  group('點開素材的身分', () {
    testWidgets('🔴 板庫路由沒有房：身分走 session key，不該停在「身分待定」',
        (tester) async {
      final api = _FakeAttachmentsApi();
      await tester.pumpWidget(_host(
        const StageFilesList(
          boardId: 'b1',
          checklistId: 'c1',
          files: [_file],
          actions: null,
          // `/boards/:id` 進來的板：沒有 participant
          participantId: null,
          useSessionKey: true,
        ),
        attachmentsApi: api,
      ));

      await tester.tap(find.text('run.log'));
      await tester.pumpAndSettle();

      expect(api.calls, [(null, 'device-key')],
          reason: '只認 participant 的話這條路連請求都不會發出去');
      expect(find.text('還在取得房間身分，稍候再試'), findsNothing);
    });

    testWidgets('兩種身分都沒有才是「身分待定」', (tester) async {
      final api = _FakeAttachmentsApi();
      await tester.pumpWidget(_host(
        const StageFilesList(
          boardId: 'b1',
          checklistId: 'c1',
          files: [_file],
          actions: null,
        ),
        attachmentsApi: api,
      ));

      await tester.tap(find.text('run.log'));
      await tester.pumpAndSettle();

      expect(api.calls, isEmpty);
      expect(find.text('還在取得房間身分，稍候再試'), findsOneWidget);
    });

    testWidgets('房軸行為不變：帶的是 participant', (tester) async {
      final api = _FakeAttachmentsApi();
      await tester.pumpWidget(_host(
        const StageFilesList(
          boardId: 'b1',
          checklistId: 'c1',
          files: [_file],
          actions: null,
          participantId: 'p1',
        ),
        attachmentsApi: api,
      ));

      await tester.tap(find.text('run.log'));
      await tester.pumpAndSettle();

      expect(api.calls, [('p1', null)]);
    });
  });

  group('多檔匯入', () {
    test('只有一個檔才問備註——選了八個檔不該連開八次對話框', () {
      expect(shouldAskStageNote(1), isTrue);
      expect(shouldAskStageNote(2), isFalse);
      expect(shouldAskStageNote(8), isFalse);
    });
  });

  group('卸除素材（續）', () {
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

  group('加素材', () {
    testWidgets(
        '🔴 選檔期間畫面重建過一次，選好的檔照樣上傳並掛上——不可以靜默丟掉',
        (tester) async {
      final uploads = _RecordingAttachmentsApi();
      final boards = _RecordingBoardsApi();
      final picking = Completer<List<PlatformFile>>();
      // 按鈕所在的那一層：切成 false 就是「板重拉、底下整棵樹換掉」
      final showButton = ValueNotifier(true);
      addTearDown(showButton.dispose);

      await tester.pumpWidget(ProviderScope(
        overrides: [
          boardsApiProvider.overrideWithValue(boards),
          attachmentsApiProvider.overrideWithValue(uploads),
          identityProvider.overrideWith((ref, roomId) async =>
              (participantId: 'p-$roomId', displayName: '艾斯維爾')),
          initialConfigProvider.overrideWithValue(const AppConfig(
            serverUrl: 'http://hub.test',
            token: 'tok',
            themeMode: ThemeModePref.dark,
            preferredName: 'Bernie',
            deviceKey: 'device-key',
          )),
        ],
        child: MaterialApp(
          localizationsDelegates: kTestLocalizationsDelegates,
          supportedLocales: kTestSupportedLocales,
          theme: buildUepTheme(Brightness.dark),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => ValueListenableBuilder<bool>(
                valueListenable: showButton,
                builder: (_, show, _) => show
                    ? Builder(
                        builder: (buttonContext) => TextButton(
                          onPressed: () => pickAndAttachStageFile(
                            buttonContext,
                            boardId: 'b1',
                            checklistId: 'c1',
                            roomId: 'r1',
                            actions: ref.read(_roomActionsProvider),
                            pickFiles: () => picking.future,
                          ),
                          child: const Text('加'),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('加'));
      await tester.pump();

      // 檔案對話框還開著時板重拉了一次
      showButton.value = false;
      await tester.pump();
      expect(find.text('加'), findsNothing);

      // 選兩個檔：多檔不問備註，走的是逐檔上傳那條迴圈
      picking.complete([
        _PickedFile('a.log', r'C:\tmp\a.log'),
        _PickedFile('b.png', r'C:\tmp\b.png'),
      ]);
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }

      expect(uploads.uploaded, ['a.log', 'b.png'],
          reason: '選好的檔在重建之後沒被送出去');
      expect(boards.attached, [('b1', 'c1', 'up-a.log'), ('b1', 'c1', 'up-b.png')]);
    });
  });
}

/// 房軸的動作——「加素材」只有房軸有（附件要上傳到一間房）。
final _roomActionsProvider =
    Provider<BoardActions>((ref) => BoardActions(ref, 'r1'));

/// 測試用的選檔結果。只有名字與路徑是這條路會讀的。
final class _PickedFile extends PlatformFile {
  _PickedFile(this.name, this._path);

  @override
  final String name;
  final String _path;

  @override
  String? get path => _path;

  @override
  Uri get uri => Uri.file(_path, windows: true);

  @override
  get xFile => throw UnimplementedError();

  @override
  Future<int> length() async => 0;

  @override
  Future<Uint8List> readAsBytes() async => Uint8List(0);

  @override
  Stream<Uint8List> readAsByteStream() => const Stream.empty();
}

class _RecordingAttachmentsApi extends AttachmentsApi {
  _RecordingAttachmentsApi() : super(Dio());

  final uploaded = <String>[];

  @override
  Future<UploadedAttachment> uploadPath(
    String roomId, {
    required String participantId,
    required String path,
    required String filename,
    String? mime,
    ProgressCallback? onProgress,
    CancelToken? cancelToken,
  }) async {
    uploaded.add(filename);
    return UploadedAttachment(
        id: 'up-$filename', filename: filename, mime: mime ?? '', size: 0);
  }
}

class _RecordingBoardsApi extends BoardsApi {
  _RecordingBoardsApi() : super(Dio());

  final attached = <(String, String, String)>[];

  @override
  Future<StageFile> addStageFile(
    String boardId,
    String checklistId, {
    required String attachmentId,
    String note = '',
    String? participantId,
    String? sessionKey,
  }) async {
    attached.add((boardId, checklistId, attachmentId));
    return StageFile(
      id: 'sf-$attachmentId',
      checklistId: checklistId,
      attachmentId: attachmentId,
      filename: '',
      mime: '',
      size: 0,
    );
  }
}
