import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 側邊欄寬度的落盤、夾取與快照同步。
///
/// 兩端一起驗的理由與字級那支相同：`AppConfig.leftPaneWidth` 是版面唯一
/// 讀得到的值，而重啟之後它從 prefs 來——只驗 setter 寫進去了，換不換得
/// 回來還是沒有答案。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsRepository settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsRepository(await SharedPreferences.getInstance());
  });

  test('沒設定過時是預設寬', () {
    expect(settings.leftPaneWidth, kLeftPaneDefaultWidth);
    expect(settings.rightPaneWidth, kRightPaneDefaultWidth);
  });

  test('寫進去的值會落盤，key 是 chatroom.left/right_pane_width', () async {
    await settings.setLeftPaneWidth(360);
    await settings.setRightPaneWidth(420);

    expect(settings.leftPaneWidth, 360);
    expect(settings.rightPaneWidth, 420);
    expect(settings.prefs.getDouble('chatroom.left_pane_width'), 360);
    expect(settings.prefs.getDouble('chatroom.right_pane_width'), 420);
  });

  test('超界的值寫入時就被夾住', () async {
    await settings.setLeftPaneWidth(5000);
    expect(settings.leftPaneWidth, kLeftPaneMaxWidth);

    await settings.setLeftPaneWidth(-100);
    expect(settings.leftPaneWidth, kLeftPaneMinWidth);

    await settings.setRightPaneWidth(5000);
    expect(settings.rightPaneWidth, kRightPaneMaxWidth);

    await settings.setRightPaneWidth(0);
    expect(settings.rightPaneWidth, kRightPaneMinWidth);
  });

  test('🔴 prefs 裡是上一版留下的超界值時，讀出來也要夾住', () async {
    SharedPreferences.setMockInitialValues({
      'chatroom.left_pane_width': 1200.0,
      'chatroom.right_pane_width': 10.0,
    });
    final repo = SettingsRepository(await SharedPreferences.getInstance());

    expect(repo.leftPaneWidth, kLeftPaneMaxWidth,
        reason: '上下限改過之後，舊值會把主內容擠掉');
    expect(repo.rightPaneWidth, kRightPaneMinWidth);
  });

  test('available 比上限窄時以 available 為準；窄到連下限都放不下時回下限', () {
    expect(clampLeftPaneWidth(400, available: 300), 300);
    expect(clampLeftPaneWidth(400, available: 900), 400);
    expect(clampLeftPaneWidth(900, available: 900), kLeftPaneMaxWidth);
    expect(clampLeftPaneWidth(400, available: 50), kLeftPaneMinWidth);

    expect(clampRightPaneWidth(500, available: 320), 320);
    expect(clampRightPaneWidth(500), 500);
    expect(clampRightPaneWidth(900), kRightPaneMaxWidth);
  });

  test('setLeftPaneWidth 同步快照，重建時從 prefs 讀回來', () async {
    final container = ProviderContainer(overrides: [
      settingsRepoProvider.overrideWithValue(settings),
      initialConfigProvider.overrideWithValue(
        AppConfig.fromSettings(settings, token: '', deviceKey: 'dev-1'),
      ),
    ]);
    addTearDown(container.dispose);

    expect(container.read(appConfigProvider).leftPaneWidth,
        kLeftPaneDefaultWidth);

    await container.read(appConfigProvider.notifier).setLeftPaneWidth(330);
    await container.read(appConfigProvider.notifier).setRightPaneWidth(500);

    expect(container.read(appConfigProvider).leftPaneWidth, 330);
    expect(container.read(appConfigProvider).rightPaneWidth, 500);

    // 下次啟動走的是這條路：快照由倉庫重建
    final restored =
        AppConfig.fromSettings(settings, token: '', deviceKey: 'dev-1');
    expect(restored.leftPaneWidth, 330);
    expect(restored.rightPaneWidth, 500);
  });
}
