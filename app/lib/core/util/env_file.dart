/// `.env` 的讀與寫。
///
/// ## 為什麼不是整份重寫
///
/// 規則照抄 `host-kit/install.py` 的 `update_env()`：**只覆寫指定的 key，
/// 其餘行、註解與順序原樣保留**。`.env` 是人會去讀、去改的檔案——主持人
/// 自己加的設定、寫給自己的註解，在存檔那一刻消失是最難查的一種壞法，
/// 而畫面上會顯示成功。
///
/// 寫檔也照同一套：先寫暫存檔再換檔名。直接 open(..,'w') 在寫到一半失敗時
/// 留下 0 位元組的 `.env`，那時 Hub 起不來，而本來只是想改一個埠號。
library;

import 'dart:io';

/// 解析 `.env`。規則與 server `config.py`、`install.py:read_env()` 一致：
/// 忽略空行與 `#` 開頭，只切第一個 `=`（token 是 urlsafe base64，值裡可能
/// 還有 `=`）。
Map<String, String> parseEnvText(String text) {
  final values = <String, String>{};
  for (final line in text.split('\n')) {
    final stripped = line.trim();
    if (stripped.isEmpty || stripped.startsWith('#')) continue;
    final at = stripped.indexOf('=');
    if (at <= 0) continue;
    values[stripped.substring(0, at).trim()] =
        stripped.substring(at + 1).trim();
  }
  return values;
}

/// 把 [updates] 套到 [original] 上，回傳新的檔案內容。
///
/// - 既有的 key 就地覆寫，行的位置不動。
/// - 沒有的 key 追加在尾端。
/// - 註解、空行、不認得的 key 全部原樣保留。
///
/// ⚠️ 追加之前要確認前一行有換行，否則兩個設定會黏成
/// `CHATROOM_PORT=8787CHATROOM_TOKEN=...`——兩個同時失效，而檔案看起來
/// 還是有內容的。
String applyEnvUpdates(String original, Map<String, String> updates) {
  final remaining = Map<String, String>.of(updates);
  final out = <String>[];
  // 追加的行跟著這份檔案原本的行尾走。`.env` 在 Windows 上多半是 CRLF，
  // 補一行 LF 進去會讓下一次編輯的 diff 看起來莫名其妙
  final eol = original.contains('\r\n') ? '\r\n' : '\n';

  if (original.isNotEmpty) {
    for (final line in _linesKeepingEnds(original)) {
      final stripped = line.trim();
      final newline = line.endsWith('\r\n')
          ? '\r\n'
          : line.endsWith('\n')
              ? '\n'
              : '';
      var key = '';
      if (stripped.isNotEmpty && !stripped.startsWith('#')) {
        final at = stripped.indexOf('=');
        if (at > 0) key = stripped.substring(0, at).trim();
      }
      if (key.isNotEmpty && remaining.containsKey(key)) {
        out.add('$key=${remaining.remove(key)}$newline');
      } else {
        out.add(line);
      }
    }
  }

  if (remaining.isNotEmpty) {
    if (out.isNotEmpty && !out.last.endsWith('\n')) {
      out[out.length - 1] = '${out.last}$eol';
    }
    remaining.forEach((key, value) => out.add('$key=$value$eol'));
  }
  return out.join();
}

/// 一行一項，換行字元留在行尾（Python `splitlines(keepends=True)` 的語意）。
///
/// CRLF 也留著：`.env` 在 Windows 上多半是 CRLF，把它整份換成 LF 等於
/// 在 diff 裡動了每一行，而使用者只改了一個欄位。
List<String> _linesKeepingEnds(String text) {
  final out = <String>[];
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    if (text[i] == '\n') {
      out.add(text.substring(start, i + 1));
      start = i + 1;
    }
  }
  if (start < text.length) out.add(text.substring(start));
  return out;
}

/// 把 [updates] 寫回 [file]。檔案不存在時就從空的開始（只寫這幾個 key）。
Future<void> writeEnvUpdates(File file, Map<String, String> updates) async {
  if (updates.isEmpty) return;
  final original = await file.exists() ? await file.readAsString() : '';
  final text = applyEnvUpdates(original, updates);
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString(text);
  await tmp.rename(file.path);
}

/// 欄位驗證的結果。**不帶文案**——訊息屬於畫面，這一層只說是哪一種錯，
/// 才能在沒有 l10n 的測試裡直接驗。
enum EnvFieldError {
  /// 本來有值，被清成空的。
  required,
  notInteger,
  portRange,
  negative,
  badUrl,
}

/// 埠號：整數、1–65535。[required] 為 false 時留空代表「用預設值」。
EnvFieldError? validateEnvPort(String value, {bool required = false}) {
  final text = value.trim();
  if (text.isEmpty) return required ? EnvFieldError.required : null;
  final n = int.tryParse(text);
  if (n == null) return EnvFieldError.notInteger;
  if (n < 1 || n > 65535) return EnvFieldError.portRange;
  return null;
}

/// 秒數／天數／配額：非負整數。[required] 為 false 時留空代表「用預設值」。
EnvFieldError? validateEnvNonNegativeInt(String value,
    {bool required = false}) {
  final text = value.trim();
  if (text.isEmpty) return required ? EnvFieldError.required : null;
  final n = int.tryParse(text);
  if (n == null) return EnvFieldError.notInteger;
  if (n < 0) return EnvFieldError.negative;
  return null;
}

/// 網址：要有 http／https scheme 與 host。
EnvFieldError? validateEnvUrl(String value, {bool required = false}) {
  final text = value.trim();
  if (text.isEmpty) return required ? EnvFieldError.required : null;
  final uri = Uri.tryParse(text);
  if (uri == null) return EnvFieldError.badUrl;
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    return EnvFieldError.badUrl;
  }
  if (uri.host.isEmpty) return EnvFieldError.badUrl;
  return null;
}

/// 不能留空的純文字。
EnvFieldError? validateEnvRequiredText(String value) =>
    value.trim().isEmpty ? EnvFieldError.required : null;
