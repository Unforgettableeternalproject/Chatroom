import 'package:flutter/material.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../core/util/relative_time.dart';
import '../models/message.dart';

/// system 訊息：兩側髮絲線 + mono 小字（設計稿樣式），
/// 與一般發言視覺明顯不同（P3-06 條件 3）。
class SystemMessageTile extends StatelessWidget {
  const SystemMessageTile({super.key, required this.message});

  final Message message;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(child: Container(height: 1, color: s.hairline)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            '${message.content} · ${clockTime(message.createdAt)}',
            style: UepText.mono(size: 9, color: s.inkMute, letterSpacing: 1.4),
            textAlign: TextAlign.center,
          ),
        ),
        Expanded(child: Container(height: 1, color: s.hairline)),
      ]),
    );
  }
}
