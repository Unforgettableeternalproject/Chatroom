import 'dart:io';

import 'package:chatroom_app/models/host_kit.dart';
import 'package:chatroom_app/state/host_kit_providers.dart';
import 'package:chatroom_app/state/mcp_kit_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 兩個 `.env` 的原始鍵值 provider——設定表單讀的就是它們。
///
/// 讀不到檔案時回 `null`（畫面說「讀不到」），**不是空 Map**：空 Map 會讓
/// 表單畫成一堆空欄位，而存一次檔就把使用者原本的設定改寫成空的。
void main() {
  late Directory dir;
  late File envFile;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('env_raw');
    envFile = File('${dir.path}${Platform.pathSeparator}.env');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('Hub：讀得出每一個 key，註解與空行不算', () async {
    envFile.writeAsStringSync('# 註解\n\nCHATROOM_PORT=8787\nCHATROOM_TOKEN=a=b\n');
    final c = ProviderContainer(overrides: [
      hostKitProvider.overrideWith(
          (ref) async => HostKit(kitRoot: dir.path, envFile: envFile.path)),
    ]);
    addTearDown(c.dispose);

    expect(await c.read(hostEnvRawProvider.future),
        {'CHATROOM_PORT': '8787', 'CHATROOM_TOKEN': 'a=b'});
  });

  test('🔴 Hub：`.env` 不存在回 null，不是空 Map', () async {
    final c = ProviderContainer(overrides: [
      hostKitProvider.overrideWith((ref) async => HostKit(
          kitRoot: dir.path,
          envFile: '${dir.path}${Platform.pathSeparator}nope.env')),
    ]);
    addTearDown(c.dispose);

    expect(await c.read(hostEnvRawProvider.future), isNull);
  });

  test('MCP：讀得出 bridge 那份', () async {
    envFile.writeAsStringSync('CHATROOM_URL=http://127.0.0.1:8787\n');
    final c = ProviderContainer(overrides: [
      mcpKitProvider.overrideWith(
          (ref) async => McpKit(kitRoot: dir.path, envFile: envFile.path)),
    ]);
    addTearDown(c.dispose);

    expect(await c.read(mcpEnvRawProvider.future),
        {'CHATROOM_URL': 'http://127.0.0.1:8787'});
  });

  test('MCP：這一份說不出 `.env` 在哪就回 null', () async {
    final c = ProviderContainer(overrides: [
      mcpKitProvider.overrideWith(
          (ref) async => McpKit(kitRoot: dir.path, envFile: '')),
    ]);
    addTearDown(c.dispose);

    expect(await c.read(mcpEnvRawProvider.future), isNull);
  });
}
