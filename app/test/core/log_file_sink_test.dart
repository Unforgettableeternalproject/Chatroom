import 'dart:io';

import 'package:chatroom_app/core/logging/log_file_sink.dart';
import 'package:chatroom_app/core/logging/redacting_logger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('chatroom-log-'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('落檔是 append，不是每次重開就把前面洗掉', () {
    // open(…, 'w') 的失敗會留下 0 bytes，而這個檔案存在的唯一理由
    // 就是事後回去讀它。
    LogFileSink(dir).write('第一行');
    LogFileSink(dir).write('第二行'); // 另一個 instance，模擬重啟
    expect(LogFileSink(dir).file.readAsStringSync(), '第一行\n第二行\n');
  });

  test('目錄不存在時自己建出來', () {
    final nested = Directory('${dir.path}${Platform.pathSeparator}a'
        '${Platform.pathSeparator}b');
    LogFileSink(nested).write('hi');
    expect(nested.existsSync(), isTrue);
  });

  test('超過上限換檔，舊的那份完整留著（rename，不是清空）', () {
    final sink = LogFileSink(dir, maxBytes: 40);
    sink.write('A' * 50);
    expect(sink.previous.existsSync(), isFalse, reason: '第一次寫不換檔');
    sink.write('B');
    expect(sink.previous.readAsStringSync(), '${'A' * 50}\n');
    expect(sink.file.readAsStringSync(), 'B\n');
  });

  test('落檔失敗不往外拋，也不會每則都洗一次版', () {
    // 拿一個「同名檔案已存在」的路徑當目錄——createSync 必炸
    final blocker = File('${dir.path}${Platform.pathSeparator}blocked')
      ..writeAsStringSync('x');
    final sink = LogFileSink(Directory(blocker.path));
    expect(() {
      sink.write('一');
      sink.write('二');
    }, returnsNormally);
  });

  test('落檔內容一樣要遮蔽 token——含 error 與 stackTrace', () {
    final rec = LogRecord(
      Level.SEVERE,
      'connect ws://h/ws?token=abcd1234 失敗',
      'ws',
      StateError('Authorization: Bearer supersecret'),
      StackTrace.fromString('at ws://h/ws?token=zzzz'),
    );
    final line = formatRecord(rec);
    expect(line, contains('token=«REDACTED»'));
    expect(line, contains('Bearer «REDACTED»'));
    expect(line, isNot(contains('abcd1234')));
    expect(line, isNot(contains('supersecret')));
    expect(line, isNot(contains('zzzz')));
    expect(line, contains('SEVERE'));
    expect(line, contains('ws:'));
  });

  test('預設落點的路徑分隔真的分得開（別讓跳脫把它併成一段）', () {
    // 這條是為了釘住一個已經發生過的錯：路徑用字面反斜線寫，Dart 把
    // 不合法的跳脫靜靜吃掉，結果目錄名變成 UEPChatroomlogs——一個字
    // 都不會提示，只有去找檔案的人會找不到。
    final dir = defaultLogDirectory({
      'LOCALAPPDATA': 'BASE',
      'HOME': 'BASE',
      'XDG_STATE_HOME': 'BASE',
    });
    expect(dir, isNotNull);
    final segments = dir!.path.split(Platform.pathSeparator);
    expect(segments.first, 'BASE');
    expect(segments.length, greaterThan(1), reason: '至少要分得出一層');
    expect(segments.any((s) => s.contains('UEPChatroom')), isFalse);
  });

  test('沒有任何可寫位置時回 null——不落在工作目錄', () {
    expect(defaultLogDirectory(const {}), isNull);
  });

  test('setupLogging 真的把 Logger 的輸出寫進檔案', () async {
    final sink = LogFileSink(dir);
    setupLogging(fileSink: sink, enableFile: false);
    Logger('codex_dispatch').info('mention 補投成功（設計討論，2 則）');
    // onRecord 是非同步廣播，讓出一個 microtask 週期
    await Future<void>.delayed(Duration.zero);
    expect(
      sink.file.readAsStringSync(),
      contains('mention 補投成功（設計討論，2 則）'),
    );
    expect(logFile?.path, sink.file.path);
  });
}
