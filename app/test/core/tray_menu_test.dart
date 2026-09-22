import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/window/window_tray.dart';
import 'package:chatroom_app/l10n/l10n.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';

/// 系統匣右鍵選單：畫出來的樣子與點下去的去向。
///
/// [buildTrayMenu] 是純函式，所以這裡不碰任何原生端。
MenuItem? _item(Menu menu, String key) => menu.getMenuItem(key);

List<String> _keysInOrder(Menu menu) =>
    (menu.items ?? []).map((i) => i.key ?? i.type).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final l10n = L10n.current; // 預設繁中（沒掛 L10nSync 時就是 ARB 模板那份）
  final realSupported = WindowTray.supportedOverride;

  tearDown(() {
    WindowTray.supportedOverride = realSupported;
    WindowTray.instance.notifyModeReader = null;
    WindowTray.instance.notifyModeWriter = null;
  });

  test('選單順序：開啟／分隔／通知標題＋三項／分隔／結束', () {
    final menu = buildTrayMenu(NotifyModePref.all);

    expect(_keysInOrder(menu), [
      'show',
      'separator',
      'normal', // 「通知」標題沒有 key，它不可點
      'notify.off',
      'notify.mentions',
      'notify.all',
      'separator',
      'exit',
    ]);
    expect(menu.items![2].label, l10n.trayMenuNotifySection);
    expect(menu.items![2].disabled, isTrue);
    expect(_item(menu, 'show')!.label, l10n.trayMenuOpen);
    expect(_item(menu, 'exit')!.label, l10n.trayMenuExit);
  });

  test('通知三項用既有文案，且只勾當前那個', () {
    for (final mode in NotifyModePref.values) {
      final menu = buildTrayMenu(mode);
      for (final m in NotifyModePref.values) {
        final item = _item(menu, 'notify.${m.name}')!;
        expect(item.type, 'checkbox');
        expect(item.checked, m == mode, reason: '$mode 時的 ${m.name}');
      }
      expect(_item(menu, 'notify.off')!.label, l10n.settingsNotifyOff);
      expect(
          _item(menu, 'notify.mentions')!.label, l10n.settingsNotifyMentions);
      expect(_item(menu, 'notify.all')!.label, l10n.settingsNotifyAll);
    }
  });

  test('鍵與模式對得回去，其他鍵不會被誤認成通知', () {
    for (final mode in NotifyModePref.values) {
      expect(trayNotifyModeOf(trayNotifyKey(mode)), mode);
    }
    expect(trayNotifyModeOf('show'), isNull);
    expect(trayNotifyModeOf('exit'), isNull);
    expect(trayNotifyModeOf('notify.everything'), isNull);
  });

  test('點通知項目會把那個模式交給 writer', () {
    final written = <NotifyModePref>[];
    WindowTray.instance.notifyModeWriter = (m) async => written.add(m);

    for (final mode in NotifyModePref.values) {
      WindowTray.instance
          .onTrayMenuItemClick(_item(buildTrayMenu(mode), 'notify.mentions')!);
    }

    expect(written, List.filled(NotifyModePref.values.length,
        NotifyModePref.mentions));
  });

  test('點開啟／結束不會誤觸通知的 writer', () {
    final written = <NotifyModePref>[];
    WindowTray.instance.notifyModeWriter = (m) async => written.add(m);
    // supported=false ⇒ showWindow／_quit 是 no-op，不會碰原生端
    WindowTray.supportedOverride = false;

    final menu = buildTrayMenu(NotifyModePref.all);
    WindowTray.instance.onTrayMenuItemClick(_item(menu, 'show')!);
    WindowTray.instance.onTrayMenuItemClick(_item(menu, 'exit')!);

    expect(written, isEmpty);
  });

  test('AppConfigNotifier 接上讀寫接點，寫回去會落盤並推動重繪', () async {
    WindowTray.supportedOverride = false; // setCloseToTray 之外也別碰原生端
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsRepository(await SharedPreferences.getInstance());
    final container = ProviderContainer(overrides: [
      settingsRepoProvider.overrideWithValue(settings),
      initialConfigProvider.overrideWithValue(
        AppConfig.fromSettings(settings, token: '', deviceKey: 'dev-1'),
      ),
    ]);
    addTearDown(container.dispose);

    // build() 跑過才會接上接點
    final before = container.read(appConfigProvider).notifyModeRevision;
    expect(WindowTray.instance.notifyModeReader!(), NotifyModePref.all);

    await WindowTray.instance.notifyModeWriter!(NotifyModePref.mentions);

    expect(settings.notifyMode, NotifyModePref.mentions);
    expect(WindowTray.instance.notifyModeReader!(), NotifyModePref.mentions);
    // 設定頁 watch 的是 appConfigProvider——值變了它才會重讀倉庫
    expect(container.read(appConfigProvider).notifyModeRevision, before + 1);
  });
}
