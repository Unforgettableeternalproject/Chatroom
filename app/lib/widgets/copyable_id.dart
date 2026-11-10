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
  });

  final String value;
  final String? label;
  final double size;

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
            style: UepText.mono(size: size, color: s.inkMute, letterSpacing: .4),
          ),
        ),
      ),
    );
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
