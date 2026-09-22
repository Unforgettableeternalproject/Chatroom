import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/window/window_tray.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「關閉視窗時縮到系統匣」的偏好：預設值、落盤、快照同步。
///
/// 全程把 [WindowTray.supportedOverride] 關掉——這裡驗的是偏好，
/// 不是原生視窗；開著的話 setCloseToTray 會去打 window_manager 的
/// method channel，而測試環境沒有那一端。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsRepository settings;
  final realSupported = WindowTray.supportedOverride;

  setUp(() async {
    WindowTray.supportedOverride = false;
    SharedPreferences.setMockInitialValues({});
    settings = SettingsRepository(await SharedPreferences.getInstance());
  });

  tearDown(() => WindowTray.supportedOverride = realSupported);

  test('沒設定過時是開著的', () {
    expect(settings.closeToTray, isTrue);
  });

  test('關掉會落盤，key 是 chatroom.close_to_tray', () async {
    await settings.setCloseToTray(false);

    expect(settings.closeToTray, isFalse);
    expect(settings.prefs.getBool('chatroom.close_to_tray'), isFalse);
  });

  test('setCloseToTray 同步快照，重建時從 prefs 讀回來', () async {
    final container = ProviderContainer(overrides: [
      settingsRepoProvider.overrideWithValue(settings),
      initialConfigProvider.overrideWithValue(
        AppConfig.fromSettings(settings, token: '', deviceKey: 'dev-1'),
      ),
    ]);
    addTearDown(container.dispose);

    expect(container.read(appConfigProvider).closeToTray, isTrue);

    await container.read(appConfigProvider.notifier).setCloseToTray(false);
    expect(container.read(appConfigProvider).closeToTray, isFalse);

    // 下次啟動走的是這條路：快照由倉庫重建
    expect(
        AppConfig.fromSettings(settings, token: '', deviceKey: 'dev-1')
            .closeToTray,
        isFalse);
  });

  test('不支援的平台上開關不動原生，偏好照樣存得回來', () async {
    // supported=false ⇒ setEnabled 是 no-op；這條確認它沒有順手吞掉落盤
    await WindowTray.instance.setEnabled(true);
    expect(WindowTray.instance.enabled, isFalse);

    await settings.setCloseToTray(true);
    expect(settings.closeToTray, isTrue);
  });
}
