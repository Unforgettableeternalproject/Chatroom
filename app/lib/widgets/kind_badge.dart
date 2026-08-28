import 'package:flutter/material.dart';

import '../core/theme/uep_tokens.dart';
import '../core/theme/uep_theme.dart';

/// participant.kind → 色軸顏色（設計稿的訊息左側色條與徽章色）。
Color kindColor(String kind, {required BuildContext context}) {
  switch (kind) {
    case 'claude':
      return UepColors.kindClaude;
    case 'codex':
      return UepColors.kindCodex;
    case 'human':
      return UepColors.kindHuman;
    default:
      return UepColors.kindOther;
  }
}

/// mono 小字 uppercase 徽章：CLAUDE / CODEX / HUMAN / OTHER。
class KindBadge extends StatelessWidget {
  const KindBadge({super.key, required this.kind, this.compact = false});

  final String kind;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = kindColor(kind, context: context);
    final label = kind.toUpperCase();
    if (compact) {
      return Text(label,
          style: UepText.mono(size: 8, color: color, letterSpacing: 1.0));
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: .4)),
      ),
      child: Text(label,
          style: UepText.mono(size: 8.5, color: color, letterSpacing: 1.2)),
    );
  }
}

/// mono uppercase 標籤（設計稿隨處可見的小標）。
class MonoLabel extends StatelessWidget {
  const MonoLabel(this.text,
      {super.key, this.size = 9, this.color, this.letterSpacing = 1.8});

  final String text;
  final double size;
  final Color? color;
  final double letterSpacing;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: UepText.mono(
        size: size,
        color: color ?? context.uep.inkMute,
        letterSpacing: letterSpacing,
      ),
    );
  }
}
