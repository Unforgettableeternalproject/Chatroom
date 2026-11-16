import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:logging/logging.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../l10n/l10n.dart';
import '../config/app_settings.dart';
import '../platform/app_platform.dart';

final _log = Logger('tray');

/// 系統匣的原生接點。抽出來只為了一件事：讓測試能讓它失敗。
abstract class TrayBackend {
  /// [isTemplate] 只有 macOS 用：template 圖是黑色＋alpha 的剪影，系統會依
  /// 淺／深色選單列自動反白。
  Future<void> setIcon(String path, {bool isTemplate = false});
  Future<void> setToolTip(String tooltip);
  Future<void> setContextMenu(Menu menu);
  Future<void> popUpContextMenu();
  Future<void> destroy();
}

/// 視窗的原生接點，同上。
abstract class WindowBackend {
  Future<void> setPreventClose(bool value);
  Future<void> show();
  Future<void> focus();
  Future<void> hide();
  Future<void> destroy();
}

class _RealTrayBackend implements TrayBackend {
  const _RealTrayBackend();

  @override
  Future<void> setIcon(String path, {bool isTemplate = false}) =>
      trayManager.setIcon(path, isTemplate: isTemplate);

  /// Linux 的 tray_manager 沒有實作 `setToolTip`（AppIndicator 沒有這個概念），
  /// 會丟 [MissingPluginException]。那不是匣裝不上去，吞掉。
  @override
  Future<void> setToolTip(String tooltip) async {
    try {
      await trayManager.setToolTip(tooltip);
    } on MissingPluginException {
      // 此平台沒有 tooltip
    }
  }

  @override
  Future<void> setContextMenu(Menu menu) => trayManager.setContextMenu(menu);

  /// Linux 的選單是永遠掛在圖示上的，沒有「彈出」這個動作；同上，吞掉。
  @override
  Future<void> popUpContextMenu() async {
    try {
      await trayManager.popUpContextMenu();
    } on MissingPluginException {
      // 此平台沒有彈出選單
    }
  }

  @override
  Future<void> destroy() => trayManager.destroy();
}

class _RealWindowBackend implements WindowBackend {
  const _RealWindowBackend();

  @override
  Future<void> setPreventClose(bool value) =>
      windowManager.setPreventClose(value);

  @override
  Future<void> show() => windowManager.show();

  @override
  Future<void> focus() => windowManager.focus();

  @override
  Future<void> hide() => windowManager.hide();

  @override
  Future<void> destroy() => windowManager.destroy();
}

/// 匣圖示的資產與是否為 template：Windows 只吃 `.ico`；macOS 用黑色＋alpha
/// 的 template PNG；Linux（AppIndicator）用彩色 PNG。
({String asset, bool isTemplate}) trayIconFor(AppPlatform platform) =>
    switch (platform) {
      AppPlatform.windows => (asset: 'assets/tray.ico', isTemplate: false),
      AppPlatform.macos => (asset: 'assets/tray_template.png', isTemplate: true),
      AppPlatform.linux => (asset: 'assets/tray.png', isTemplate: false),
    };

/// 探測子進程的接點。測試換成 fake。
typedef TrayProbeRun = Future<ProcessResult> Function(
    String executable, List<String> arguments);

/// Linux 上有沒有系統匣宿主：session bus 上 `org.kde.StatusNotifierWatcher`
/// 有沒有人擁有。
///
/// 🔴 **這一步不能省。** tray_manager 在 Linux 用 AppIndicator：沒有宿主時
/// `setIcon` 不會失敗（圖示只是沒有地方顯示），於是「匣裝不上去就回滾關閉
/// 攔截」的保護完全不會觸發——關閉視窗會把它藏起來，而沒有任何東西能把它
/// 叫回來（GNOME 沒裝 AppIndicator 擴充套件就是這樣）。
///
/// 依序用 `gdbus`、`dbus-send`、`busctl` 問，哪個在就用哪個；**全都問不到
/// 一律當作沒有**——寧可關閉視窗直接結束，也不要留一個叫不回來的視窗。
Future<bool> linuxTrayHostAvailable({TrayProbeRun? run}) async {
  const watcher = 'org.kde.StatusNotifierWatcher';
  final exec = run ??
      (exe, args) => Process.run(exe, args).timeout(const Duration(seconds: 3));

  /// 問得到答案回 true／false；工具不在或 bus 連不上回 null（換下一個）。
  Future<bool?> ask(
      String exe, List<String> args, bool Function(String out) owned) async {
    try {
      final r = await exec(exe, args);
      if (r.exitCode != 0) return null;
      return owned('${r.stdout}');
    } on Object {
      return null;
    }
  }

  final viaGdbus = await ask(
    'gdbus',
    [
      'call',
      '--session',
      '--dest',
      'org.freedesktop.DBus',
      '--object-path',
      '/org/freedesktop/DBus',
      '--method',
      'org.freedesktop.DBus.NameHasOwner',
      watcher,
    ],
    (out) => out.contains('true'),
  );
  if (viaGdbus != null) return viaGdbus;

  final viaDbusSend = await ask(
    'dbus-send',
    [
      '--session',
      '--print-reply',
      '--dest=org.freedesktop.DBus',
      '/org/freedesktop/DBus',
      'org.freedesktop.DBus.NameHasOwner',
      'string:$watcher',
    ],
    (out) => out.contains('boolean true'),
  );
  if (viaDbusSend != null) return viaDbusSend;

  // busctl status：名字有擁有者就是 0，沒有就非 0
  try {
    final r = await exec('busctl', ['--user', 'status', watcher]);
    return r.exitCode == 0;
  } on Object {
    return false;
  }
}

/// 關閉視窗時縮到系統匣（Windows、macOS、Linux），行為仿 Line。
///
/// **開關關著時這裡什麼都不做**：不註冊攔截、不放匣圖示，關閉鍵就是結束。
/// 這不是保守，是必要——`setPreventClose(true)` 一旦裝上去，關閉鍵就再也
/// 不會結束程式，而使用者沒有第二個地方可以關掉它。
///
/// 桌面三平台。其他平台（手機）一律靜默略過：不是失敗，是不適用。
///
/// - macOS：紅燈＝縮到匣（`preventClose`＋`hide`）；Dock 圖示會叫回視窗
///   （AppDelegate 的 `applicationShouldHandleReopen`）。
/// - Linux：只有偵測到系統匣宿主才裝攔截（見 [linuxTrayHostAvailable]）；
///   沒有宿主就維持關閉，關閉視窗直接結束。
class WindowTray with WindowListener, TrayListener {
  WindowTray._();

  static final WindowTray instance = WindowTray._();

  /// 桌面三平台有這條路。`@visibleForTesting` 可覆寫——測試要能兩邊都測，
  /// 而 `Platform.isWindows` 在測試裡是跑測試那台機器的事實，不是被測條件。
  @visibleForTesting
  static bool supportedOverride = !kIsWeb &&
      (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// 現在扮演哪個平台（選圖示、決定要不要探測匣宿主）。測試覆寫它。
  @visibleForTesting
  static AppPlatform platform = detectAppPlatform() ?? AppPlatform.windows;

  /// 有沒有系統匣可以放圖示。只有 Linux 會真的探測；其他平台恆為真。
  @visibleForTesting
  static Future<bool> Function() trayHostAvailable = () =>
      platform == AppPlatform.linux
          ? linuxTrayHostAvailable()
          : Future.value(true);

  bool get supported => supportedOverride;

  /// 原生接點。測試可換成假的，藉此模擬匣裝不上去。
  @visibleForTesting
  static TrayBackend tray = const _RealTrayBackend();

  @visibleForTesting
  static WindowBackend window = const _RealWindowBackend();

  /// 結束進程的接點。測試換掉它，免得 `exit(0)` 把測試進程一起殺了。
  @visibleForTesting
  static void Function(int code) exitProcess = exit;

  bool _enabled = false;
  bool _listening = false;
  bool _trayVisible = false;

  /// 有沒有系統匣可以放圖示（設定頁據此停用開關）。
  static Future<bool> hostAvailable() => trayHostAvailable();

  bool get enabled => _enabled;

  /// 通知模式的讀寫接點：選單要顯示當前值、點下去要寫回去，而系統匣活在
  /// widget 樹之外拿不到 `ref`。由 `AppConfigNotifier` 在建立時接上。
  ///
  /// 沒接上時選單照畫（勾在預設的「所有訊息」），點了不做事——這是啟動
  /// 途中的短暫狀態，不該讓右鍵直接炸掉。
  NotifyModePref Function()? notifyModeReader;
  Future<void> Function(NotifyModePref mode)? notifyModeWriter;

  /// 啟動時呼叫一次。[enabled] 是偏好的當前值。
  Future<void> init({required bool enabled}) async {
    if (!supported) return;
    if (!_listening) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      _listening = true;
    }
    await setEnabled(enabled);
  }

  /// 開關切換時呼叫；關掉會把攔截與匣圖示一起收回去。
  ///
  /// 開啟時**先把匣放上去再裝攔截**，而且任何一步失敗都把 [enabled] 與
  /// `preventClose` 一起退回關閉狀態。順序反過來的話，匣放不上去（圖示裝
  /// 不了、原生匣服務不在）就會留下一個關不掉也叫不回來的視窗。
  Future<void> setEnabled(bool value) async {
    if (!supported) return;
    if (!value) {
      _enabled = false;
      try {
        await window.setPreventClose(false);
        await _removeTray();
      } catch (e) {
        _log.warning('系統匣設定失敗（closeToTray=false）：$e');
      }
      return;
    }
    if (!await trayHostAvailable()) {
      // 沒有匣宿主：圖示放得上去也看不到。不裝攔截，關閉視窗就直接結束
      _log.warning('找不到系統匣宿主（StatusNotifierWatcher），'
          'closeToTray 維持關閉：關閉視窗會直接結束');
      _enabled = false;
      try {
        await window.setPreventClose(false);
      } catch (e) {
        _log.warning('關閉攔截拆除失敗：$e');
      }
      return;
    }
    try {
      await _ensureTray();
    } catch (e) {
      _log.warning('系統匣建立失敗，closeToTray 維持關閉：$e');
      await _disableAfterTrayFailure();
      return;
    }
    try {
      await window.setPreventClose(true);
      _enabled = true;
    } catch (e) {
      _log.warning('關閉攔截安裝失敗，closeToTray 維持關閉：$e');
      await _disableAfterTrayFailure();
    }
  }

  /// 失敗回滾：攔截拆掉、狀態退回關閉、半套的匣圖示也收掉。
  /// 每一步都自己吞例外——回滾本身再丟，就沒有第二次機會了。
  Future<void> _disableAfterTrayFailure() async {
    _enabled = false;
    try {
      await window.setPreventClose(false);
    } catch (e) {
      _log.warning('回滾關閉攔截失敗：$e');
    }
    try {
      await tray.destroy();
    } catch (e) {
      _log.warning('回滾系統匣失敗：$e');
    }
    _trayVisible = false;
  }

  /// 把視窗叫回前景。點通知時也走這裡——視窗藏在匣裡時，導頁本身
  /// 是看不見的。
  Future<void> showWindow() async {
    if (!supported) return;
    try {
      await window.show();
      await window.focus();
    } catch (e) {
      _log.warning('顯示視窗失敗：$e');
    }
  }

  Future<void> _ensureTray() async {
    if (_trayVisible) return;
    final icon = trayIconFor(platform);
    await tray.setIcon(icon.asset, isTemplate: icon.isTemplate);
    await tray.setToolTip('Chatroom');
    await _applyMenu();
    _trayVisible = true;
  }

  Future<void> _removeTray() async {
    if (!_trayVisible) return;
    await tray.destroy();
    _trayVisible = false;
  }

  /// 選單每次要彈之前重建：標籤跟著 App 語言走，勾選跟著當前通知模式走，
  /// 而兩者都可以在執行期變。
  Future<void> _applyMenu() async {
    await tray.setContextMenu(
        buildTrayMenu(notifyModeReader?.call() ?? NotifyModePref.all));
  }

  /// 真的結束：先把攔截拆掉，否則 `destroy()` 會被自己擋下來。
  ///
  /// 先 `hide()` 讓視窗立刻消失：`destroy()` 只是送出 PostQuitMessage，之後
  /// runner 同步收掉引擎，期間視窗還掛著卻不處理訊息，會顯示「沒有回應」。
  /// 最後 `exit(0)` 跳過那段慢收尾；log 是同步寫入並 flush，沒有待寫狀態。
  Future<void> _quit() async {
    try {
      await window.hide();
      await window.setPreventClose(false);
      await _removeTray();
      await window.destroy();
      exitProcess(0);
    } catch (e) {
      _log.warning('結束程式失敗：$e');
    }
  }

  /// 結束程式，與匣選單的「結束」同一條路。給自我更新用：closeToTray
  /// 開著時關閉視窗只會藏起來，進程不會走。
  Future<void> quit() => _quit();

  @override
  void onWindowClose() {
    if (!_enabled) return; // 開關關著＝照常結束，preventClose 也沒裝
    window.hide();
  }

  @override
  void onTrayIconMouseDown() {
    showWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    _applyMenu().then((_) => tray.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case kTrayMenuShow:
        showWindow();
      case kTrayMenuExit:
        _quit();
      case final String key when trayNotifyModeOf(key) != null:
        notifyModeWriter?.call(trayNotifyModeOf(key)!);
    }
  }
}

// ---------- 選單本身 ----------

const kTrayMenuShow = 'show';
const kTrayMenuExit = 'exit';

/// 通知模式那三項的鍵；值是 `NotifyModePref.name`，所以加模式不必改對照表。
String trayNotifyKey(NotifyModePref mode) => 'notify.${mode.name}';

/// 反查：不是通知那三項就回 null。
NotifyModePref? trayNotifyModeOf(String key) {
  if (!key.startsWith('notify.')) return null;
  final name = key.substring('notify.'.length);
  for (final mode in NotifyModePref.values) {
    if (mode.name == name) return mode;
  }
  return null;
}

/// 系統匣右鍵選單。純函式——給什麼模式就畫出什麼勾選，方便單測。
///
/// 三個通知模式做成 checkbox 而不是子選單：從匣上改通知是「現在很吵」
/// 當下的動作，多一層展開就等於要人先找得到它。
///
/// 「通知」那行是**停用的標題**，不是可點的項目：少了它，選單上會同時
/// 出現「關閉」與「結束」兩個看起來都像在關程式的字。
Menu buildTrayMenu(NotifyModePref mode) {
  final l10n = L10n.current;
  return Menu(items: [
    MenuItem(key: kTrayMenuShow, label: l10n.trayMenuOpen),
    MenuItem.separator(),
    MenuItem(label: l10n.trayMenuNotifySection, disabled: true),
    for (final (m, label) in [
      (NotifyModePref.off, l10n.settingsNotifyOff),
      (NotifyModePref.mentions, l10n.settingsNotifyMentions),
      (NotifyModePref.all, l10n.settingsNotifyAll),
    ])
      MenuItem.checkbox(
        key: trayNotifyKey(m),
        label: label,
        checked: m == mode,
      ),
    MenuItem.separator(),
    MenuItem(key: kTrayMenuExit, label: l10n.trayMenuExit),
  ]);
}
