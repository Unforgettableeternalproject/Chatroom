import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 設定儲存分兩層（UI-DESIGN §1.5）：
/// - flutter_secure_storage：api_token、device_session_key（機密 / 同生命週期）
/// - shared_preferences：server_url、主題、各房 participant 快取等 UI 偏好
class SettingsRepository {
  SettingsRepository(this._prefs, [FlutterSecureStorage? secure])
      : _secure = secure ?? const FlutterSecureStorage();

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;

  static const _kServerUrl = 'chatroom.server_url';
  static const _kThemeMode = 'chatroom.theme_mode';
  static const _kFontScale = 'chatroom.font_scale';
  static const _kFontFamily = 'chatroom.font_family';
  static const _kLocale = 'chatroom.locale';
  static const _kPreferredName = 'chatroom.preferred_name';
  static const _kToken = 'chatroom.api_token';
  static const _kDeviceKey = 'chatroom.device_session_key';
  static const _kLastReadPrefix = 'chatroom.last_read.';
  static const _kParticipantPrefix = 'chatroom.participant.';

  /// 每個房「已經把 board 變動通知到哪個水位」。
  ///
  /// **必須落盤**：Hub 在訂閱時會推當前 board 水位，而 dispatcher 的水位
  /// 只在記憶體——每次 App 或 Hub 重啟都會把現況當成新變動再喚醒一次，
  /// 而已經進 Codex queue 的東西撤不回來（2026-09-14 實機）。
  static const _kBoardNotifiedPrefix = 'chatroom.board.notified.';
  static const _kDisplayNamePrefix = 'chatroom.display_name.';
  static const _kSeenSessionKeys = 'chatroom.seen_session_keys';
  static const _kHiddenMembersPrefix = 'chatroom.hidden_members.';
  static const _kHighlightedMembersPrefix = 'chatroom.highlighted_members.';
  static const _kPendingMentionPrefix = 'chatroom.pending_mention.';
  static const _kNotifyMode = 'chatroom.notify_mode';
  static const _kCloseToTray = 'chatroom.close_to_tray';
  static const _kCodexDispatch = 'chatroom.codex_dispatch';
  static const _kCodexThread = 'chatroom.codex_thread';
  static const _kOpsExceptionSeen = 'ops.exceptions.seenAt';
  static const _kLeftPaneWidth = 'chatroom.left_pane_width';
  static const _kRightPaneWidth = 'chatroom.right_pane_width';

  static Future<SettingsRepository> load() async {
    final prefs = await SharedPreferences.getInstance();
    return SettingsRepository(prefs);
  }

  // ---------- server / token ----------

  /// 是否已完成首次設定（曾儲存過 server URL）。
  bool get hasServerConfig => _prefs.containsKey(_kServerUrl);

  String get serverUrl =>
      _prefs.getString(_kServerUrl) ?? 'http://127.0.0.1:8787';
  Future<void> setServerUrl(String url) =>
      _prefs.setString(_kServerUrl, url.trim());

  Future<String?> readToken() => _secure.read(key: _kToken);
  Future<void> writeToken(String token) =>
      _secure.write(key: _kToken, value: token);

  // ---------- device session key ----------

  Future<String?> readDeviceKey() => _secure.read(key: _kDeviceKey);
  Future<void> writeDeviceKey(String key) =>
      _secure.write(key: _kDeviceKey, value: key);

  // ---------- UI 偏好 ----------

  ThemeModePref get themeMode => ThemeModePref.values.firstWhere(
        (m) => m.name == _prefs.getString(_kThemeMode),
        orElse: () => ThemeModePref.dark,
      );
  Future<void> setThemeMode(ThemeModePref mode) =>
      _prefs.setString(_kThemeMode, mode.name);

  /// 字級偏好：整個 App 的文字縮放，預設「中」。
  FontScalePref get fontScale => FontScalePref.values.firstWhere(
        (f) => f.name == _prefs.getString(_kFontScale),
        orElse: () => FontScalePref.medium,
      );
  Future<void> setFontScale(FontScalePref scale) =>
      _prefs.setString(_kFontScale, scale.name);

  /// 字體偏好：標題與內文用哪一套字，預設 Noto Serif TC。
  FontFamilyPref get fontFamily => FontFamilyPref.values.firstWhere(
        (f) => f.name == _prefs.getString(_kFontFamily),
        orElse: () => FontFamilyPref.standard,
      );
  Future<void> setFontFamily(FontFamilyPref family) =>
      _prefs.setString(_kFontFamily, family.name);

  /// 語言偏好，預設跟隨系統。
  ///
  /// 只存偏好本身；`system` 要對應到哪個 locale 由套用端（`app.dart`）交給
  /// Flutter 自己解析——這裡不把系統語言寫死成一個值，否則使用者換系統語言
  /// 之後 App 還停在舊的那個。
  LocalePref get locale => LocalePref.values.firstWhere(
        (l) => l.name == _prefs.getString(_kLocale),
        orElse: () => LocalePref.system,
      );
  Future<void> setLocale(LocalePref pref) =>
      _prefs.setString(_kLocale, pref.name);

  String get preferredName => _prefs.getString(_kPreferredName) ?? '';
  Future<void> setPreferredName(String name) =>
      _prefs.setString(_kPreferredName, name.trim());

  /// 通知模式：預設通知所有新訊息（被 @mention 一律通知）。
  NotifyModePref get notifyMode => NotifyModePref.values.firstWhere(
        (m) => m.name == _prefs.getString(_kNotifyMode),
        orElse: () => NotifyModePref.all,
      );
  Future<void> setNotifyMode(NotifyModePref mode) =>
      _prefs.setString(_kNotifyMode, mode.name);

  /// 關閉視窗時縮到系統匣而不是結束程式（Windows 專用），預設開。
  ///
  /// 預設開是因為這個 App 的用途是等訊息：關掉視窗多半是「不想看了」，
  /// 不是「不要再通知我」。關掉開關後關閉鍵就是結束，沒有第二種行為。
  bool get closeToTray => _prefs.getBool(_kCloseToTray) ?? true;
  Future<void> setCloseToTray(bool v) => _prefs.setBool(_kCloseToTray, v);

  /// Codex 轉送：app 收到的新訊息經 codex queue 喚醒本機 Codex session。
  /// 每台裝置各自設定，預設關閉（多裝置同開會重複轉送）。
  bool get codexDispatchEnabled => _prefs.getBool(_kCodexDispatch) ?? false;
  Future<void> setCodexDispatchEnabled(bool v) =>
      _prefs.setBool(_kCodexDispatch, v);

  /// 診斷用單一轉送目標；空字串 = 掃描並依房內身分分流所有活躍 Codex session。
  String get codexDispatchThread => _prefs.getString(_kCodexThread) ?? '';
  Future<void> setCodexDispatchThread(String id) =>
      _prefs.setString(_kCodexThread, id.trim());

  /// 左欄（房間／Board 列表）寬度，單位 px。
  ///
  /// 讀出來就夾在合法範圍內：落盤的值可能來自上一版的上下限，而版面拿到
  /// 一個超界的數字只會把主內容擠掉。
  double get leftPaneWidth => clampLeftPaneWidth(
      _prefs.getDouble(_kLeftPaneWidth) ?? kLeftPaneDefaultWidth);
  Future<void> setLeftPaneWidth(double width) =>
      _prefs.setDouble(_kLeftPaneWidth, clampLeftPaneWidth(width));

  /// 右欄（成員／回報）寬度，單位 px。
  double get rightPaneWidth => clampRightPaneWidth(
      _prefs.getDouble(_kRightPaneWidth) ?? kRightPaneDefaultWidth);
  Future<void> setRightPaneWidth(double width) =>
      _prefs.setDouble(_kRightPaneWidth, clampRightPaneWidth(width));

  /// 監控器（派工異常）看到哪裡了：最後一筆看過的事件時間（ISO）。
  ///
  /// 記時間不記 id：清單是跨房合併出來的，「這筆比我看過的新」要能比大小。
  String get opsExceptionSeenAt =>
      _prefs.getString(_kOpsExceptionSeen) ?? '';
  Future<void> setOpsExceptionSeenAt(String createdAt) =>
      _prefs.setString(_kOpsExceptionSeen, createdAt);

  // ---------- 房間層級快取 ----------

  int lastReadSeq(String roomId) => _prefs.getInt('$_kLastReadPrefix$roomId') ?? 0;

  /// 被 @ 了但還沒去看的則數（每房）。
  ///
  /// 與「未讀訊息」刻意分開：未讀是**看了沒**，這個是**處理了沒**。工作列
  /// 徽章綁在後者——右下角的 toast 會自己消失，看漏就沒了，而徽章要留到
  /// 人真的去看為止。這也是為什麼它要持久化：關掉 App 再開，那件事還在。
  int pendingMentions(String roomId) =>
      _prefs.getInt('$_kPendingMentionPrefix$roomId') ?? 0;

  Future<void> addPendingMention(String roomId) => _prefs.setInt(
      '$_kPendingMentionPrefix$roomId', pendingMentions(roomId) + 1);

  Future<void> clearPendingMentions(String roomId) =>
      _prefs.remove('$_kPendingMentionPrefix$roomId');

  /// 所有房間的未讀 mention 總和。
  int get totalPendingMentions => _prefs
      .getKeys()
      .where((k) => k.startsWith(_kPendingMentionPrefix))
      .fold(0, (sum, k) => sum + (_prefs.getInt(k) ?? 0));
  Future<void> setLastReadSeq(String roomId, int seq) =>
      _prefs.setInt('$_kLastReadPrefix$roomId', seq);

  /// 這個房的 board 已經通知到哪個水位；沒有紀錄時回 null
  /// （那與「通知到 0」不同——0 是一個真的水位）。
  int? boardNotifiedSeq(String roomId) =>
      _prefs.getInt('$_kBoardNotifiedPrefix$roomId');

  Future<void> setBoardNotifiedSeq(String roomId, int seq) =>
      _prefs.setInt('$_kBoardNotifiedPrefix$roomId', seq);

  String? participantId(String roomId) =>
      _prefs.getString('$_kParticipantPrefix$roomId');
  Future<void> setParticipantId(String roomId, String? id) async {
    if (id == null) {
      await _prefs.remove('$_kParticipantPrefix$roomId');
    } else {
      await _prefs.setString('$_kParticipantPrefix$roomId', id);
    }
  }

  /// 我在該房的顯示名稱（mention 比對用；join 成功時寫入）。
  String? displayName(String roomId) =>
      _prefs.getString('$_kDisplayNamePrefix$roomId');
  Future<void> setDisplayName(String roomId, String name) =>
      _prefs.setString('$_kDisplayNamePrefix$roomId', name);

  /// 在成員列表中被我隱藏的 participant id。
  ///
  /// **純本機視圖**——不送去 Hub，不影響聊天內容、mention、歷史或任何人
  /// 的成員資料，只決定這台裝置的側邊列表要不要畫他。房間開久了離開過的
  /// 身分會越積越多，列表長到不能用，但那些記錄在 Hub 端仍有用途（歷史
  /// 訊息的身分對照），所以是隱藏而不是刪除。
  Set<String> hiddenMembers(String roomId) =>
      (_prefs.getStringList('$_kHiddenMembersPrefix$roomId') ?? const [])
          .toSet();

  Future<void> setHiddenMembers(String roomId, Set<String> ids) async {
    final key = '$_kHiddenMembersPrefix$roomId';
    if (ids.isEmpty) {
      await _prefs.remove(key);
    } else {
      await _prefs.setStringList(key, ids.toList());
    }
  }

  /// 在時間軸上被我標記的 participant id。
  ///
  /// 與 [hiddenMembers] 是同一類東西（**純本機視圖**，不送 Hub、不影響任何
  /// 人看到的內容），方向相反：隱藏是「別讓他佔位置」，標記是「別讓我漏看
  /// 他」。房裡人一多，等某個特定 agent 回話時整條時間軸都在滾。
  ///
  /// 刻意與訊息氣泡的 `highlighted` 分開——那是跳轉時的**暫態**金框，
  /// 一秒後就該消失；這個是持續的偏好。共用一個視覺通道會讓「我剛跳過來」
  /// 和「這個人我在等」看起來一模一樣。
  Set<String> highlightedMembers(String roomId) =>
      (_prefs.getStringList('$_kHighlightedMembersPrefix$roomId') ?? const [])
          .toSet();

  Future<void> setHighlightedMembers(String roomId, Set<String> ids) async {
    final key = '$_kHighlightedMembersPrefix$roomId';
    if (ids.isEmpty) {
      await _prefs.remove(key);
    } else {
      await _prefs.setStringList(key, ids.toList());
    }
  }

  /// 最近見過的 agent session_key（指派畫面的快選來源）。
  List<String> get seenSessionKeys =>
      _prefs.getStringList(_kSeenSessionKeys) ?? const [];
  Future<void> rememberSessionKeys(Iterable<String> keys) async {
    final merged = <String>{...keys, ...seenSessionKeys}.take(30).toList();
    await _prefs.setStringList(_kSeenSessionKeys, merged);
  }

  @visibleForTesting
  SharedPreferences get prefs => _prefs;
}

enum ThemeModePref { dark, light }

/// 字級偏好：tiny 極小、small 小、medium 中（預設）、large 大、xlarge 特大。
///
/// 只存偏好本身，實際的縮放倍率由套用端（`app.dart` 的 MediaQuery）決定——
/// 倍率是視覺決策，會被調整，而落盤的值不該跟著改。
///
/// 落盤的是 `enum.name`，所以加新檔不會動到舊值：存過 small／medium／large
/// 的裝置照樣讀得回來。
enum FontScalePref { tiny, small, medium, large, xlarge }

/// 字體偏好：standard 預設（Noto Serif TC）、iansui 芫荽、openhuninn 粉圓、
/// chenyuluoyan 辰宇落雁體、glowsans Glow Sans TC。
///
/// 與 [FontScalePref] 同樣只存 `enum.name`；實際字族名寫在 `uep_theme.dart`，
/// 那是打包進 assets 的家族字串，會隨字體檔換版而變，不該落盤。
/// `standard` 而不是 `default`——後者是 Dart 保留字。
enum FontFamilyPref { standard, iansui, openhuninn, chenyuluoyan, glowsans }

/// 通知模式：off 不通知、mentions 僅被 @mention、all 所有新訊息。
enum NotifyModePref { off, mentions, all }

/// 語言偏好：system 跟隨系統、zhTW 繁體中文、en 英文。
///
/// 落盤的是 `enum.name`（`system` / `zhTW` / `en`），不是 BCP-47 字串——
/// 選項是一份有限清單，而 locale 字串的寫法（`zh_TW`／`zh-Hant-TW`）會變。
enum LocalePref { system, zhTW, en }

/// 側邊欄寬度的預設與夾取範圍（px）。
///
/// 放在這裡而不是各自的畫面檔：落盤端（讀回來要夾）與版面端（拖曳時要夾）
/// 必須用同一份數字，分兩處寫遲早會各改各的。
const double kLeftPaneDefaultWidth = 272;
const double kLeftPaneMinWidth = 200;
const double kLeftPaneMaxWidth = 480;
const double kRightPaneDefaultWidth = 288;
const double kRightPaneMinWidth = 240;
const double kRightPaneMaxWidth = 560;

/// 主內容（訊息區）不論側欄怎麼拖都要留下的寬度。
const double kMainPaneMinWidth = 420;

/// 分隔線的可拖曳寬度。細到看不見就抓不到，粗到會被誤觸。
const double kPaneDividerWidth = 6;

/// 夾在 [min]、[max] 之間；[max] 比 [min] 還小時以 [min] 為準
/// （視窗窄到連下限都放不下時，寧可讓側欄超出也不要回一個負數）。
double clampPaneWidth(double width, {required double min, required double max}) {
  final hi = max < min ? min : max;
  return width.clamp(min, hi).toDouble();
}

/// 左欄夾取。[available] 是當下版面還能給側欄的最大寬（已扣掉主內容下限與
/// 分隔線）；沒傳就只用固定上限。
double clampLeftPaneWidth(double width, {double? available}) => clampPaneWidth(
      width,
      min: kLeftPaneMinWidth,
      max: available == null || available > kLeftPaneMaxWidth
          ? kLeftPaneMaxWidth
          : available,
    );

/// 右欄夾取；語意同 [clampLeftPaneWidth]。
double clampRightPaneWidth(double width, {double? available}) => clampPaneWidth(
      width,
      min: kRightPaneMinWidth,
      max: available == null || available > kRightPaneMaxWidth
          ? kRightPaneMaxWidth
          : available,
    );
