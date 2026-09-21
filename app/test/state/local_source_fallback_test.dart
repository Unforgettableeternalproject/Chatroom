import 'dart:convert';
import 'dart:io';

import 'package:chatroom_app/models/host_kit.dart';
import 'package:chatroom_app/state/mcp_kit_providers.dart';
import 'package:chatroom_app/state/runner_kit_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 沒有安裝包登錄檔時的**本機來源**偵測。
///
/// 這一層的要害只有一個：**「沒有登錄檔」不等於「這台沒有」**。直接跑
/// repo 裡那份 bridge、或手動部署執行器的機器從來不會有登錄檔，而兩者
/// 都正在運作——把它們判成「沒裝」，畫面就對著一台在跑的機器說它什麼
/// 都沒有，而且沒有任何地方會報錯。
///
/// 三種狀況各驗一次：登錄檔存在／登錄檔沒有但本機來源在／兩者皆無。
void main() {
  late Directory tmp;
  final sep = Platform.pathSeparator;

  String join(List<String> parts) => parts.join(sep);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('local_source_test');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// 造一個長得像 repo 的目錄：`<root>/bridge/chatroom_mcp` + `server/.env`。
  Future<String> makeRepo({String version = '1.2.3', String? build}) async {
    final root = join([tmp.path, 'repo']);
    await Directory(join([root, 'bridge', 'chatroom_mcp'])).create(
        recursive: true);
    await File(join([root, 'bridge', 'chatroom_mcp', 'version.py']))
        .writeAsString('APP_VERSION = "$version"\n');
    if (build != null) {
      await File(join([root, 'bridge', 'chatroom_mcp', '_build.json']))
          .writeAsString(build);
    }
    await Directory(join([root, 'server'])).create(recursive: true);
    await File(join([root, 'server', '.env']))
        .writeAsString('CHATROOM_URL=http://127.0.0.1:8787\n');
    return root;
  }

  group('MCP bridge', () {
    test('登錄檔存在 → 用它，來源是安裝包', () async {
      final kitRoot = join([tmp.path, 'mcp-kit']);
      await Directory(kitRoot).create(recursive: true);
      final registry = File(join([tmp.path, 'mcp-kit.json']));
      await registry.writeAsString(jsonEncode({
        'kit_root': kitRoot,
        'env_file': join([kitRoot, '.env']),
        'installed_at': '2026-09-18T06:00:00+00:00',
        'targets': ['claude'],
      }));

      final kit = await resolveMcpKit(registry: registry);
      expect(kit, isNotNull);
      expect(kit!.source, KitSource.installed);
      expect(kit.kitRoot, kitRoot);
      expect(kit.bridgePath, join([kitRoot, 'bridge']),
          reason: '安裝包沒有記 bridge 目錄，就是 kit 根目錄底下那個');
    });

    test('🔴 沒有登錄檔、但本機找得到 bridge → 算有，來源是本機', () async {
      final root = await makeRepo();
      final kit = await resolveMcpKit(
        registry: File(join([tmp.path, 'nope.json'])),
        walkFrom: [join([root, 'app', 'build', 'windows'])],
      );

      expect(kit, isNotNull, reason: '直接跑 repo 那份的人從來不會有登錄檔');
      expect(kit!.source, KitSource.local);
      expect(kit.bridgePath, join([root, 'bridge']));
      expect(kit.envFile, join([root, 'server', '.env']),
          reason: '.env 的真相在 repo 的 server/.env');
    });

    test('環境變數指定的 bridge 優先於往上找', () async {
      final root = await makeRepo();
      final kit = await resolveMcpKit(
        registry: null,
        environment: {'CHATROOM_BRIDGE_PATH': join([root, 'bridge'])},
      );
      expect(kit?.bridgePath, join([root, 'bridge']));
    });

    test('執行器設定的 bridge_path 也算數', () async {
      final root = await makeRepo();
      final configPath = join([tmp.path, 'config.json']);
      await File(configPath).writeAsString(
          jsonEncode({'bridge_path': join([root, 'bridge'])}));

      final kit = await resolveMcpKit(
        registry: null,
        environment: {'CHATROOM_RUNNER_CONFIG': configPath},
      );
      expect(kit?.bridgePath, join([root, 'bridge']));
    });

    test('🔴 有好幾份 bridge 時，挑說得出連線設定的那一份', () async {
      final repo = await makeRepo();
      final bare = join([tmp.path, 'copied']);
      await Directory(join([bare, 'bridge', 'chatroom_mcp']))
          .create(recursive: true);

      final kit = await resolveMcpKit(
        registry: null,
        // 先列沒有 .env 的那一份，它不該贏
        environment: {'CHATROOM_BRIDGE_PATH': join([bare, 'bridge'])},
        walkFrom: [join([repo, 'app'])],
      );
      expect(kit?.bridgePath, join([repo, 'bridge']),
          reason: '挑到沒有 .env 的那份，分頁會出現卻永遠答不出「連得上嗎」');
    });

    test('只有一份而且沒有 .env → 照樣算有（位置與版本仍然是真的）', () async {
      final bare = join([tmp.path, 'copied']);
      await Directory(join([bare, 'bridge', 'chatroom_mcp']))
          .create(recursive: true);
      final kit = await resolveMcpKit(
        registry: null,
        environment: {'CHATROOM_BRIDGE_PATH': join([bare, 'bridge'])},
      );
      expect(kit?.source, KitSource.local);
      expect(kit?.envFile, '');
    });

    test('🔴 .env 只有 host／port 時組得出 URL（Hub 自己那份長這樣）', () async {
      final envPath = join([tmp.path, 'server.env']);
      await File(envPath)
          .writeAsString('CHATROOM_HOST=10.0.0.5\nCHATROOM_TOKEN=t\n');
      final container = ProviderContainer(overrides: [
        mcpKitProvider.overrideWith((ref) async => McpKit(
              kitRoot: tmp.path,
              envFile: envPath,
              source: KitSource.local,
            )),
      ]);
      addTearDown(container.dispose);

      final env = await container.read(mcpEnvProvider.future);
      expect(env?.url, 'http://10.0.0.5:8787');
      expect(env?.token, 't');
    });

    test('🔴 兩者皆無 → null（分頁整個不出現）', () async {
      final kit = await resolveMcpKit(
        registry: File(join([tmp.path, 'nope.json'])),
        environment: {'USERPROFILE': join([tmp.path, 'empty-home'])},
        walkFrom: [join([tmp.path, 'empty'])],
      );
      expect(kit, isNull);
    });

    test('版本：有 _build.json 就用它', () async {
      final root = await makeRepo(
          build: jsonEncode({'version': '1.2.3', 'commit': 'abc123abc123'}));
      expect(await readBridgeVersion(join([root, 'bridge'])),
          '1.2.3+abc123abc123');
    });

    test('🔴 沒有 _build.json、也不是 git 工作樹 → 版號 + unknown', () async {
      final root = await makeRepo(version: '9.9.9');
      expect(await readBridgeVersion(join([root, 'bridge'])), '9.9.9+unknown',
          reason: '「不知道是哪一版」與「是某一版」是兩件事，不要偽造 commit');
    });

    test('連 version.py 都沒有 → 空字串（畫面顯示讀不到）', () async {
      expect(await readBridgeVersion(join([tmp.path, 'nothing'])), '');
    });
  });

  group('執行器', () {
    test('登錄檔存在 → 用它，來源是安裝包', () async {
      final kitDir = join([tmp.path, 'Runner']);
      await Directory(kitDir).create(recursive: true);
      final registry = File(join([tmp.path, 'runner-kit.json']));
      await registry.writeAsString(jsonEncode({
        'kit_dir': kitDir,
        'config': join([tmp.path, 'config.json']),
        'python': join([kitDir, '.venv', 'Scripts', 'python.exe']),
      }));

      final kit = await resolveRunnerKit(registry: registry);
      expect(kit, isNotNull);
      expect(kit!.source, KitSource.installed);
      expect(kit.kitDir, kitDir);
    });

    test('🔴 沒有登錄檔、但 config.json 在 → 算有，程式目錄從 bridge_path 推',
        () async {
      final kitDir = join([tmp.path, 'Runner']);
      await Directory(join([kitDir, 'bridge'])).create(recursive: true);
      final configPath = join([tmp.path, 'config.json']);
      await File(configPath).writeAsString(jsonEncode({
        'bridge_path': join([kitDir, 'bridge']),
        'projects': {'a': <String, dynamic>{}},
      }));

      final kit = await resolveRunnerKit(
        registry: File(join([tmp.path, 'nope.json'])),
        environment: {'CHATROOM_RUNNER_CONFIG': configPath},
      );
      expect(kit, isNotNull, reason: '手動部署的執行器正在接派工，只是沒有登錄檔');
      expect(kit!.source, KitSource.local);
      expect(kit.configPath, configPath);
      expect(kit.kitDir, kitDir);
    });

    test('config.json 也沒有、但排程工作在 → 從工作推設定與程式目錄', () async {
      final kitDir = join([tmp.path, 'Runner']);
      await Directory(kitDir).create(recursive: true);
      final configPath = join([tmp.path, 'from-task.json']);

      final kit = await resolveRunnerKit(
        registry: null,
        environment: {'CHATROOM_RUNNER_CONFIG': join([tmp.path, 'nope.json'])},
        scheduledTask: () async => RunnerTaskInfo(
          command: join([kitDir, '.venv', 'Scripts', 'pythonw.exe']),
          workingDirectory: kitDir,
          configPath: configPath,
        ),
      );
      expect(kit, isNotNull);
      expect(kit!.configPath, configPath);
      expect(kit.kitDir, kitDir);
      expect(kit.source, KitSource.local);
    });

    test('🔴 兩者皆無 → null（分頁整個不出現）', () async {
      final kit = await resolveRunnerKit(
        registry: File(join([tmp.path, 'nope.json'])),
        environment: {'CHATROOM_RUNNER_CONFIG': join([tmp.path, 'none.json'])},
        scheduledTask: () async => null,
      );
      expect(kit, isNull);
    });

    test('排程工作的 XML 解得出程式、工作目錄與 --config', () {
      const xml = '''
<Task><Actions>
  <Exec>
    <Command>E:\\Chatroom\\Runner\\.venv\\Scripts\\pythonw.exe</Command>
    <Arguments>-m chatroom_runner --config "C:/state/config.json"</Arguments>
    <WorkingDirectory>E:/Chatroom/Runner</WorkingDirectory>
  </Exec>
</Actions></Task>''';
      final info = parseRunnerTaskXml(xml);
      expect(info, isNotNull);
      expect(info!.workingDirectory, 'E:/Chatroom/Runner');
      expect(info.configPath, 'C:/state/config.json');
      expect(info.command, endsWith('pythonw.exe'));
    });

    test('版本：_build.json 優先，沒有就讀 VERSION.txt', () async {
      final kitDir = join([tmp.path, 'Runner']);
      await Directory(join([kitDir, 'runner', 'chatroom_runner']))
          .create(recursive: true);
      await File(join([kitDir, 'VERSION.txt']))
          .writeAsString('copied: 325617dd34b5\n');
      expect(await readRunnerVersion(kitDir), 'copied: 325617dd34b5');

      await File(join([kitDir, 'runner', 'chatroom_runner', '_build.json']))
          .writeAsString(
              jsonEncode({'version': '1.2.3', 'commit': '325617dd34b5'}));
      expect(await readRunnerVersion(kitDir), '1.2.3+325617dd34b5');
    });

    test('程式目錄什麼都沒有 → 空字串', () async {
      expect(await readRunnerVersion(join([tmp.path, 'nothing'])), '');
    });
  });
}
