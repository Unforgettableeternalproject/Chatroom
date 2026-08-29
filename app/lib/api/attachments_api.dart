
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/attachment.dart';
import 'api_client.dart';

/// 上傳完成、尚未隨訊息送出的附件。
///
/// 上傳與發言是分開的兩次請求（Hub 的契約就是如此），中間這段時間附件已經在
/// 伺服器上、但不屬於任何訊息。這個型別就是那段中間狀態。
@immutable
class UploadedAttachment {
  const UploadedAttachment({
    required this.id,
    required this.filename,
    required this.mime,
    required this.size,
  });

  final String id;
  final String filename;
  final String mime;
  final int size;

  bool get isImage => mime.startsWith('image/');

  /// 給預覽列用；與 [Attachment.readableSize] 同一套算法。
  String get readableSize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(0)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class AttachmentsApi {
  AttachmentsApi(this._dio);

  final Dio _dio;

  /// 從本機路徑上傳。桌面選檔與拖放都走這條——不先讀進記憶體，
  /// dio 會串流送出，大檔才不會把 App 撐爆。
  Future<UploadedAttachment> uploadPath(
    String roomId, {
    required String participantId,
    required String path,
    required String filename,
    String? mime,
    ProgressCallback? onProgress,
    CancelToken? cancelToken,
  }) =>
      _upload(
        roomId,
        participantId: participantId,
        part: MultipartFile.fromFileSync(path, filename: filename),
        filename: filename,
        mime: mime,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );

  /// 從記憶體上傳。剪貼簿貼上的圖片沒有檔案路徑，只能走這條。
  Future<UploadedAttachment> uploadBytes(
    String roomId, {
    required String participantId,
    required Uint8List bytes,
    required String filename,
    String? mime,
    ProgressCallback? onProgress,
    CancelToken? cancelToken,
  }) =>
      _upload(
        roomId,
        participantId: participantId,
        part: MultipartFile.fromBytes(bytes, filename: filename),
        filename: filename,
        mime: mime,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );

  Future<UploadedAttachment> _upload(
    String roomId, {
    required String participantId,
    required MultipartFile part,
    required String filename,
    String? mime,
    ProgressCallback? onProgress,
    CancelToken? cancelToken,
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/rooms/$roomId/attachments',
          data: FormData.fromMap({'file': part}),
          options: Options(
            headers: {'X-Participant-Id': participantId},
            // 全域 sendTimeout 對大檔太短；上傳的時間由檔案大小決定，
            // 不是由伺服器反應速度決定
            sendTimeout: const Duration(minutes: 5),
            receiveTimeout: const Duration(minutes: 5),
          ),
          onSendProgress: onProgress,
          cancelToken: cancelToken,
        );
        final data = res.data!;
        return UploadedAttachment(
          id: data['id'] as String,
          filename: filename,
          // Hub 回的 mime 以它實際存下的為準，不用我們猜的那個
          mime: (data['mime'] as String?) ??
              mime ??
              'application/octet-stream',
          size: (data['size'] as int?) ?? 0,
        );
      });
}
