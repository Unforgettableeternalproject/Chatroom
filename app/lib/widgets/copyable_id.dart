import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../l10n/l10n.dart';

/// 開發者模式用的 ID 小標：mono 小字、低調色，點一下複製 [value]。
///
/// [label] 是畫面上顯示的字（預設就是 [value]）；複製的永遠是 [value]。
/// 複製後以 SnackBar 提示「已複製」。
class CopyableId extends StatelessWidget {
  const CopyableId({
    super.key,
    required this.value,
    this.label,
    this.size = 10,
    this.ellipsis = false,
  });

  final String value;
  final String? label;
  final double size;

  /// 空間不夠時單行加省略號（需放在有寬度上限的位置）；預設不截斷。
  final bool ellipsis;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Tooltip(
      message: AppLocalizations.of(context).commonCopy,
      child: InkWell(
        onTap: () => copyIdToClipboard(context, value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          child: Text(
            label ?? value,
            maxLines: ellipsis ? 1 : null,
            softWrap: !ellipsis,
            overflow: ellipsis ? TextOverflow.ellipsis : TextOverflow.clip,
            style: UepText.mono(size: size, color: s.inkMute, letterSpacing: .4),
          ),
        ),
      ),
    );
  }
}

/// 標題優先的「標題＋ID」並排：標題完整保留（過長才由標題自己省略號），
/// ID 只取標題之後剩下的寬度，剩餘不足 [minIdWidth] 就整個不畫。
///
/// 放在 Row 的 `Flexible`／`Expanded` 內使用，量的是那個格子的寬度。
class TitleWithId extends StatelessWidget {
  const TitleWithId({
    super.key,
    required this.title,
    required this.titleStyle,
    required this.id,
    this.showId = true,
    this.gap = 10,
    this.minIdWidth = 56,
    this.plainOverflow = TextOverflow.ellipsis,
  });

  final String title;
  final TextStyle titleStyle;
  final String id;
  final bool showId;
  final double gap;
  final double minIdWidth;

  /// [showId] 為 false（開發者模式關）時標題照原樣畫，這是當時的 overflow；
  /// 不加 maxLines，換行行為與沒有這個元件之前一致。
  final TextOverflow? plainOverflow;

  @override
  Widget build(BuildContext context) {
    if (!showId) {
      return Text(title, overflow: plainOverflow, style: titleStyle);
    }
    final titleText = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: titleStyle,
    );
    return LayoutBuilder(builder: (context, c) {
      final painter = TextPainter(
        text: TextSpan(text: title, style: titleStyle),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final left = c.maxWidth - painter.width - gap;
      painter.dispose();
      if (!left.isFinite || left < minIdWidth) return titleText;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: titleText),
          SizedBox(width: gap),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: left),
            child: CopyableId(value: id, ellipsis: true),
          ),
        ],
      );
    });
  }
}

/// 複製 [value] 並提示「已複製」。右鍵選單等非 [CopyableId] 的入口共用。
Future<void> copyIdToClipboard(BuildContext context, String value) async {
  await Clipboard.setData(ClipboardData(text: value));
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(AppLocalizations.of(context).commonCopied),
      duration: const Duration(seconds: 2),
    ));
}
