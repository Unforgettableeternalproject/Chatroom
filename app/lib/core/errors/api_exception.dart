/// App 層例外家族。Server 的 HTTPException 一律回
/// `{"detail": {"code": "...", "message": "..."}}`——code 是穩定契約，
/// message 僅供人讀，client 絕不對 message 做字串比對。
sealed class ApiException implements Exception {
  const ApiException(this.code, this.message, [this.detail = const {}]);

  /// server 的機器可讀錯誤碼（無法取得時為空字串）。
  final String code;

  /// 給使用者看的中文訊息。
  final String message;

  /// Hub 塞在 `detail` 裡的其餘欄位（原樣）。
  ///
  /// **不要為每個新欄位長一個新的例外型別**——Hub 用 `_err(**extra)` 把
  /// 「往下走的資訊」放進拒絕裡（`allowed`、`reopen_to`、`open`⋯⋯），那是
  /// 一個開放集合。把它原樣留著，需要的呼叫端自己取，新增欄位時 client
  /// 不必跟著改型別。
  ///
  /// ⚠️ 但 `code` 仍是唯一穩定的契約：**先看 code 再取欄位**，不要對
  /// `message` 做字串比對。
  final Map<String, dynamic> detail;

  @override
  String toString() => '$runtimeType($code): $message';
}

/// 401 — token 錯誤或未提供。設定問題，UI 導向設定頁。
class AuthException extends ApiException {
  const AuthException([String code = 'invalid_token'])
      : super(code, 'API token 無效，請至設定檢查');
}

/// 401 + participant_header_required — 請求沒帶 `X-Participant-Id`。
///
/// **這是程式錯，不是設定錯**，所以不能沿用 [AuthException] 那句「API token
/// 無效」——token 明明是好的，其他畫面全部正常，只有漏帶身分的那個請求會
/// 死。把兩者混成同一句話，找的人會去翻設定頁，而錯在呼叫端。
class ParticipantHeaderMissingException extends ApiException {
  const ParticipantHeaderMissingException()
      : super('participant_header_required',
            '這個畫面沒有帶上房間身分（程式問題，與 API token 無關）');
}

/// 403 — participant 非 active 或不屬於此房。觸發自動 re-join，
/// 與 401 語意不同，不可合併處理。
///
/// ⚠️ **訊息一律優先用 Hub 的原話**。同一個型別接住的 403 其實有兩種語境：
/// heartbeat／發言時的「身分真的過期了」（會 re-join），以及封存、收回邀請
/// 這類房內管理動作的「你沒有這個資格」（不會 re-join，也不該 re-join）。
/// 寫死「正在重新加入…」會在後者身上說出一件不會發生的事——使用者按了封存
/// 卻被告知系統正在幫他重新加入，那句話跟他做的事毫無關係。
///
/// re-join 的判定看的是**型別**（`on ParticipantInvalidException`），不是這句
/// 話，所以換掉 message 不影響自癒行為。
class ParticipantInvalidException extends ApiException {
  const ParticipantInvalidException([
    String code = 'participant_not_active',
    String? message,
  ]) : super(code, message ?? '你的房間身分已失效，正在重新加入…');
}

/// 403 + root_token_required — 這台 Hub 由別人主持，發放/撤銷邀請的權限
/// 留在他那裡。
///
/// **不可與 [ParticipantInvalidException] 混用**：那個會觸發自動 re-join，
/// 而這裡的 403 跟房間身分毫無關係，重新加入一百次也不會變成主持人。
class RootTokenRequiredException extends ApiException {
  const RootTokenRequiredException([String? message])
      : super('root_token_required',
            message ?? '只有 Hub 主持人能發放或撤銷邀請');
}

/// 403 — 你不是這塊板的成員（`not_board_member` / `not_board_owner` /
/// `not_board_supervisor`）。
///
/// 🔴 **絕不可以與 [ParticipantInvalidException] 共用型別**：那個型別會觸發
/// 自動 re-join，而**重新加入聊天室一百次也不會讓你出現在板的成員列上**。
/// 板的成員資格與房內身分是兩件事（艾斯維爾裁決 A+，2026-09-02）——這正是
/// 那個裁決要分開的東西。
///
/// 而且這多半**不是錯誤，是狀態**：房裡的人本來就不自動是板成員。
/// 呈現時該講「請板的 owner 把你加進來」，不是任何紅色的東西。
class BoardAccessException extends ApiException {
  const BoardAccessException(super.code, super.message, [super.detail]);

  /// Hub 在被擋下的回應裡附上這兩個值——**那是這時候唯一還拿得到的東西**，
  /// 落地畫面靠它們講出「這間房掛著哪塊板」，不必再打一次必然再被擋的 API。
  String get boardId => (detail['board_id'] as String?) ?? '';
  String get boardName => (detail['board_name'] as String?) ?? '';
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

/// 409 — 與**目前狀態**衝突：卡被別人領走了、狀態轉移不合法⋯⋯
///
/// **與 [RoomArchivedException] 分開，理由同 403 那組**：409 不是只有一種，
/// 而把「這張卡已經被 Swift-Falcon 領走了」講成「此聊天室已封存，無法發言」，
/// 會讓人去找一個根本沒有封存的房間。
///
/// ⚠️ 這一類**多半不是錯誤**。兩個 agent 同時認領同一張卡，本來就只有一個
/// 會成功——輸的那個要拿到的是「誰贏了」這個事實，不是一個錯誤畫面。
class ConflictException extends ApiException {
  const ConflictException(String code, String message,
      {this.allowed = const [], Map<String, dynamic> detail = const {}})
      : super(code, message, detail);

  /// `invalid_transition` 時，Hub 告訴你從現在這個狀態還能去哪。
  ///
  /// 有它就不必在 App 這側複製一份轉移表——那份副本會與 Hub 各自演化，
  /// 而畫面上多出一顆按不動的按鈕不會有任何地方報錯。
  final List<String> allowed;
}

/// 封存房唯讀瀏覽時，本機沒有這個房間的身分。
///
/// 封存房**不能 join**（Hub 的 join 一開頭就擋 409 `room_archived`），所以
/// 唯讀瀏覽靠的是「我曾經是誰」——那份 id 存在本機。沒有它表示從沒進過這個
/// 房間，而封存之後也加不進去了。
///
/// **不可以沿用 [ParticipantInvalidException]**：那個會觸發自動 re-join，
/// 而這裡 re-join 一百次都會被同一個 409 擋下來。
class ArchivedWithoutIdentityException extends ApiException {
  const ArchivedWithoutIdentityException()
      : super('archived_no_identity',
            '這個聊天室已封存，而你沒有加入過它——封存後無法再加入');
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
