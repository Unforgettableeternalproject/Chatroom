import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 開發者模式偏好：預設關、落盤、快照同步。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsRepository settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsRepository(await SharedPreferences.getInstance());
  });

  test('沒設定過時是關的', () {
    expect(settings.devMode, isFalse);
  });

  test('開啟會落盤，key 是 chatroom.dev_mode', () async {
    await settings.setDevMode(true);

    expect(settings.devMode, isTrue);
    expect(settings.prefs.getBool('chatroom.dev_mode'), isTrue);
  });

  test('setDevMode 同步快照，重建時從 prefs 讀回來', () async {
    final container = ProviderContainer(overrides: [
      settingsRepoProvider.overrideWithValue(settings),
      initialConfigProvider.overrideWithValue(
        AppConfig.fromSettings(settings, token: '', deviceKey: 'dev-1'),
      ),
    ]);
    addTearDown(container.dispose);

    expect(container.read(appConfigProvider).devMode, isFalse);
    await container.read(appConfigProvider.notifier).setDevMode(true);
    expect(container.read(appConfigProvider).devMode, isTrue);

    expect(AppConfig.fromSettings(settings, token: '', deviceKey: 'd').devMode,
        isTrue);
  });
}
