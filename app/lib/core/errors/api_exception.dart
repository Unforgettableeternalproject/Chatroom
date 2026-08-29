/// App 層例外家族。Server 的 HTTPException 一律回
/// `{"detail": {"code": "...", "message": "..."}}`——code 是穩定契約，
/// message 僅供人讀，client 絕不對 message 做字串比對。
sealed class ApiException implements Exception {
  const ApiException(this.code, this.message);

  /// server 的機器可讀錯誤碼（無法取得時為空字串）。
  final String code;

  /// 給使用者看的中文訊息。
  final String message;

  @override
  String toString() => '$runtimeType($code): $message';
}

/// 401 — token 錯誤或未提供。設定問題，UI 導向設定頁。
class AuthException extends ApiException {
  const AuthException([String code = 'invalid_token'])
      : super(code, 'API token 無效，請至設定檢查');
}

/// 403 — participant 非 active 或不屬於此房。觸發自動 re-join，
/// 與 401 語意不同，不可合併處理。
class ParticipantInvalidException extends ApiException {
  const ParticipantInvalidException([String code = 'participant_not_active'])
      : super(code, '你的房間身分已失效，正在重新加入…');
}

/// 404 — 房間 / 訊息 / 指派不存在。
class NotFoundException extends ApiException {
  const NotFoundException([String code = 'not_found'])
      : super(code, '找不到指定的房間或訊息');
}

/// 409 — 房間已封存（唯讀）。
class RoomArchivedException extends ApiException {
  const RoomArchivedException([String code = 'room_archived'])
      : super(code, '此聊天室已封存，無法發言');
}

/// 422 — 請求內容不合法（如 reply_to 目標不存在）。
class ValidationException extends ApiException {
  const ValidationException(super.code, super.message);
}

/// 413 — 附件超過 Hub 設定的上限。這是**使用者可修正**的錯誤（換個小一點的
/// 檔案），與 5xx 的「伺服器壞了」語意完全不同，不可讓它掉進 ServerException。
class AttachmentTooLargeException extends ApiException {
  /// [message] 用 Hub 回的那句——它知道實際上限是幾 MB，我們不知道。
  const AttachmentTooLargeException([String? message])
      : super('attachment_too_large', message ?? '檔案超過伺服器允許的大小上限');
}

/// 410 — metadata 還在、實體檔案已不在伺服器上（db 與 attachments/ 不同步）。
/// 對使用者而言不是「找不到」，是「這個東西回不來了」，訊息要講清楚。
class AttachmentGoneException extends ApiException {
  const AttachmentGoneException([String code = 'attachment_blob_missing'])
      : super(code, '附件內容已不在伺服器上（資料庫與附件目錄可能不同步）');
}

/// 連不上 Hub（逾時 / socket 錯誤）。
class NetworkException extends ApiException {
  const NetworkException()
      : super('network', '無法連線到 Hub，請確認伺服器位址');
}

/// 其他 5xx。
class ServerException extends ApiException {
  ServerException(int statusCode)
      : super('server_$statusCode', '伺服器發生錯誤（HTTP $statusCode）');
}
