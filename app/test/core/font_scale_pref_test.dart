import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 字級偏好落盤與快照同步。
///
/// 兩端要一起驗：`AppConfig.fontScale` 是套用端（app.dart 的 MediaQuery）
/// 唯一讀得到的值，而重啟之後它從 prefs 來——只驗 setter 寫進去了，
/// 換不換得回來還是沒有答案。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsRepository settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsRepository(await SharedPreferences.getInstance());
  });

  test('沒設定過時是「中」', () {
    expect(settings.fontScale, FontScalePref.medium);
  });

  test('寫進去的值會落盤，key 是 chatroom.font_scale', () async {
    await settings.setFontScale(FontScalePref.large);

    expect(settings.fontScale, FontScalePref.large);
    expect(settings.prefs.getString('chatroom.font_scale'), 'large');
  });

  test('prefs 裡是壞值時回預設，不丟例外', () async {
    SharedPreferences.setMockInitialValues(
        {'chatroom.font_scale': 'gigantic'});
    final repo = SettingsRepository(await SharedPreferences.getInstance());

    expect(repo.fontScale, FontScalePref.medium);
  });

  test('setFontScale 同步快照，重建時從 prefs 讀回來', () async {
    final container = ProviderContainer(overrides: [
      settingsRepoProvider.overrideWithValue(settings),
      initialConfigProvider.overrideWithValue(
        AppConfig.fromSettings(settings, token: '', deviceKey: 'dev-1'),
      ),
    ]);
    addTearDown(container.dispose);

    expect(container.read(appConfigProvider).fontScale, FontScalePref.medium);

    await container
        .read(appConfigProvider.notifier)
        .setFontScale(FontScalePref.small);
    expect(container.read(appConfigProvider).fontScale, FontScalePref.small);

    // 下次啟動走的是這條路：快照由倉庫重建
    expect(AppConfig.fromSettings(settings, token: '', deviceKey: 'dev-1')
        .fontScale, FontScalePref.small);
  });
}
