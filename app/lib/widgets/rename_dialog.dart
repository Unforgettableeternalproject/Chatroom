import 'package:flutter/material.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import 'uep_button.dart';

/// 改名對話框——房間與板共用（c271c7ff）。
///
/// **同一個動作只做一份**：兩邊的規則完全一樣（不能空、要 trim、改完會在
/// 房裡留一則系統訊息），各寫一份的話那些規則就會各自漂移，而漂移的那一半
/// 沒有任何地方會報錯。
///
/// 回傳新名字；使用者取消時回 null。**不做 API 呼叫**——它只負責問出一個
/// 名字，送出去是呼叫端的事（兩條軸的身分來源不同）。
Future<String?> showRenameDialog(
  BuildContext context, {
  required String title,
  required String current,
  String hint = '',
}) =>
    showDialog<String>(
      context: context,
      builder: (_) =>
          _RenameDialog(title: title, current: current, hint: hint),
    );

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({
    required this.title,
    required this.current,
    required this.hint,
  });

  final String title;
  final String current;
  final String hint;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _text = TextEditingController(text: widget.current);
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _text.text.trim();
    // 空字串 Hub 回 422。擋在這裡是為了讓拒絕的理由**看起來像它自己**——
    // 422 的原話講的是欄位驗證，讀的人得自己翻譯成「名字不能空白」
    if (name.isEmpty) {
      setState(() => _error = '名字不能是空的');
      return;
    }
    // 沒改就當取消。送一個一樣的名字上去會在房裡留下一則
    // 「X 將房間改名為 Y」的系統訊息，而什麼都沒變
    if (name == widget.current.trim()) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return AlertDialog(
      backgroundColor: s.bgCard,
      title:
          Text(widget.title, style: UepText.display(size: 20, color: s.inkTitle)),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text('改名會在房裡留下一則系統訊息——誰改的、改成什麼，都看得到。',
                style: UepText.serif(size: 12, color: s.inkMute, height: 1.5)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _text,
            autofocus: true,
            style: UepText.sans(size: 13, color: s.ink),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              hintText: widget.hint,
              hintStyle: UepText.sans(size: 12.5, color: s.inkMute),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(_error!,
                  style: UepText.serif(size: 12.5, color: UepColors.errorText)),
            ),
          ],
        ]),
      ),
      actions: [
        UepButton(
          label: '取消',
          variant: UepButtonVariant.outline,
          small: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
        UepButton(label: '改名', small: true, onPressed: _submit),
      ],
    );
  }
}
