import 'package:flutter/foundation.dart';

import 'attachment.dart';

/// 掛在階段（checklist）上的素材。
///
/// 附件本身仍是房內的 `attachment`（上傳走 `POST /api/rooms/{rid}/attachments`），
/// 這一列只是「這份附件屬於這個階段」的關係，外加一句 [note] 說它是什麼。
///
/// **素材屬於階段，不屬於某一張卡**：同一個階段底下的卡與 run 共用它。
/// 契約見階段素材契約（2026-09-17）。
@immutable
class StageFile {
  const StageFile({
    required this.id,
    required this.checklistId,
    required this.attachmentId,
    required this.filename,
    this.mime = 'application/octet-stream',
    this.size = 0,
    this.addedBy = '',
    this.addedByName = '',
    this.note = '',
    this.createdAt = '',
  });

  /// 這條掛接關係的 id。**卸除用的是它，不是 [attachmentId]**——同一份附件
  /// 可以掛在不同階段上，拿附件 id 去刪會刪錯一個。
  final String id;
  final String checklistId;
  final String attachmentId;

  /// 上傳者給的原始檔名。僅供顯示，不可拿來組路徑。
  final String filename;
  final String mime;
  final int size;

  /// 掛的人（actor_key）與他當時的顯示名。名字是快照——Hub 不反查，
  /// 掛的人可能早就不在任何一間房裡了。
  final String addedBy;
  final String addedByName;

  /// 一句話：這份素材是什麼。可以是空的。
  final String note;
  final String createdAt;

  bool get isImage => mime.startsWith('image/');

  /// 人看得懂的大小。與 [Attachment.readableSize] 同一套算法。
  String get readableSize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(0)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// 轉成附件，交給既有的附件元件預覽／下載。
  ///
  /// ⚠️ **id 用 [attachmentId]**：那些元件打的是
  /// `GET /api/attachments/{id}`，掛接關係的 id 在那條路徑上不存在。
  Attachment get asAttachment => Attachment(
        id: attachmentId,
        filename: filename,
        mime: mime,
        size: size,
        isImage: isImage,
      );

  factory StageFile.fromJson(Map<String, dynamic> json) => StageFile(
        id: (json['id'] as String?) ?? '',
        checklistId: (json['checklist_id'] as String?) ?? '',
        attachmentId: (json['attachment_id'] as String?) ?? '',
        filename: (json['filename'] as String?) ?? '檔案',
        mime: (json['mime'] as String?) ?? 'application/octet-stream',
        size: (json['size'] as int?) ?? 0,
        addedBy: (json['added_by'] as String?) ?? '',
        addedByName: (json['added_by_name'] as String?) ?? '',
        note: (json['note'] as String?) ?? '',
        createdAt: (json['created_at'] as String?) ?? '',
      );

  /// 從 Hub 回的清單解析。
  ///
  /// 🔴 **缺鍵一律回空列表**：舊 Hub 的 checklist 沒有 `files` 這個鍵，而
  /// 板的解析是全 App 共用的一條路——在這裡丟例外的話，一台還沒升級的 Hub
  /// 會讓整塊板讀不出來，而畫面上只會是一句「讀取失敗」。
  static List<StageFile> listFrom(dynamic raw) {
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map<String, dynamic>) StageFile.fromJson(e),
    ];
  }
}
