import 'package:flutter/material.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/l10n.dart';
import '../../models/board.dart';
import '../../widgets/host_reason.dart';
import '../../widgets/uep_button.dart';

/// 拆頁對話框問出來的結果：週期名稱，與主持人模式下的理由。
@immutable
class SplitInboxInput {
  const SplitInboxInput({required this.title, this.reason = ''});

  final String title;
  final String reason;
}

/// 把「未分類」的一頁拆成獨立週期：問週期名稱。
///
/// 名稱必填、不可為「未分類」——Hub 也會擋（`title_required`、
/// `inbox_title_reserved`），擋在這裡是讓人不必送出去才知道。
/// 主持人模式下多一欄理由（沿用 [HostReasonField]）。
///
/// **不做 API 呼叫**：只負責問，送出是呼叫端的事。取消回 null。
Future<SplitInboxInput?> showSplitInboxDialog(BuildContext context) =>
    showDialog<SplitInboxInput>(
      context: context,
      builder: (_) => _SplitInboxDialog(showReason: isHostViewOn(context)),
    );

class _SplitInboxDialog extends StatefulWidget {
  const _SplitInboxDialog({required this.showReason});

  final bool showReason;

  @override
  State<_SplitInboxDialog> createState() => _SplitInboxDialogState();
}

class _SplitInboxDialogState extends State<_SplitInboxDialog> {
  final _title = TextEditingController();
  final _reason = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _submit() {
    final l10n = AppLocalizations.of(context);
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = l10n.boardErrorTitleRequired);
      return;
    }
    if (title == kUncategorisedTitle) {
      setState(() => _error = l10n.boardErrorInboxTitleReserved);
      return;
    }
    Navigator.of(context)
        .pop(SplitInboxInput(title: title, reason: _reason.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      backgroundColor: s.bgCard,
      title: Text(l10n.boardInboxSplit,
          style: UepText.sectionTitle(color: s.inkTitle)),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            key: const ValueKey('split-inbox-title'),
            controller: _title,
            autofocus: true,
            style: UepText.sans(size: 14, color: s.ink),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              labelText: l10n.boardInboxSplitNameLabel,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(_error!,
                  style: UepText.serif(size: 13.5, color: UepColors.errorText)),
            ),
          ],
          if (widget.showReason) ...[
            const SizedBox(height: 12),
            HostReasonField(controller: _reason),
          ],
        ]),
      ),
      actions: [
        UepButton(
          label: l10n.commonCancel,
          variant: UepButtonVariant.outline,
          small: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
        UepButton(
            label: l10n.boardInboxSplitConfirm, small: true, onPressed: _submit),
      ],
    );
  }
}
