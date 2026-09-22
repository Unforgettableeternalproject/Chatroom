import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../l10n/l10n.dart';

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

  /// 選單每次要彈之前重建：標籤跟著 App 語言走，而語言可以在執行期換。
  Future<void> _applyMenu() async {
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: L10n.current.trayMenuOpen),
      MenuItem.separator(),
      MenuItem(key: 'exit', label: L10n.current.trayMenuExit),
    ]));
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
      case 'show':
        showWindow();
      case 'exit':
        _quit();
    }
  }
}
