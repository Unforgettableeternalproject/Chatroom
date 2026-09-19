import 'dart:io';

import 'package:chatroom_app/core/util/env_file.dart';
import 'package:flutter_test/flutter_test.dart';

/// `.env` 的改寫規則。
///
/// 這一層的要害只有一個：**主持人自己寫在 `.env` 裡的東西不能消失**。
/// 整份重寫過一次的教訓寫在 `host-kit/install.py:update_env()` 上面——
/// 那時安裝器從頭到尾顯示成功，而使用者的設定全沒了。
void main() {
  group('applyEnvUpdates', () {
    test('🔴 只覆寫指定的 key，註解、空行與順序原樣保留', () {
      const original = '# Hub 設定，改完要重啟\n'
          'CHATROOM_HOST=127.0.0.1\n'
          'CHATROOM_PORT=8787\n'
          '\n'
          '# 這是我自己加的\n'
          'CHATROOM_IDLE_TIMEOUT=600\n';

      final out = applyEnvUpdates(original, {'CHATROOM_PORT': '9000'});

      expect(
        out,
        '# Hub 設定，改完要重啟\n'
        'CHATROOM_HOST=127.0.0.1\n'
        'CHATROOM_PORT=9000\n'
        '\n'
        '# 這是我自己加的\n'
        'CHATROOM_IDLE_TIMEOUT=600\n',
      );
    });

    test('沒有的 key 追加在尾端', () {
      final out = applyEnvUpdates(
        'CHATROOM_HOST=127.0.0.1\n',
        {'CHATROOM_LOG_LEVEL': 'DEBUG'},
      );
      expect(out, 'CHATROOM_HOST=127.0.0.1\nCHATROOM_LOG_LEVEL=DEBUG\n');
    });

    test('🔴 最後一行沒有換行時，追加前先補一個', () {
      final out = applyEnvUpdates(
        'CHATROOM_PORT=8787',
        {'CHATROOM_TOKEN': 'abc'},
      );
      expect(out, 'CHATROOM_PORT=8787\nCHATROOM_TOKEN=abc\n',
          reason: '黏在一起的話兩個設定同時失效，而檔案看起來還是有內容的');
    });

    test('CRLF 的行尾留著，不把整份換成 LF', () {
      final out = applyEnvUpdates(
        'CHATROOM_HOST=127.0.0.1\r\nCHATROOM_PORT=8787\r\n',
        {'CHATROOM_PORT': '9000'},
      );
      expect(out, 'CHATROOM_HOST=127.0.0.1\r\nCHATROOM_PORT=9000\r\n');
    });

    test('值裡有 `=` 的 token 覆寫得掉，也切得對', () {
      final out = applyEnvUpdates(
        'CHATROOM_TOKEN=aa==\n',
        {'CHATROOM_TOKEN': 'bb=='},
      );
      expect(out, 'CHATROOM_TOKEN=bb==\n');
      expect(parseEnvText(out)['CHATROOM_TOKEN'], 'bb==');
    });

    test('註解掉的 key 不算數：不覆寫它，照樣追加新的一行', () {
      final out = applyEnvUpdates(
        '# CHATROOM_PORT=8787\n',
        {'CHATROOM_PORT': '9000'},
      );
      expect(out, '# CHATROOM_PORT=8787\nCHATROOM_PORT=9000\n');
    });
  });

  group('writeEnvUpdates', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('env_file_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('先寫暫存檔再換檔名，寫完不留 .tmp', () async {
      final file = File('${dir.path}${Platform.pathSeparator}.env');
      file.writeAsStringSync('# 我的設定\nCHATROOM_PORT=8787\n');

      await writeEnvUpdates(file, {'CHATROOM_PORT': '9000'});

      expect(file.readAsStringSync(), '# 我的設定\nCHATROOM_PORT=9000\n');
      expect(File('${file.path}.tmp').existsSync(), isFalse);
    });

    test('檔案不存在時從空的開始，只寫指定的 key', () async {
      final file = File('${dir.path}${Platform.pathSeparator}.env');
      await writeEnvUpdates(file, {'CHATROOM_URL': 'http://127.0.0.1:8787'});
      expect(file.readAsStringSync(), 'CHATROOM_URL=http://127.0.0.1:8787\n');
    });

    test('🔴 沒有要改的東西就不動檔案', () async {
      final file = File('${dir.path}${Platform.pathSeparator}.env');
      file.writeAsStringSync('CHATROOM_PORT=8787\n');
      final before = file.lastModifiedSync();

      await writeEnvUpdates(file, {});

      expect(file.readAsStringSync(), 'CHATROOM_PORT=8787\n');
      expect(file.lastModifiedSync(), before);
    });
  });

  group('欄位驗證', () {
    test('埠號要是 1–65535 的整數', () {
      expect(validateEnvPort('8787'), isNull);
      expect(validateEnvPort('1'), isNull);
      expect(validateEnvPort('65535'), isNull);
      expect(validateEnvPort('0'), EnvFieldError.portRange);
      expect(validateEnvPort('65536'), EnvFieldError.portRange);
      expect(validateEnvPort('87.5'), EnvFieldError.notInteger);
      expect(validateEnvPort('abc'), EnvFieldError.notInteger);
    });

    test('🔴 留空的意思是「沒設，用預設值」——本來有值才不准清空', () {
      expect(validateEnvPort(''), isNull);
      expect(validateEnvPort('', required: true), EnvFieldError.required);
      expect(validateEnvNonNegativeInt(''), isNull);
      expect(validateEnvNonNegativeInt('', required: true),
          EnvFieldError.required);
    });

    test('秒數／天數是非負整數', () {
      expect(validateEnvNonNegativeInt('0'), isNull);
      expect(validateEnvNonNegativeInt('600'), isNull);
      expect(validateEnvNonNegativeInt('-1'), EnvFieldError.negative);
      expect(validateEnvNonNegativeInt('600.5'), EnvFieldError.notInteger);
    });

    test('網址要有 http／https 與 host', () {
      expect(validateEnvUrl('http://127.0.0.1:8787'), isNull);
      expect(validateEnvUrl('https://hub.example.com'), isNull);
      expect(validateEnvUrl('127.0.0.1:8787'), EnvFieldError.badUrl);
      expect(validateEnvUrl('ftp://x/y'), EnvFieldError.badUrl);
      expect(validateEnvUrl('http://'), EnvFieldError.badUrl);
    });

    test('必填文字：只有空白也算空', () {
      expect(validateEnvRequiredText('  '), EnvFieldError.required);
      expect(validateEnvRequiredText('INFO'), isNull);
    });
  });
}
