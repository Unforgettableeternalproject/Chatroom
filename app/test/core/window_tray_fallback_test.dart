import 'package:chatroom_app/core/window/window_tray.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tray_manager/tray_manager.dart';

/// 匣裝不上去的那條路：關閉攔截必須回滾。
///
/// 沒回滾的話，按下關閉＝視窗藏起來，而沒有匣圖示能把它叫回來——
/// 對使用者來說就是程式消失了。
class _FakeTray implements TrayBackend {
  _FakeTray({this.failOnSetIcon = false});

  final bool failOnSetIcon;
  int destroyCount = 0;

  @override
  Future<void> setIcon(String path) async {
    if (failOnSetIcon) throw StateError('圖示裝不上');
  }

  @override
  Future<void> setToolTip(String tooltip) async {}

  @override
  Future<void> setContextMenu(Menu menu) async {}

  @override
  Future<void> popUpContextMenu() async {}

  @override
  Future<void> destroy() async => destroyCount++;
}

class _FakeWindow implements WindowBackend {
  bool preventClose = false;
  int hideCount = 0;
  final List<bool> preventCloseCalls = [];

  @override
  Future<void> setPreventClose(bool value) async {
    preventCloseCalls.add(value);
    preventClose = value;
  }

  @override
  Future<void> show() async {}

  @override
  Future<void> focus() async {}

  @override
  Future<void> hide() async => hideCount++;

  @override
  Future<void> destroy() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final realSupported = WindowTray.supportedOverride;
  late _FakeWindow window;

  setUp(() {
    WindowTray.supportedOverride = true;
    window = _FakeWindow();
    WindowTray.window = window;
  });

  tearDown(() async {
    WindowTray.tray = _FakeTray();
    await WindowTray.instance.setEnabled(false);
    WindowTray.supportedOverride = realSupported;
  });

  test('匣建立失敗：preventClose 回到 false，enabled 也退回去', () async {
    final tray = _FakeTray(failOnSetIcon: true);
    WindowTray.tray = tray;

    await WindowTray.instance.setEnabled(true);

    expect(window.preventClose, isFalse);
    expect(WindowTray.instance.enabled, isFalse);
    // 半套的匣也要收掉
    expect(tray.destroyCount, greaterThan(0));
  });

  test('匣建立失敗後按關閉視窗不會 hide', () async {
    WindowTray.tray = _FakeTray(failOnSetIcon: true);

    await WindowTray.instance.setEnabled(true);
    WindowTray.instance.onWindowClose();

    expect(window.hideCount, 0);
  });

  test('匣建立成功時照常裝攔截，關閉視窗才會 hide', () async {
    WindowTray.tray = _FakeTray();

    await WindowTray.instance.setEnabled(true);

    expect(window.preventClose, isTrue);
    expect(WindowTray.instance.enabled, isTrue);

    WindowTray.instance.onWindowClose();
    expect(window.hideCount, 1);
  });

  test('攔截安裝失敗也退回關閉', () async {
    WindowTray.tray = _FakeTray();
    WindowTray.window = _ThrowOnPreventCloseWindow(window);

    await WindowTray.instance.setEnabled(true);

    expect(WindowTray.instance.enabled, isFalse);
    // 回滾那次 setPreventClose(false) 不丟，所以狀態收得回來
    expect(window.preventClose, isFalse);
  });
}

/// `setPreventClose(true)` 丟例外、`false` 照常——模擬攔截裝不上。
class _ThrowOnPreventCloseWindow implements WindowBackend {
  _ThrowOnPreventCloseWindow(this.inner);

  final _FakeWindow inner;

  @override
  Future<void> setPreventClose(bool value) async {
    if (value) throw StateError('攔截裝不上');
    await inner.setPreventClose(value);
  }

  @override
  Future<void> show() => inner.show();

  @override
  Future<void> focus() => inner.focus();

  @override
  Future<void> hide() => inner.hide();

  @override
  Future<void> destroy() => inner.destroy();
}
