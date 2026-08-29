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
  static const _kPreferredName = 'chatroom.preferred_name';
  static const _kToken = 'chatroom.api_token';
  static const _kDeviceKey = 'chatroom.device_session_key';
  static const _kLastReadPrefix = 'chatroom.last_read.';
  static const _kParticipantPrefix = 'chatroom.participant.';
  static const _kDisplayNamePrefix = 'chatroom.display_name.';
  static const _kSeenSessionKeys = 'chatroom.seen_session_keys';
  static const _kHiddenMembersPrefix = 'chatroom.hidden_members.';
  static const _kPendingMentionPrefix = 'chatroom.pending_mention.';
  static const _kNotifyMode = 'chatroom.notify_mode';
  static const _kCodexDispatch = 'chatroom.codex_dispatch';
  static const _kCodexThread = 'chatroom.codex_thread';

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

  /// Codex 轉送：app 收到的新訊息經 codex queue 喚醒本機 Codex session。
  /// 每台裝置各自設定，預設關閉（多裝置同開會重複轉送）。
  bool get codexDispatchEnabled => _prefs.getBool(_kCodexDispatch) ?? false;
  Future<void> setCodexDispatchEnabled(bool v) =>
      _prefs.setBool(_kCodexDispatch, v);

  /// 診斷用單一轉送目標；空字串 = 掃描並依房內身分分流所有活躍 Codex session。
  String get codexDispatchThread => _prefs.getString(_kCodexThread) ?? '';
  Future<void> setCodexDispatchThread(String id) =>
      _prefs.setString(_kCodexThread, id.trim());

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

/// 通知模式：off 不通知、mentions 僅被 @mention、all 所有新訊息。
enum NotifyModePref { off, mentions, all }
