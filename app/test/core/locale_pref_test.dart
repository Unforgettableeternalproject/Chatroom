import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 語言偏好落盤與快照同步。
///
/// 兩端要一起驗：`AppConfig.locale` 是套用端（app.dart 的 MaterialApp.locale）
/// 唯一讀得到的值，而重啟之後它從 prefs 來——只驗 setter 寫進去了，
/// 換不換得回來還是沒有答案。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsRepository settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsRepository(await SharedPreferences.getInstance());
  });

  test('沒設定過時跟隨系統', () {
    expect(settings.locale, LocalePref.system);
  });

  test('寫進去的值會落盤，key 是 chatroom.locale', () async {
    await settings.setLocale(LocalePref.en);

    expect(settings.locale, LocalePref.en);
    expect(settings.prefs.getString('chatroom.locale'), 'en');

    await settings.setLocale(LocalePref.zhTW);
    expect(settings.locale, LocalePref.zhTW);
    expect(settings.prefs.getString('chatroom.locale'), 'zhTW');
  });

  test('prefs 裡是壞值時回跟隨系統，不丟例外', () async {
    SharedPreferences.setMockInitialValues({'chatroom.locale': 'ja_JP'});
    final repo = SettingsRepository(await SharedPreferences.getInstance());

    expect(repo.locale, LocalePref.system);
  });

  test('setLocale 同步快照，重建時從 prefs 讀回來', () async {
    final container = ProviderContainer(overrides: [
      settingsRepoProvider.overrideWithValue(settings),
      initialConfigProvider.overrideWithValue(
        AppConfig.fromSettings(settings, token: '', deviceKey: 'dev-1'),
      ),
    ]);
    addTearDown(container.dispose);

    expect(container.read(appConfigProvider).locale, LocalePref.system);

    await container.read(appConfigProvider.notifier).setLocale(LocalePref.en);
    expect(container.read(appConfigProvider).locale, LocalePref.en);

    // 下次啟動走的是這條路：快照由倉庫重建
    expect(
        AppConfig.fromSettings(settings, token: '', deviceKey: 'dev-1').locale,
        LocalePref.en);
  });
}
