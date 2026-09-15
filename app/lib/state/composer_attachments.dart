import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors/api_exception.dart';
import '../widgets/composer_attachments.dart';
import 'app_providers.dart';
import 'messages_providers.dart';

/// 還沒送出的**附件**，依房間分開——與 [composerDraftsProvider] 同族。
///
/// ## 為什麼不能留在 `_MessageComposerState` 裡
///
/// 草稿那次修法給了 `ChatScreen` 一個 `ValueKey(roomId)`，讓 State 隨房重建
/// ——那治好了「打到一半的字跑到別的房」，也治好了更嚴重的「附件在別的房
/// 被送出去」。但附件當時沒有跟著搬到房間層級，所以它換了一個症狀：
/// **切走再回來，剛貼的截圖全部不見**（艾斯維爾 2026-09-03）。
///
/// 那不只是「東西沒了」。舊的 `dispose` 還會把上傳中的項目 `cancel` 掉，
/// 理由是「傳完會往一個已 dispose 的 State 寫結果」——理由成立，但代價是
/// 切個房間就把已經傳到一半的大檔砍掉重來。
///
/// ## 所以上傳也搬進來
///
/// 這裡不只存清單，**上傳整條流程都在這裡跑**。Notifier 的生命週期是 App
/// 級的，寫結果時不必問「畫面還在不在」，於是：
///
/// - 切走再回來，附件還在，進度條接著跑
/// - 沒有任何理由需要在離開畫面時取消上傳
///
/// 取消只剩一個來源：**使用者自己按叉叉**。
///
/// ## 只在記憶體
///
/// 同 [composerDraftsProvider] 的理由：這是「這一輪還沒送出的東西」。
/// 而且附件的 `remoteId` 綁在 Hub 上，跨啟動保留會指向一批無主附件。
class ComposerAttachmentDrafts
    extends Notifier<Map<String, List<ComposerAttachment>>> {
  @override
  Map<String, List<ComposerAttachment>> build() => const {};

  /// Hub 的 `attachment_ids` 上限。超過會整則訊息被擋下來。
  static const maxPerMessage = 10;

  List<ComposerAttachment> of(String roomId) => state[roomId] ?? const [];

  void _put(String roomId, List<ComposerAttachment> next) {
    if (next.isEmpty) {
      if (!state.containsKey(roomId)) return;
      state = {...state}..remove(roomId);
      return;
    }
    state = {...state, roomId: next};
  }

  /// 挑好一個檔案，排進待送清單並開始上傳。
  ///
  /// 回傳非 null 表示**沒有排進去**，字串是要給人看的原因——擋下來的判斷
  /// （大小、數量）留在這裡，但顯示是畫面的事。
  Future<String?> enqueue(
    String roomId, {
    required String filename,
    required int size,
    required int maxBytes,
    String? path,
    Uint8List? bytes,
    String? mime,
  }) async {
    if (size > maxBytes) {
      // 先擋在本機：明知會被拒絕還是把整個檔案推上去，只是白白佔用頻寬與時間
      final mb = (maxBytes / (1024 * 1024)).toStringAsFixed(0);
      return '$filename 超過上限 $mb MB，未加入';
    }
    final current = of(roomId);
    if (current.length >= maxPerMessage) {
      return '一則訊息最多 $maxPerMessage 個附件';
    }
    final item = ComposerAttachment(
      localId: '${DateTime.now().microsecondsSinceEpoch}-${current.length}',
      filename: filename,
      mime: mime ?? guessMime(filename),
      size: size,
      path: path,
      bytes: bytes,
      cancelToken: CancelToken(),
    );
    _put(roomId, [...current, item]);
    await _upload(roomId, item);
    return null;
  }

  void _replace(String roomId, String localId, ComposerAttachment next) {
    final current = of(roomId);
    final i = current.indexWhere((a) => a.localId == localId);
    if (i < 0) return; // 使用者已經把它移掉了
    _put(roomId, [...current]..[i] = next);
  }

  Future<void> _upload(String roomId, ComposerAttachment item) async {
    final api = ref.read(attachmentsApiProvider);
    try {
      final identity = await ref.read(identityProvider(roomId).future);
      void onProgress(int sent, int total) {
        if (total <= 0) return;
        _replace(roomId, item.localId, item.copyWith(progress: sent / total));
      }

      final uploaded = item.bytes != null
          ? await api.uploadBytes(
              roomId,
              participantId: identity.participantId,
              bytes: item.bytes!,
              filename: item.filename,
              mime: item.mime,
              onProgress: onProgress,
              cancelToken: item.cancelToken,
            )
          : await api.uploadPath(
              roomId,
              participantId: identity.participantId,
              path: item.path!,
              filename: item.filename,
              mime: item.mime,
              onProgress: onProgress,
              cancelToken: item.cancelToken,
            );
      _replace(
        roomId,
        item.localId,
        item.copyWith(
          status: ComposerAttachmentStatus.ready,
          progress: 1,
          remoteId: uploaded.id,
        ),
      );
    } on ApiException catch (e) {
      _replace(
        roomId,
        item.localId,
        item.copyWith(
          status: ComposerAttachmentStatus.failed,
          error: e.message,
        ),
      );
    } on DioException catch (e) {
      // 取消是使用者自己按的，不是錯誤——那個項目已經被移掉了
      if (CancelToken.isCancel(e)) return;
      _replace(
        roomId,
        item.localId,
        item.copyWith(status: ComposerAttachmentStatus.failed, error: '上傳失敗'),
      );
    }
  }

  void remove(String roomId, ComposerAttachment a) {
    if (a.status == ComposerAttachmentStatus.uploading) {
      a.cancelToken?.cancel('使用者取消');
    }
    _put(roomId, [
      for (final x in of(roomId))
        if (x.localId != a.localId) x,
    ]);
  }

  Future<void> retry(String roomId, ComposerAttachment a) async {
    final fresh = a.copyWith(
      status: ComposerAttachmentStatus.uploading,
      progress: 0,
      cancelToken: CancelToken(),
    );
    _replace(roomId, a.localId, fresh);
    await _upload(roomId, fresh);
  }

  /// 送出成功之後叫它。**清掉的是那一房**，不是全部。
  void clear(String roomId) => _put(roomId, const []);

  static String guessMime(String filename) {
    final ext = filename.contains('.')
        ? filename.split('.').last.toLowerCase()
        : '';
    return switch (ext) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'bmp' => 'image/bmp',
      'svg' => 'image/svg+xml',
      'pdf' => 'application/pdf',
      'txt' || 'log' || 'md' => 'text/plain',
      'json' => 'application/json',
      'zip' => 'application/zip',
      _ => 'application/octet-stream',
    };
  }
}

final composerAttachmentsProvider =
    NotifierProvider<ComposerAttachmentDrafts,
        Map<String, List<ComposerAttachment>>>(ComposerAttachmentDrafts.new);
