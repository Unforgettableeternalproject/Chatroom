import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';

enum ComposerAttachmentStatus { uploading, ready, failed }

/// 已挑選、尚未隨訊息送出的附件。
///
/// 上傳與發言是兩次請求，中間這段時間東西已經在 Hub 上但不屬於任何訊息——
/// 這個型別就是那段中間狀態。刻意做成「先傳完再發言」而不是「按送出才開始
/// 傳」：大檔上傳要好幾秒，把它塞進送出動作裡會讓輸入框僵住，而且傳到一半
/// 失敗時使用者已經按過送出了，重試就會變成重複發言。
class ComposerAttachment {
  ComposerAttachment({
    required this.localId,
    required this.filename,
    required this.mime,
    required this.size,
    this.path,
    this.bytes,
    this.status = ComposerAttachmentStatus.uploading,
    this.progress = 0,
    this.remoteId,
    this.error,
    this.cancelToken,
  });

  /// 本機識別碼。remoteId 要等上傳完成才有，但列表在那之前就得畫出來。
  final String localId;
  final String filename;
  final String mime;
  final int size;

  /// 二選一：選檔／拖放有路徑，剪貼簿貼上只有 bytes。
  final String? path;
  final Uint8List? bytes;

  final ComposerAttachmentStatus status;

  /// 0..1；size 為 0（未知）時 UI 改畫不定量進度。
  final double progress;

  /// 上傳完成後 Hub 給的 id，送訊息時用它。
  final String? remoteId;
  final String? error;
  final CancelToken? cancelToken;

  bool get isImage => mime.startsWith('image/');
  bool get isReady => status == ComposerAttachmentStatus.ready;

  String get readableSize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(0)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  ComposerAttachment copyWith({
    ComposerAttachmentStatus? status,
    double? progress,
    String? remoteId,
    String? error,
    CancelToken? cancelToken,
  }) =>
      ComposerAttachment(
        localId: localId,
        filename: filename,
        mime: mime,
        size: size,
        path: path,
        bytes: bytes,
        status: status ?? this.status,
        progress: progress ?? this.progress,
        remoteId: remoteId ?? this.remoteId,
        // error 要能被清掉（重試時），所以不用 ?? 沿用舊值
        error: status == ComposerAttachmentStatus.failed ? (error ?? this.error) : null,
        cancelToken: cancelToken ?? this.cancelToken,
      );
}

/// 輸入框上方的待送附件列。
class ComposerAttachmentBar extends StatelessWidget {
  const ComposerAttachmentBar({
    super.key,
    required this.attachments,
    required this.onRemove,
    required this.onRetry,
  });

  final List<ComposerAttachment> attachments;
  final void Function(ComposerAttachment) onRemove;
  final void Function(ComposerAttachment) onRetry;

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final a in attachments)
            _AttachmentChip(
              attachment: a,
              onRemove: () => onRemove(a),
              onRetry: () => onRetry(a),
            ),
        ],
      ),
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({
    required this.attachment,
    required this.onRemove,
    required this.onRetry,
  });

  final ComposerAttachment attachment;
  final VoidCallback onRemove;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final a = attachment;
    final failed = a.status == ComposerAttachmentStatus.failed;
    final uploading = a.status == ComposerAttachmentStatus.uploading;

    return Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.fromLTRB(9, 6, 4, 6),
      decoration: BoxDecoration(
        color: s.bgSunken,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
            color: failed ? UepColors.error.withValues(alpha: .6) : s.line),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(
          failed
              ? Icons.error_outline
              : a.isImage
                  ? Icons.image_outlined
                  : Icons.insert_drive_file_outlined,
          size: 14,
          color: failed ? UepColors.error : s.inkMute,
        ),
        const SizedBox(width: 7),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                a.filename,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: UepText.sans(
                    size: 12, weight: FontWeight.w600, color: s.inkTitle),
              ),
              const SizedBox(height: 2),
              Text(
                failed ? (a.error ?? '上傳失敗') : a.readableSize,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: UepText.mono(
                    size: 8.5,
                    color: failed ? UepColors.error : s.inkMute,
                    letterSpacing: 1.0),
              ),
              if (uploading) ...[
                const SizedBox(height: 4),
                SizedBox(
                  width: 120,
                  height: 2,
                  child: LinearProgressIndicator(
                    // size 未知時給不定量動畫，畫一條永遠停在 0 的條更像壞了
                    value: a.size > 0 ? a.progress.clamp(0.0, 1.0) : null,
                    backgroundColor: s.line,
                    color: UepColors.gold,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (failed)
          IconButton(
            tooltip: '重試',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.all(4),
            onPressed: onRetry,
            icon: Icon(Icons.refresh, size: 14, color: s.inkMute),
          ),
        IconButton(
          tooltip: uploading ? '取消上傳' : '移除',
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(),
          padding: const EdgeInsets.all(4),
          onPressed: onRemove,
          icon: Icon(Icons.close, size: 14, color: s.inkMute),
        ),
      ]),
    );
  }
}
