import '../../l10n/l10n.dart';

/// App 層例外家族。Server 的 HTTPException 一律回
/// `{"detail": {"code": "...", "message": "..."}}`——code 是穩定契約，
/// message 僅供人讀，client 絕不對 message 做字串比對。
sealed class ApiException implements Exception {
  const ApiException(this.code, String? message, [this.detail = const {}])
      : _message = message;

  /// server 的機器可讀錯誤碼（無法取得時為空字串）。
  final String code;

  /// Hub 的原話；null 代表這個型別自己講（見 [defaultMessage]）。
  final String? _message;

  /// 給使用者看的訊息。Hub 有原話就用原話。
  String get message => _message ?? defaultMessage;

  /// 沒有 Hub 原話時這個型別要說的那句話。
  ///
  /// **是 getter 不是建構子參數**：文字跟著語言走，而這些例外全是 `const`
  /// 建構的——把翻譯塞進建構子會讓每一處 `const XxxException()` 失效。
  String get defaultMessage => code;

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
  const AuthException([String code = 'invalid_token']) : super(code, null);

  @override
  String get defaultMessage => L10n.current.errorInvalidToken;
}

/// 401 + participant_header_required — 請求沒帶 `X-Participant-Id`。
///
/// **這是程式錯，不是設定錯**，所以不能沿用 [AuthException] 那句「API token
/// 無效」——token 明明是好的，其他畫面全部正常，只有漏帶身分的那個請求會
/// 死。把兩者混成同一句話，找的人會去翻設定頁，而錯在呼叫端。
class ParticipantHeaderMissingException extends ApiException {
  const ParticipantHeaderMissingException()
      : super('participant_header_required', null);

  @override
  String get defaultMessage => L10n.current.errorParticipantHeaderMissing;
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
    super.code = 'participant_not_active',
    super.message,
  ]);

  @override
  String get defaultMessage => L10n.current.errorParticipantInvalid;
}

/// 403 + root_token_required — 這台 Hub 由別人主持，發放/撤銷邀請的權限
/// 留在他那裡。
///
/// **不可與 [ParticipantInvalidException] 混用**：那個會觸發自動 re-join，
/// 而這裡的 403 跟房間身分毫無關係，重新加入一百次也不會變成主持人。
class RootTokenRequiredException extends ApiException {
  const RootTokenRequiredException([String? message])
      : super('root_token_required', message);

  @override
  String get defaultMessage => L10n.current.errorRootTokenRequired;
}

/// 403 + human_token_required — 手上這張憑證是 agent 憑證，而這個動作
/// （以 `role=human` 進房、開主持人視角）只認人類憑證。
///
/// 🔴 **絕不可以走 [ParticipantInvalidException]**：那個型別會觸發自動
/// re-join，而**重新加入一百次也不會讓一張 agent 憑證變成人類憑證**。
/// 那是一個永遠不會成功、看起來卻像連線卡住的迴圈。
///
/// 而且這條路徑的錯誤訊息特別要緊：它長得跟「你沒份」一模一樣——房間列表
/// 看得到公開房、邀請也收得到，點進去卻一律進不去。把它講成「你不是這個
/// 聊天室的成員」會讓人去找一個根本不存在的成員資格問題（09/12 實測，
/// 艾斯維爾在別人的 Hub 上花了一整晚）。真正要做的事在**發邀請的那一端**。
class HumanCredentialRequiredException extends ApiException {
  const HumanCredentialRequiredException([String? message])
      : super('human_token_required', message);

  @override
  String get defaultMessage => L10n.current.errorHumanCredentialRequired;
}

/// 403 + not_your_agent — 那個 agent 不是用你這張憑證接入的。
///
/// 指派的界線是「群」＝一個人連同他的 agent（艾斯維爾裁 2026-09-12）。
/// **主持人也沒有穿透口**——「我能指派所有人的 agent」與「別人能指派我的
/// agent」是同一條規則的兩面。
///
/// 🔴 同樣不可以走 [ParticipantInvalidException]：這與房間身分無關，
/// re-join 一百次也不會換掉接入時填的那把 token。
class NotYourAgentException extends ApiException {
  const NotYourAgentException([String? message])
      : super('not_your_agent', message);

  @override
  String get defaultMessage => L10n.current.errorNotYourAgent;
}

/// 403 + kind_not_allowed_for_supervisor — Supervisor 代派時的 kind 白名單
/// （Supervisor 自派工 2026-09-19）。
///
/// 🔴 同樣不可以走 [ParticipantInvalidException]：被擋的是**這張憑證不是
/// 人類**（只有人類派得了 `push`），與房內身分無關——re-join 一百次也不會
/// 讓 Supervisor 變成人。要做的事是請房內的人類自己按。
///
/// `kind` 從 Hub 的 detail 帶出來：講不出是哪一種，人就不知道換誰來按。
class SupervisorKindNotAllowedException extends ApiException {
  const SupervisorKindNotAllowedException(String? message,
      [Map<String, dynamic> detail = const {}])
      : super('kind_not_allowed_for_supervisor', message, detail);

  String get kind => (detail['kind'] as String?) ?? '';

  @override
  String get defaultMessage =>
      L10n.current.opsErrorSupervisorKindNotAllowed(
          kind.isEmpty ? L10n.current.commonUnknown : kind);
}

/// 403 + release_requires_human — 上板只有人類觸發得了，Supervisor agent
/// 也不行。
///
/// 🔴 同樣不可以走 [ParticipantInvalidException]：那個會觸發自動 re-join，
/// 而重新加入一百次也不會讓一張 agent 憑證變成人類憑證。上板會直接推上
/// 穩定分支，那個決定要有人負責。
class ReleaseRequiresHumanException extends ApiException {
  const ReleaseRequiresHumanException([String? message])
      : super('release_requires_human', message);

  @override
  String get defaultMessage => L10n.current.errorReleaseRequiresHuman;
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
  const NotFoundException([String code = 'not_found']) : super(code, null);

  @override
  String get defaultMessage => L10n.current.errorNotFound;
}

/// 409 — 房間已封存（唯讀）。
class RoomArchivedException extends ApiException {
  const RoomArchivedException([String code = 'room_archived'])
      : super(code, null);

  @override
  String get defaultMessage => L10n.current.errorRoomArchived;
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
      : super('archived_no_identity', null);

  @override
  String get defaultMessage => L10n.current.errorArchivedNoIdentity;
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
      : super('attachment_too_large', message);

  @override
  String get defaultMessage => L10n.current.errorAttachmentTooLarge;
}

/// 410 — metadata 還在、實體檔案已不在伺服器上（db 與 attachments/ 不同步）。
/// 對使用者而言不是「找不到」，是「這個東西回不來了」，訊息要講清楚。
class AttachmentGoneException extends ApiException {
  const AttachmentGoneException([String code = 'attachment_blob_missing'])
      : super(code, null);

  @override
  String get defaultMessage => L10n.current.errorAttachmentGone;
}

/// 連不上 Hub（逾時 / socket 錯誤）。
class NetworkException extends ApiException {
  const NetworkException() : super('network', null);

  @override
  String get defaultMessage => L10n.current.errorNetwork;
}

/// 其他 5xx。
class ServerException extends ApiException {
  ServerException(this.statusCode) : super('server_$statusCode', null);

  final int statusCode;

  @override
  String get defaultMessage => L10n.current.errorServer(statusCode);
}

/// 搬卡搬到一半：**新卡建好了，舊卡沒能標成「已搬走」**。
///
/// 搬卡是兩個寫入，而 Hub 沒有原子端點——中間斷掉必然留下一個中間狀態。
/// 兩個方向只有一個成立：先建卡再指過去，所以壞掉的形狀只有這一種
/// （反過來需要一個還不存在的 id，送不出去）。
///
/// ⚠️ **刻意不補償**（不刪掉剛建的那張新卡）。理由有兩個：那張卡是使用者
/// 真的要的東西，而刪除本身也會失敗——補償失敗留下的狀態更難對人講。
/// 所以這裡選擇把話講完整，讓人知道那邊已經多了一張卡：**不講的話，重按
/// 一次就會再建一張，而那才是真正的損害**。
class MoveHalfDoneException extends ApiException {
  MoveHalfDoneException(this.newTaskId, this.cause)
      : super('move_half_done', null);

  @override
  String get defaultMessage => L10n.current.errorMoveHalfDone(cause.message);

  /// 已經建好的那張卡。畫面要有辦法把人帶過去。
  final String newTaskId;

  /// 第二步實際上是怎麼失敗的。
  final ApiException cause;
}
