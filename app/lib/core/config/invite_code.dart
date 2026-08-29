import 'dart:convert';

import 'package:flutter/foundation.dart';

/// 一份邀請：連進哪台 Hub、用哪把 token。
@immutable
class InviteCode {
  const InviteCode({
    required this.serverUrl,
    required this.token,
    this.label = '',
  });

  final String serverUrl;
  final String token;

  /// 發給誰（主持人填的標註）。只是給對方看的提示，不影響任何行為。
  final String label;

  /// 版本前綴。日後格式若要改，舊 App 才能明確說「這個邀請碼太新了」，
  /// 而不是解出一堆亂碼再用一個看不懂的錯誤把人擋在門外。
  static const _prefix = 'CHATROOM-INVITE-1.';

  /// 編成一串可以貼在聊天軟體裡的文字。
  ///
  /// 刻意不做成網址：`http://…?token=…` 貼到哪都會被自動連結、被預覽服務
  /// 抓去展開，token 就跟著外流了。這串沒有 scheme，不會被當成連結。
  String encode() {
    final json = jsonEncode({
      'u': serverUrl,
      't': token,
      if (label.isNotEmpty) 'n': label,
    });
    return _prefix + base64Url.encode(utf8.encode(json));
  }

  /// 解析邀請碼；格式不對回 null（由呼叫端決定要怎麼講）。
  ///
  /// base64 只是為了讓它變成一串不會被手動改壞的文字，**不是加密**——
  /// 任何拿到這串字的人都能還原出 token，所以它的傳遞方式要當成密碼看待。
  static InviteCode? tryParse(String raw) {
    final text = raw.trim();
    if (!text.startsWith(_prefix)) return null;
    try {
      final json = jsonDecode(
          utf8.decode(base64Url.decode(text.substring(_prefix.length))));
      if (json is! Map) return null;
      final url = (json['u'] as String?)?.trim() ?? '';
      final token = (json['t'] as String?)?.trim() ?? '';
      if (url.isEmpty || token.isEmpty) return null;
      return InviteCode(
        serverUrl: url,
        token: token,
        label: (json['n'] as String?) ?? '',
      );
    } catch (_) {
      // 貼歪了、少一段、被聊天軟體換行——都走同一條路：這不是一份邀請
      return null;
    }
  }
}
