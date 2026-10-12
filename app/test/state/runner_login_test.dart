import 'dart:convert';
import 'dart:io';

import 'package:chatroom_app/state/runner_kit_providers.dart';
import 'package:flutter_test/flutter_test.dart';

/// 執行器登入判斷：`claude auth status` 的解析、`mcp list` 的過期字樣、
/// 長效 token 檔的契約。
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('runner-login-state'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String p(String name) => '${dir.path}${Platform.pathSeparator}$name';

  RunnerConfigFile config() => RunnerConfigFile(
        path: p('config.json'),
        raw: const {},
        workspaces: const [],
        modified: DateTime(2026),
        stateDir: dir.path,
        claudeConfigDir: p('claude-config'),
      );

  group('parseClaudeAuthStatus', () {
    test('已登入的實際輸出 → true', () {
      expect(
          parseClaudeAuthStatus('{\n  "loggedIn": true,\n'
              '  "authMethod": "claude.ai",\n  "subscriptionType": "max"\n}'),
          isTrue);
    });

    test('🔴 沒登入時 exit 1 但 stdout 仍是 JSON → false，不是 null', () {
      expect(
          parseClaudeAuthStatus(
              '{"loggedIn": false, "authMethod": "none"}\n'),
          isFalse);
    });

    test('前後夾雜警告行仍解得出', () {
      expect(
          parseClaudeAuthStatus('warning: something\n{"loggedIn": true}\n'),
          isTrue);
    });

    test('看不懂 → null（退回檔案判準）', () {
      expect(parseClaudeAuthStatus(''), isNull);
      expect(parseClaudeAuthStatus("'claude' is not recognized"), isNull);
      expect(parseClaudeAuthStatus('{"authMethod": "none"}'), isNull);
      expect(parseClaudeAuthStatus('{"loggedIn": "yes"}'), isNull);
      expect(parseClaudeAuthStatus('{broken'), isNull);
    });
  });

  group('isClaudeAuthExpiredText', () {
    test('OAuth 過期與 refresh 失敗都算', () {
      expect(isClaudeAuthExpiredText('OAuth session expired. Please /login'),
          isTrue);
      expect(
          isClaudeAuthExpiredText(
              'Error: token could not be refreshed\nNo MCP servers configured'),
          isTrue);
    });

    test('一般的失敗不算', () {
      expect(isClaudeAuthExpiredText('No MCP servers configured'), isFalse);
      expect(isClaudeAuthExpiredText(''), isFalse);
    });
  });

  group('長效 token 檔', () {
    test('🔴 檔名是與執行器的契約：<state_dir>/claude-oauth-token', () {
      expect(runnerOAuthTokenFileFor(config())!.path, p('claude-oauth-token'));
    });

    test('寫入只有 token 一行：去頭尾空白、不帶結尾換行，父目錄自己建', () async {
      final file = File(p('nested${Platform.pathSeparator}claude-oauth-token'));
      await writeRunnerOAuthToken(file, '  sk-ant-oat01-abc  \r\n');
      expect(file.readAsStringSync(), 'sk-ant-oat01-abc');
      expect(await readRunnerOAuthToken(file), 'sk-ant-oat01-abc');
    });

    test('空的或中間有空白的不寫，例外訊息裡沒有 token', () async {
      final file = File(p('claude-oauth-token'));
      await expectLater(
          writeRunnerOAuthToken(file, '   '), throwsFormatException);
      try {
        await writeRunnerOAuthToken(file, 'abc def-secret');
        fail('應該丟例外');
      } on FormatException catch (e) {
        expect('$e', isNot(contains('secret')));
      }
      expect(file.existsSync(), isFalse);
    });

    test('清除刪掉檔案；沒有檔也不丟例外', () async {
      final file = File(p('claude-oauth-token'));
      await writeRunnerOAuthToken(file, 'tok');
      await clearRunnerOAuthToken(file);
      expect(file.existsSync(), isFalse);
      await clearRunnerOAuthToken(file);
      expect(await readRunnerOAuthToken(file), isNull);
    });

    test('空檔不算設定', () async {
      final file = File(p('claude-oauth-token'))..writeAsStringSync('\n  \n');
      expect(await readRunnerOAuthToken(file), isNull);
    });
  });

  group('resolveRunnerClaudeLogin', () {
    Future<RunnerClaudeLogin> resolve(
      bool? probed, {
      bool credentials = false,
      String? token,
      bool mcpExpired = false,
      List<String?>? seenToken,
    }) async {
      final cfg = config();
      final configDir = cfg.claudeConfigDir;
      Directory(configDir).createSync(recursive: true);
      if (credentials) {
        File('$configDir${Platform.pathSeparator}.credentials.json')
            .writeAsStringSync('{"claudeAiOauth": {"accessToken": "x"}}');
      }
      final tokenFile = runnerOAuthTokenFileFor(cfg)!;
      if (token != null) await writeRunnerOAuthToken(tokenFile, token);
      return resolveRunnerClaudeLogin(
        cfg: cfg,
        configDir: configDir,
        probe: (c, {oauthToken}) async {
          seenToken?.add(oauthToken);
          return probed;
        },
        tokenFile: tokenFile,
        mcpAuthExpired: mcpExpired,
      );
    }

    test('🔴 憑證檔在但 claude 說沒登入 → 已過期，不是已登入', () async {
      final r = await resolve(false, credentials: true);
      expect(r.loggedIn, isFalse);
      expect(r.expired, isTrue);
    });

    test('claude 說已登入 → 已登入（不管檔案）', () async {
      final r = await resolve(true);
      expect(r.loggedIn, isTrue);
    });

    test('問不到 → 退回檔案判準', () async {
      expect((await resolve(null)).loggedIn, isFalse);
      expect((await resolve(null)).expired, isFalse);
      expect((await resolve(null, credentials: true)).loggedIn, isTrue);
    });

    test('🔴 mcp list 說 OAuth 過期 → 失效，即使 auth status 說已登入', () async {
      final r = await resolve(true, credentials: true, mcpExpired: true);
      expect(r.loggedIn, isFalse);
      expect(r.expired, isTrue);
    });

    test('有 token 檔時 mcp list 的過期不降級，token 也交給 probe', () async {
      final seen = <String?>[];
      final r = await resolve(true,
          token: 'tok-123', mcpExpired: true, seenToken: seen);
      expect(r.loggedIn, isTrue);
      expect(r.tokenSet, isTrue);
      expect(seen, ['tok-123']);
    });
  });

  test('mergeMcpServers 把 authExpired 帶過去', () {
    const expired = MachineMcpServers(error: 'x', authExpired: true);
    expect(
        mergeMcpServers(expired, const MachineMcpServers(names: ['fff']))
            .authExpired,
        isTrue);
    expect(
        mergeMcpServers(expired, const MachineMcpServers(globalError: 'y'))
            .authExpired,
        isTrue);
  });

  group('終端視窗', () {
    test('設定目錄用 PowerShell 單引號字串，單引號要成對', () {
      expect(claudeTerminalScript(r"C:\it's\cfg", ['auth', 'login']),
          r"$env:CLAUDE_CONFIG_DIR = 'C:\it''s\cfg'; claude auth login");
    });

    test('走 start /wait 與 -EncodedCommand（UTF-16LE base64）', () {
      const script = r"$env:CLAUDE_CONFIG_DIR = 'C:\中文'; claude setup-token";
      final argv = claudeTerminalArgv(script);
      expect(argv.sublist(0, 8), [
        'cmd',
        '/c',
        'start',
        '',
        '/wait',
        'powershell',
        '-NoExit',
        '-EncodedCommand',
      ]);
      final bytes = base64.decode(argv.last);
      final units = <int>[
        for (var i = 0; i + 1 < bytes.length; i += 2)
          bytes[i] | (bytes[i + 1] << 8)
      ];
      expect(String.fromCharCodes(units), script);
    });
  });
}
