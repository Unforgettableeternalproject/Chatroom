import 'dart:typed_data';

import 'package:chatroom_app/api/attachments_api.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/composer_attachments.dart';
import 'package:chatroom_app/state/messages_providers.dart';
import 'package:chatroom_app/widgets/composer_attachments.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 不打網路，直接回一個 id——這裡要驗的是「東西留在哪一房」，不是上傳本身。
class _FakeAttachmentsApi extends AttachmentsApi {
  _FakeAttachmentsApi() : super(Dio());

  int uploads = 0;

  @override
  Future<UploadedAttachment> uploadBytes(
    String roomId, {
    required String participantId,
    required Uint8List bytes,
    required String filename,
    String? mime,
    ProgressCallback? onProgress,
    CancelToken? cancelToken,
  }) async {
    uploads++;
    return UploadedAttachment(
      id: 'remote-$uploads',
      filename: filename,
      mime: mime ?? 'image/png',
      size: bytes.length,
    );
  }
}

ProviderContainer _container(_FakeAttachmentsApi api) => ProviderContainer(
      overrides: [
        attachmentsApiProvider.overrideWithValue(api),
        identityProvider.overrideWith(
          (ref, roomId) async =>
              (participantId: 'p-$roomId', displayName: '艾斯維爾'),
        ),
      ],
    );

Future<String?> _paste(
  ProviderContainer c,
  String roomId, {
  int size = 8,
  int maxBytes = 1024,
}) =>
    c.read(composerAttachmentsProvider.notifier).enqueue(
          roomId,
          filename: '貼上的圖片.png',
          size: size,
          maxBytes: maxBytes,
          bytes: Uint8List(size),
          mime: 'image/png',
        );

void main() {
  late _FakeAttachmentsApi api;
  late ProviderContainer c;

  setUp(() {
    api = _FakeAttachmentsApi();
    c = _container(api);
  });

  tearDown(() => c.dispose());

  test('附件依房分開——貼進 A 房的圖不會出現在 B 房', () async {
    await _paste(c, 'A');
    final drafts = c.read(composerAttachmentsProvider.notifier);
    expect(drafts.of('A'), hasLength(1));
    expect(drafts.of('B'), isEmpty);
  });

  test('🔴 這條是本次修的 bug：切走再回來，附件還在'
      '（從前它活在隨房重建的 State 裡，切房就沒了）', () async {
    await _paste(c, 'A');
    // 切到 B 房逛一圈——舊實作在這一步就把 A 房的待送附件連同上傳一起丟掉
    await _paste(c, 'B');
    final drafts = c.read(composerAttachmentsProvider.notifier);
    expect(drafts.of('A'), hasLength(1));
    expect(drafts.of('A').single.remoteId, 'remote-1');
    expect(drafts.of('B'), hasLength(1));
  });

  test('上傳完成的狀態寫得回去——畫面不在也一樣', () async {
    await _paste(c, 'A');
    final a = c.read(composerAttachmentsProvider.notifier).of('A').single;
    expect(a.status, ComposerAttachmentStatus.ready);
    expect(a.progress, 1);
  });

  test('超過單檔上限就不排進去，並說明原因', () async {
    final why = await _paste(c, 'A', size: 4096, maxBytes: 1024);
    expect(why, contains('超過上限'));
    expect(c.read(composerAttachmentsProvider.notifier).of('A'), isEmpty);
    expect(api.uploads, 0);
  });

  test('一則訊息最多 10 個附件，第 11 個被擋下', () async {
    for (var i = 0; i < 10; i++) {
      expect(await _paste(c, 'A'), isNull);
    }
    expect(await _paste(c, 'A'), contains('最多 10 個'));
    expect(c.read(composerAttachmentsProvider.notifier).of('A'), hasLength(10));
  });

  test('送出後清掉的只有那一房', () async {
    await _paste(c, 'A');
    await _paste(c, 'B');
    final drafts = c.read(composerAttachmentsProvider.notifier);
    drafts.clear('A');
    expect(drafts.of('A'), isEmpty);
    expect(drafts.of('B'), hasLength(1));
  });

  test('移除一個附件不影響同房其他的', () async {
    await _paste(c, 'A');
    await _paste(c, 'A');
    final drafts = c.read(composerAttachmentsProvider.notifier);
    final first = drafts.of('A').first;
    drafts.remove('A', first);
    expect(drafts.of('A'), hasLength(1));
    expect(drafts.of('A').single.localId, isNot(first.localId));
  });
}
