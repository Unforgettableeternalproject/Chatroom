import 'package:flutter/material.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../widgets/uep_button.dart';

/// 一張卡改完之後的樣子：標題與敘述。
///
/// 兩個欄位一起回，而且**沒改的那個回 null**——`_board_patch` 只跳過 null，
/// 空字串是一個真的值，會把敘述**清掉**。把「沒動它」與「清空它」送成同一
/// 個東西的話，只改標題的人會發現敘述不見了，而且沒有任何地方報錯。
@immutable
class TaskEdit {
  const TaskEdit({this.title, this.description});

  /// 新標題；沒改回 null。
  final String? title;

  /// 新敘述；沒改回 null。**空字串是「清空」，是使用者真的做了那件事。**
  final String? description;

  bool get isEmpty => title == null && description == null;
}

/// 改一張卡的標題與敘述（艾斯維爾 09/08）。
///
/// 與 `showRenameDialog` 分開的理由：那個是**單欄位**的改名，房間與板共用；
/// 這裡要的是標題＋敘述兩格，而敘述是多行、可以留空。硬塞進同一個對話框
/// 會讓改房名的人看到一個他永遠用不到的敘述欄。
///
/// **不做 API 呼叫**——它只負責問出改成什麼，送出去是呼叫端的事（兩條軸的
/// 身分來源不同，與 `showRenameDialog` 同一個理由）。
///
/// 使用者取消、或什麼都沒改時回 null。
Future<TaskEdit?> showTaskEditDialog(
  BuildContext context, {
  required String title,
  required String description,
}) =>
    showDialog<TaskEdit>(
      context: context,
      builder: (_) => _TaskEditDialog(title: title, description: description),
    );

/// 改卡片不留痕，與週期／階段改名同一件事（`_board_patch` 不發 system 訊息）。
const kTaskEditNoTrace = '改動不會在房裡留訊息——看板的人下次看到的就是新的。';

class _TaskEditDialog extends StatefulWidget {
  const _TaskEditDialog({required this.title, required this.description});

  final String title;
  final String description;

  @override
  State<_TaskEditDialog> createState() => _TaskEditDialogState();
}

class _TaskEditDialogState extends State<_TaskEditDialog> {
  late final _title = TextEditingController(text: widget.title);
  late final _desc = TextEditingController(text: widget.description);
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _desc.dispose();
    super.dispose();
  }

  void _submit() {
    final title = _title.text.trim();
    // 空標題 Hub 會照收（`body.title.strip() if body.title else None` 把它
    // 變成 None ⇒ 靜靜地不改）。擋在這裡是為了讓「我清空了標題卻沒反應」
    // 有一個說得出口的理由
    if (title.isEmpty) {
      setState(() => _error = '標題不能是空的');
      return;
    }
    final desc = _desc.text;
    Navigator.of(context).pop(TaskEdit(
      title: title == widget.title.trim() ? null : title,
      // 敘述**不 trim 掉整段**：使用者故意留的換行是內容的一部分。
      // 但與原值相同就是沒改
      description: desc == widget.description ? null : desc,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return AlertDialog(
      backgroundColor: s.bgCard,
      title: Text('編輯任務卡',
          style: UepText.display(size: 20, color: s.inkTitle)),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(kTaskEditNoTrace,
                style: UepText.serif(size: 12, color: s.inkMute, height: 1.5)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _title,
            autofocus: true,
            style: UepText.sans(size: 13, color: s.ink),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              labelText: '標題',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _desc,
            minLines: 3,
            maxLines: 8,
            style: UepText.sans(size: 13, color: s.ink),
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              labelText: '敘述',
              hintText: '選填。這張卡要做什麼、為什麼。',
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
        UepButton(label: '儲存', small: true, onPressed: _submit),
      ],
    );
  }
}
