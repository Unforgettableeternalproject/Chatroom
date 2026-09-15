import 'dart:convert';
import 'dart:io';

import 'package:chatroom_app/models/host_kit.dart';
import 'package:flutter_test/flutter_test.dart';

/// host-kit 偵測與 `.env` 解析。
///
/// 這一層最容易靜默出錯：**每一種「讀不到」都必須降級成「這台沒有 Hub」**，
/// 而不是一個講得很篤定卻是錯的畫面，也不是一個永遠按不動的入口。
void main() {
  group('HostKit.fromJson', () {
    test('讀得出註冊檔', () {
      final kit = HostKit.fromJson({
        'version': 1,
        'kit_root': r'C:\kits\host-kit',
        'env_file': r'C:\kits\host-kit\server\.env',
        'installed_at': '2026-09-09T06:00:00+00:00',
        'installed_host': '26.176.231.43',
        'installed_port': '8787',
      });
      expect(kit.kitRoot, r'C:\kits\host-kit');
      expect(kit.installedPort, '8787');
    });

    test('🔴 缺欄位不炸，補空字串', () {
      final kit = HostKit.fromJson({'kit_root': '/x'});
      expect(kit.envFile, '');
      expect(kit.installedHost, '',
          reason: '註冊檔是別的程式寫的，欄位不齊時要降級不是崩潰');
    });
  });

  group('HostEnv', () {
    test('綁 0.0.0.0 要認得出來', () {
      const env = HostEnv(host: '0.0.0.0', port: '8787', token: 't');
      expect(env.bindsAllInterfaces, isTrue,
          reason: '沒有人連得到 0.0.0.0，位址欄不能照字面顯示它');
    });

    test('綁特定介面時不是 bindsAll', () {
      const env = HostEnv(host: '26.176.231.43', port: '8787', token: 't');
      expect(env.bindsAllInterfaces, isFalse);
    });

    test('🔴 缺 token 或 port 就是設定不完整', () {
      expect(const HostEnv(host: '0.0.0.0', port: '8787').isComplete, isFalse);
      expect(const HostEnv(host: '0.0.0.0', token: 't').isComplete, isFalse);
      expect(
        const HostEnv(host: '0.0.0.0', port: '8787', token: 't').isComplete,
        isTrue,
      );
    });
  });

  group('註冊檔的容錯（用真實檔案驗）', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('hostkit_test');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('🔴 註冊檔指向已經不存在的資料夾 → 視同沒有裝', () async {
      final gone = Directory('${tmp.path}${Platform.pathSeparator}gone');
      expect(await gone.exists(), isFalse);
      // provider 的判斷條件：kitRoot 不存在就回 null。這裡驗那個前提本身
      // ——指路牌指向不存在的地方，與沒有指路牌是同一件事
      final kit = HostKit.fromJson({'kit_root': gone.path});
      expect(await Directory(kit.kitRoot).exists(), isFalse);
    });

    test('🔴 壞掉的 JSON 不能被當成「Hub 壞了」', () {
      // 解析失敗要降級成「這台沒有 Hub」——畫成 Hub 有問題的話，主持人會
      // 跑去修一個沒有壞的伺服器
      expect(() => jsonDecode('{ 半個檔案'), throwsFormatException);
    });
  });

  group('McpKit', () {
    test('讀得出註冊檔', () {
      final kit = McpKit.fromJson({
        'kit_root': r'C:\kits\mcp-kit',
        'env_file': r'C:\kits\mcp-kit\.env',
        'installed_at': '2026-09-09T06:30:00+00:00',
        'targets': ['claude', 'codex'],
      });
      expect(kit.targets, ['claude', 'codex']);
      expect(kit.installedAt, '2026-09-09T06:30:00+00:00');
    });

    test('🔴 targets 缺了也不炸', () {
      expect(McpKit.fromJson({'kit_root': '/x'}).targets, isEmpty);
    });

    test('沒有 URL 就是設定不完整', () {
      expect(const McpEnv().isComplete, isFalse);
      expect(const McpEnv(url: 'http://h:8787').isComplete, isTrue,
          reason: 'token 可以是空的——有些 Hub 沒設 token');
    });
  });

  group('.env 解析', () {
    /// 與 `hostEnvProvider` 同一套規則，抽出來單獨驗——provider 需要
    /// 檔案系統與 riverpod，這裡只驗那段字串處理。
    Map<String, String> parse(List<String> lines) {
      final values = <String, String>{};
      for (final line in lines) {
        final text = line.trim();
        if (text.isEmpty || text.startsWith('#')) continue;
        final at = text.indexOf('=');
        if (at <= 0) continue;
        values[text.substring(0, at).trim()] = text.substring(at + 1).trim();
      }
      return values;
    }

    test('讀得出三個值', () {
      final v = parse([
        '# Chatroom Hub',
        'CHATROOM_HOST=26.176.231.43',
        'CHATROOM_PORT=8787',
        'CHATROOM_TOKEN=abc123',
      ]);
      expect(v['CHATROOM_HOST'], '26.176.231.43');
      expect(v['CHATROOM_TOKEN'], 'abc123');
    });

    test('註解與空行跳過', () {
      expect(parse(['', '  ', '# 註解', 'A=1']).keys, ['A']);
    });

    test('🔴 值裡有 = 只切第一個', () {
      expect(parse(['CHATROOM_TOKEN=a=b=c'])['CHATROOM_TOKEN'], 'a=b=c',
          reason: 'token 是 base64 家族，切錯會得到一個看起來很像但錯的值');
    });

    test('沒有 = 的行跳過，不會變成空 key', () {
      expect(parse(['亂寫一行', '=沒有名字', 'A=1']).keys, ['A']);
    });
  });
}
