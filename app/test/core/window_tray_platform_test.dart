import 'dart:io';

import 'package:chatroom_app/core/platform/app_platform.dart';
import 'package:chatroom_app/core/window/window_tray.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tray_manager/tray_manager.dart';

/// macOS／Linux 的系統匣。跑在 Windows 上，平台與匣宿主都用接點注入。

class _Tray implements TrayBackend {
  final icons = <(String, bool)>[];
  int destroyCount = 0;

  @override
  Future<void> setIcon(String path, {bool isTemplate = false}) async =>
      icons.add((path, isTemplate));

  @override
  Future<void> setToolTip(String tooltip) async {}

  @override
  Future<void> setContextMenu(Menu menu) async {}

  @override
  Future<void> popUpContextMenu() async {}

  @override
  Future<void> destroy() async => destroyCount++;
}

class _Window implements WindowBackend {
  final preventCloseCalls = <bool>[];

  @override
  Future<void> setPreventClose(bool value) async =>
      preventCloseCalls.add(value);

  @override
  Future<void> show() async {}

  @override
  Future<void> focus() async {}

  @override
  Future<void> hide() async {}

  @override
  Future<void> destroy() async {}
}

ProcessResult _r(int code, [String out = '']) => ProcessResult(0, code, out, '');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('trayIconFor', () {
    test('Windows 維持 tray.ico；macOS 是 template PNG；Linux 是彩色 PNG', () {
      expect(trayIconFor(AppPlatform.windows),
          (asset: 'assets/tray.ico', isTemplate: false));
      expect(trayIconFor(AppPlatform.macos),
          (asset: 'assets/tray_template.png', isTemplate: true));
      expect(trayIconFor(AppPlatform.linux),
          (asset: 'assets/tray.png', isTemplate: false));
    });

    test('圖示資產真的存在（pubspec 也有登記）', () {
      for (final p in AppPlatform.values) {
        expect(File(trayIconFor(p).asset).existsSync(), isTrue,
            reason: trayIconFor(p).asset);
      }
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('- assets/tray_template.png'));
      expect(pubspec, contains('- assets/tray.png'));
    });
  });

  group('linuxTrayHostAvailable', () {
    test('gdbus：NameHasOwner 回 true → 有匣', () async {
      expect(
          await linuxTrayHostAvailable(run: (e, a) async => _r(0, '(true,)\n')),
          isTrue);
      expect(
          await linuxTrayHostAvailable(run: (e, a) async => _r(0, '(false,)\n')),
          isFalse);
    });

    test('gdbus 不在 → 改問 dbus-send', () async {
      final asked = <String>[];
      final ok = await linuxTrayHostAvailable(run: (e, a) async {
        asked.add(e);
        if (e == 'gdbus') throw const ProcessException('gdbus', []);
        return _r(0, 'method return\n   boolean true\n');
      });
      expect(ok, isTrue);
      expect(asked, ['gdbus', 'dbus-send']);
    });

    test('只剩 busctl：exit 0 才算有', () async {
      Future<bool> probe(int busctlExit) =>
          linuxTrayHostAvailable(run: (e, a) async {
            if (e == 'busctl') return _r(busctlExit);
            throw ProcessException(e, a);
          });
      expect(await probe(0), isTrue);
      expect(await probe(1), isFalse);
    });

    test('🔴 全都問不到 → 當作沒有（寧可直接結束，不留叫不回來的視窗）', () async {
      expect(
          await linuxTrayHostAvailable(
              run: (e, a) async => throw ProcessException(e, a)),
          isFalse);
      expect(await linuxTrayHostAvailable(run: (e, a) async => _r(1)), isFalse);
    });
  });

  group('WindowTray 在 macOS／Linux', () {
    final realSupported = WindowTray.supportedOverride;
    final realPlatform = WindowTray.platform;
    final realProbe = WindowTray.trayHostAvailable;
    late _Tray tray;
    late _Window window;

    setUp(() {
      WindowTray.supportedOverride = true;
      tray = _Tray();
      window = _Window();
      WindowTray.tray = tray;
      WindowTray.window = window;
    });

    tearDown(() async {
      WindowTray.trayHostAvailable = () async => true;
      await WindowTray.instance.setEnabled(false);
      WindowTray.supportedOverride = realSupported;
      WindowTray.platform = realPlatform;
      WindowTray.trayHostAvailable = realProbe;
    });

    test('macOS：放 template 圖、裝上關閉攔截', () async {
      WindowTray.platform = AppPlatform.macos;
      WindowTray.trayHostAvailable = () async => true;
      await WindowTray.instance.setEnabled(true);

      expect(tray.icons, [('assets/tray_template.png', true)]);
      expect(window.preventCloseCalls, [true]);
      expect(WindowTray.instance.enabled, isTrue);
    });

    test('Linux 有匣宿主：放彩色 PNG、裝攔截', () async {
      WindowTray.platform = AppPlatform.linux;
      WindowTray.trayHostAvailable = () async => true;
      await WindowTray.instance.setEnabled(true);

      expect(tray.icons, [('assets/tray.png', false)]);
      expect(window.preventCloseCalls, [true]);
      expect(WindowTray.instance.enabled, isTrue);
    });

    test('🔴 Linux 沒有匣宿主：不放圖示、不裝攔截——關閉視窗直接結束', () async {
      WindowTray.platform = AppPlatform.linux;
      WindowTray.trayHostAvailable = () async => false;
      await WindowTray.instance.setEnabled(true);

      expect(tray.icons, isEmpty);
      expect(window.preventCloseCalls, isNot(contains(true)),
          reason: '裝了攔截卻沒有匣＝視窗藏起來之後再也叫不回來');
      expect(WindowTray.instance.enabled, isFalse);
    });
  });
}
