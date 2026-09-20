import 'package:chatroom_app/state/runner_kit_providers.dart';
import 'package:flutter_test/flutter_test.dart';

/// runner-kit 註冊檔的讀取。
///
/// `config.json` 的工作區／專案模型與 CRUD 在 `runner_workspaces_test.dart`。
void main() {
  group('RunnerKit.fromJson', () {
    test('讀得出註冊檔（安裝器實際寫的四個欄位）', () {
      final kit = RunnerKit.fromJson({
        'kit_dir': r'E:\ProgramFiles\Chatroom\Runner',
        'python': r'E:\ProgramFiles\Chatroom\Runner\.venv\Scripts\python.exe',
        'config': r'C:\Users\me\AppData\Local\UEP\Chatroom\runner\config.json',
        'installed_at': '2026-09-18T06:00:00+00:00',
      });
      expect(kit.kitDir, r'E:\ProgramFiles\Chatroom\Runner');
      expect(kit.configPath, endsWith('config.json'));
      expect(kit.installedAt, '2026-09-18T06:00:00+00:00');
    });

    test('🔴 缺欄位不炸，補空字串', () {
      final kit = RunnerKit.fromJson({'kit_dir': '/x'});
      expect(kit.configPath, '');
      expect(kit.python, '');
    });
  });


  group('parseClaudeMcpList', () {
    // `claude mcp list` 的真實輸出：三種狀態行，連接器與本機 stdio 都有
    const sample = '''
Checking MCP server health…

claude.ai Claude Docs: https://api.anthropic.com/v1/pages/mcp - ✔ Connected
claude.ai Notion: https://mcp.notion.com/mcp - ! Needs authentication
claude.ai Canva: https://mcp.canva.com/mcp - ✘ Failed to connect — MCP server "claude.ai Canva" connection timed out after 30000ms
chatroom: C:/python.exe -m chatroom_mcp - ✔ Connected
''';

    test('🔴 三種狀態都撈得到，本機 stdio 伺服器也算一台', () {
      expect(parseClaudeMcpList(sample), [
        'claude.ai Claude Docs',
        'claude.ai Notion',
        'claude.ai Canva',
        'chatroom',
      ]);
    });

    test('🔴 帶參數的命令不能把那一行吃掉', () {
      // `\S+` 只吃到執行檔就對不上後面的 ` - `，整行會被靜默跳過，
      // 而畫面上只會少一個勾選項，不會有錯誤
      expect(parseClaudeMcpList('fff: C:/fff.exe serve --port 1 - ✔ Connected'),
          ['fff']);
    });

    test('看不懂的行就是沒有伺服器', () {
      expect(parseClaudeMcpList('No MCP servers configured.'), isEmpty);
    });
  });

  group('runnerClaudeConfigDirFor', () {
    RunnerConfigFile cfg({String claudeConfigDir = '', String stateDir = ''}) =>
        RunnerConfigFile(
          path: r'C:\cfg\config.json',
          raw: const {},
          workspaces: const [],
          modified: DateTime(2026, 9, 20),
          stateDir: stateDir,
          claudeConfigDir: claudeConfigDir,
        );

    test('設定有寫就用那一個', () {
      expect(runnerClaudeConfigDirFor(cfg(claudeConfigDir: r'C:\x')), r'C:\x');
    });

    test('🔴 沒寫時是 <state_dir>/claude-config，與執行器同一條規則', () {
      final dir = runnerClaudeConfigDirFor(cfg(stateDir: r'C:\state'));
      expect(dir, endsWith('claude-config'));
      expect(dir, startsWith(r'C:\state'));
    });
  });
}
