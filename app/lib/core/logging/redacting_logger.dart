import 'dart:developer' as developer;

import 'package:logging/logging.dart';

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

/// 初始化全域 logger：一律經過 redact 再輸出。
/// 驗收條件（P3-02 條件 4）：token 不出現在任何 log。
void setupLogging({Level level = Level.INFO}) {
  Logger.root.level = level;
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
  });
}
