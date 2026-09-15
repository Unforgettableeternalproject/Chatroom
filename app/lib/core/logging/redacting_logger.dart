import 'dart:developer' as developer;
import 'dart:io';

import 'package:logging/logging.dart';

import 'log_file_sink.dart';

final _tokenPatterns = [
  // Authorization: Bearer xxx
  RegExp(r'Bearer\s+\S+'),
  // ws://.../ws?token=xxx 或任何 query string 內的 token
  RegExp(r'token=[^&\s"]+'),
];

/// 遮蔽字串中的 token。所有可能含憑據的 log 內容都必須先過這裡。
String redact(String input) {
  var out = input;
  for (final p in _tokenPatterns) {
    out = out.replaceAllMapped(p, (m) {
      final s = m.group(0)!;
      final prefix = s.startsWith('Bearer') ? 'Bearer ' : 'token=';
      return '$prefix«REDACTED»';
    });
  }
  return out;
}

/// 一行落檔格式。時間 + 等級 + logger 名稱，讓事後翻檔的人對得上時序。
String formatRecord(LogRecord rec) {
  final buf = StringBuffer()
    ..write(rec.time.toIso8601String())
    ..write(' ')
    ..write(rec.level.name.padRight(7))
    ..write(' ')
    ..write(rec.loggerName)
    ..write(': ')
    ..write(redact(rec.message));
  // error／stackTrace 一樣要過 redact——憑據出現在例外訊息裡的機會
  // 不比正文低（連線失敗的例外常常把整個 URL 印出來）
  if (rec.error != null) buf.write('\n  error: ${redact('${rec.error}')}');
  final st = rec.stackTrace;
  if (st != null) buf.write('\n${redact('$st')}');
  return buf.toString();
}

/// 目前這個 session 的落檔位置；沒落檔時為 `null`（設定頁顯示用）。
File? get logFile => _sink?.file;
LogFileSink? _sink;

/// 初始化全域 logger：一律經過 redact 再輸出。
/// 驗收條件（P3-02 條件 4）：token 不出現在任何 log。
///
/// 同時落檔一份——`developer.log` 在 release build 裡沒有任何讀者，
/// 詳見 [LogFileSink]。[fileSink] 給 `null` 以外的值可覆寫落點（測試用）；
/// 不落檔要明確傳 `enableFile: false`。
void setupLogging({
  Level level = Level.INFO,
  LogFileSink? fileSink,
  bool enableFile = true,
}) {
  Logger.root.level = level;
  if (enableFile) {
    final dir = defaultLogDirectory();
    _sink = fileSink ?? (dir == null ? null : LogFileSink(dir));
  } else {
    _sink = fileSink;
  }
  Logger.root.onRecord.listen((rec) {
    final msg = redact(rec.message);
    developer.log(
      msg,
      time: rec.time,
      level: rec.level.value,
      name: rec.loggerName,
      error: rec.error,
      stackTrace: rec.stackTrace,
    );
    _sink?.write(formatRecord(rec));
  });
}
