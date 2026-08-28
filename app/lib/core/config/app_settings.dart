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
  static const _kNotifyMode = 'chatroom.notify_mode';

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

  // ---------- 房間層級快取 ----------

  int lastReadSeq(String roomId) => _prefs.getInt('$_kLastReadPrefix$roomId') ?? 0;
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
