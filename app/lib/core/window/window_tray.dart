import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../l10n/l10n.dart';
import '../config/app_settings.dart';

final _log = Logger('tray');

/// 關閉視窗時縮到系統匣（Windows），行為仿 Line。
///
/// **開關關著時這裡什麼都不做**：不註冊攔截、不放匣圖示，關閉鍵就是結束。
/// 這不是保守，是必要——`setPreventClose(true)` 一旦裝上去，關閉鍵就再也
/// 不會結束程式，而使用者沒有第二個地方可以關掉它。
///
/// 只有 Windows。其他平台一律靜默略過：不是失敗，是不適用。
class WindowTray with WindowListener, TrayListener {
  WindowTray._();

  static final WindowTray instance = WindowTray._();

  /// 只有 Windows 有這條路。`@visibleForTesting` 可覆寫——測試要能兩邊都測，
  /// 而 `Platform.isWindows` 在測試裡是跑測試那台機器的事實，不是被測條件。
  @visibleForTesting
  static bool supportedOverride = !kIsWeb && Platform.isWindows;

  bool get supported => supportedOverride;

  bool _enabled = false;
  bool _listening = false;
  bool _trayVisible = false;

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
  Future<void> setEnabled(bool value) async {
    if (!supported) return;
    _enabled = value;
    try {
      await windowManager.setPreventClose(value);
      if (value) {
        await _ensureTray();
      } else {
        await _removeTray();
      }
    } catch (e) {
      _log.warning('系統匣設定失敗（closeToTray=$value）：$e');
    }
  }

  /// 把視窗叫回前景。點通知時也走這裡——視窗藏在匣裡時，導頁本身
  /// 是看不見的。
  Future<void> showWindow() async {
    if (!supported) return;
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (e) {
      _log.warning('顯示視窗失敗：$e');
    }
  }

  Future<void> _ensureTray() async {
    if (_trayVisible) return;
    await trayManager.setIcon('assets/tray.ico');
    await trayManager.setToolTip('Chatroom');
    await _applyMenu();
    _trayVisible = true;
  }

  Future<void> _removeTray() async {
    if (!_trayVisible) return;
    await trayManager.destroy();
    _trayVisible = false;
  }

  /// 選單每次要彈之前重建：標籤跟著 App 語言走，勾選跟著當前通知模式走，
  /// 而兩者都可以在執行期變。
  Future<void> _applyMenu() async {
    await trayManager.setContextMenu(
        buildTrayMenu(notifyModeReader?.call() ?? NotifyModePref.all));
  }

  /// 真的結束：先把攔截拆掉，否則 `destroy()` 會被自己擋下來。
  Future<void> _quit() async {
    try {
      await windowManager.setPreventClose(false);
      await _removeTray();
      await windowManager.destroy();
    } catch (e) {
      _log.warning('結束程式失敗：$e');
    }
  }

  @override
  void onWindowClose() {
    if (!_enabled) return; // 開關關著＝照常結束，preventClose 也沒裝
    windowManager.hide();
  }

  @override
  void onTrayIconMouseDown() {
    showWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    _applyMenu().then((_) => trayManager.popUpContextMenu());
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
