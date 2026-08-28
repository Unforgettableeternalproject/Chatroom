import 'package:flutter/material.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';

enum UepButtonVariant { gold, outline, danger }

/// 設計系統的 Button：膠囊形、mono uppercase 字。
/// gold = 金底深字；outline = 線框；danger = 紅系（刪除確認用）。
class UepButton extends StatelessWidget {
  const UepButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = UepButtonVariant.gold,
    this.small = false,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final UepButtonVariant variant;
  final bool small;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final pad = EdgeInsets.symmetric(
        horizontal: small ? 14 : 18, vertical: small ? 7 : 10);
    final textStyle = UepText.mono(
      size: small ? 9.5 : 10.5,
      weight: FontWeight.w500,
      letterSpacing: 1.6,
    );
    final shape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(999));

    final Widget button = switch (variant) {
      UepButtonVariant.gold => FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: UepColors.gold,
            foregroundColor: UepColors.goldInkOn,
            disabledBackgroundColor: UepColors.gold.withValues(alpha: .3),
            padding: pad,
            shape: shape,
            textStyle: textStyle,
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(label.toUpperCase(), style: textStyle),
        ),
      UepButtonVariant.outline => OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: s.lineStrong),
            foregroundColor: s.inkSoft,
            padding: pad,
            shape: shape,
            textStyle: textStyle,
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(label.toUpperCase(), style: textStyle),
        ),
      UepButtonVariant.danger => OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: UepColors.errorText.withValues(alpha: .55)),
            backgroundColor: UepColors.errorText.withValues(alpha: .12),
            foregroundColor: UepColors.errorText,
            padding: pad,
            shape: shape,
            textStyle: textStyle,
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(label.toUpperCase(), style: textStyle),
        ),
    };
    return expand
        ? SizedBox(width: double.infinity, child: button)
        : button;
  }
}
