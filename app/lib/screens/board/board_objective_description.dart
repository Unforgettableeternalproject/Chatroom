import 'package:flutter/material.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/l10n.dart';
import '../../widgets/uep_button.dart';

/// 週期抬頭的敘述最多顯示幾行；超過就截斷，全文放進「展開」的對話框。
const int kObjectiveDescriptionMaxLines = 4;

/// 週期敘述的固定高度區塊（未分類與其他週期共用同一個抬頭）。
///
/// 敘述再長，抬頭也只佔 [kObjectiveDescriptionMaxLines] 行，不擠壓底下的
/// 階段與卡片；超過才出現「展開」，短敘述沒有按鈕。
class ObjectiveDescription extends StatelessWidget {
  const ObjectiveDescription({super.key, required this.text});

  final String text;

  TextStyle _style(BuildContext context) =>
      UepText.serif(size: 14, color: context.uep.inkSoft, height: 1.85);

  @override
  Widget build(BuildContext context) {
    final style = _style(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620),
      child: LayoutBuilder(builder: (context, box) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: kObjectiveDescriptionMaxLines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: box.maxWidth);
        final overflow = painter.didExceedMaxLines;
        painter.dispose();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(text,
                key: const ValueKey('objective-description-text'),
                maxLines: kObjectiveDescriptionMaxLines,
                overflow: TextOverflow.ellipsis,
                style: style),
            if (overflow) ...[
              const SizedBox(height: 6),
              UepButton(
                key: const ValueKey('objective-description-expand'),
                label: AppLocalizations.of(context).commonExpand,
                variant: UepButtonVariant.outline,
                small: true,
                onPressed: () => showObjectiveDescriptionDialog(context, text),
              ),
            ],
          ],
        );
      }),
    );
  }
}

/// 顯示完整敘述：可捲動、可選取文字。
Future<void> showObjectiveDescriptionDialog(
        BuildContext context, String text) =>
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final s = ctx.uep;
        return AlertDialog(
          backgroundColor: s.bgCard,
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                key: const ValueKey('objective-description-full'),
                style: UepText.serif(size: 14, color: s.inkSoft, height: 1.85),
              ),
            ),
          ),
          actions: [
            UepButton(
              label: AppLocalizations.of(ctx).commonClose,
              variant: UepButtonVariant.outline,
              small: true,
              onPressed: () => Navigator.of(ctx).pop(),
            ),
          ],
        );
      },
    );
