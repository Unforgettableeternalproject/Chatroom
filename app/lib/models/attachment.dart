import 'package:flutter/foundation.dart';

/// 訊息夾帶的檔案。內容存在 Hub 的磁碟上，這裡只有 metadata。
@immutable
class Attachment {
  const Attachment({
    required this.id,
    required this.filename,
    required this.mime,
    required this.size,
    required this.isImage,
  });

  final String id;

  /// 上傳者給的原始檔名。**僅供顯示**——它是不可信輸入，不可拿來組路徑。
  final String filename;
  final String mime;
  final int size;
  final bool isImage;

  /// 人看得懂的大小。
  String get readableSize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(0)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  factory Attachment.fromJson(Map<String, dynamic> json) => Attachment(
        id: json['id'] as String,
        filename: (json['filename'] as String?) ?? '檔案',
        mime: (json['mime'] as String?) ?? 'application/octet-stream',
        size: (json['size'] as int?) ?? 0,
        // is_image 由 Hub 判定；缺席時（舊版 Hub）從 mime 推
        isImage: (json['is_image'] as bool?) ??
            ((json['mime'] as String?) ?? '').startsWith('image/'),
      );
}
