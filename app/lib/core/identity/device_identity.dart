import 'package:uuid/uuid.dart';

import '../config/app_settings.dart';

/// device_session_key：人類在 Hub 上的「裝置識別」。
/// 刻意不用平台裝置 ID（UI-DESIGN §6.1）——自產 UUID 可由使用者主動重新產生。
/// `human-` 前綴讓 Hub 端一眼可辨，不會誤把人類 key 當 agent 派工目標。
class DeviceIdentity {
  DeviceIdentity(this._settings);

  final SettingsRepository _settings;

  Future<String> ensureKey() async {
    final existing = await _settings.readDeviceKey();
    if (existing != null && existing.isNotEmpty) return existing;
    final generated = _generate();
    await _settings.writeDeviceKey(generated);
    return generated;
  }

  /// 重新產生身分（設定畫面的「重新產生」操作）。
  /// 舊的房間 participant 快取由呼叫端負責清除。
  Future<String> regenerate() async {
    final generated = _generate();
    await _settings.writeDeviceKey(generated);
    return generated;
  }

  static String _generate() =>
      'human-${const Uuid().v4().replaceAll('-', '')}';
}
