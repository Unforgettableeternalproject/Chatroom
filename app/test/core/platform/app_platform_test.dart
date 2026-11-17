import 'package:chatroom_app/core/platform/app_platform.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('chatroomInstallRoot', () {
    test('Windows：LOCALAPPDATA 底下的 UEP/Chatroom', () {
      expect(
        chatroomInstallRoot(
            platform: AppPlatform.windows,
            environment: {'LOCALAPPDATA': r'C:\Users\a\AppData\Local'}),
        r'C:\Users\a\AppData\Local\UEP\Chatroom',
      );
    });

    test('Windows：沒有 LOCALAPPDATA 退到家目錄的 .chatroom/kits', () {
      expect(
        chatroomInstallRoot(
            platform: AppPlatform.windows,
            environment: {'USERPROFILE': r'C:\Users\a'}),
        r'C:\Users\a\.chatroom\kits',
      );
      expect(
          chatroomInstallRoot(platform: AppPlatform.windows, environment: {}),
          '');
    });

    test('macOS：~/Library/Application Support/UEP/Chatroom', () {
      expect(
        chatroomInstallRoot(
            platform: AppPlatform.macos,
            // LOCALAPPDATA 在 macOS 上不該影響結果
            environment: {'HOME': '/Users/a', 'LOCALAPPDATA': r'C:\x'}),
        '/Users/a/Library/Application Support/UEP/Chatroom',
      );
    });

    test('Linux：XDG_DATA_HOME 優先，相對路徑視為無效', () {
      expect(
        chatroomInstallRoot(
            platform: AppPlatform.linux,
            environment: {'HOME': '/home/a', 'XDG_DATA_HOME': '/data'}),
        '/data/uep/chatroom',
      );
      expect(
        chatroomInstallRoot(
            platform: AppPlatform.linux,
            environment: {'HOME': '/home/a', 'XDG_DATA_HOME': 'rel/path'}),
        '/home/a/.local/share/uep/chatroom',
      );
      expect(
        chatroomInstallRoot(
            platform: AppPlatform.linux, environment: {'HOME': '/home/a'}),
        '/home/a/.local/share/uep/chatroom',
      );
      expect(
          chatroomInstallRoot(platform: AppPlatform.linux, environment: {}),
          '');
    });
  });

  group('chatroomRegistryFile', () {
    test('POSIX 用 HOME 與正斜線', () {
      final f = chatroomRegistryFile('host-kit.json',
          platform: AppPlatform.linux, environment: {'HOME': '/home/a'});
      expect(f!.path.replaceAll(r'\', '/'), '/home/a/.chatroom/host-kit.json');
      expect(f.path.contains(r'\'), isFalse);
    });

    test('拿不到家目錄回 null', () {
      expect(
          chatroomRegistryFile('x.json',
              platform: AppPlatform.macos, environment: {}),
          isNull);
    });
  });

  test('AppPlatform.sep 跟著被測平台，不跟著跑測試的機器', () {
    expect(AppPlatform.macos.join(['a', 'b']), 'a/b');
    expect(AppPlatform.windows.join(['a', 'b']), r'a\b');
  });
}
