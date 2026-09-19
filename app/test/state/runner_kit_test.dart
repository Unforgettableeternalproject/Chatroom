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

}
