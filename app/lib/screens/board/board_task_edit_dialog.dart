import 'package:flutter/material.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/l10n.dart';
import '../../widgets/uep_button.dart';
import 'board_dependency_picker.dart';

/// 一張卡改完之後的樣子：標題與敘述。
///
/// 兩個欄位一起回，而且**沒改的那個回 null**——`_board_patch` 只跳過 null，
/// 空字串是一個真的值，會把敘述**清掉**。把「沒動它」與「清空它」送成同一
/// 個東西的話，只改標題的人會發現敘述不見了，而且沒有任何地方報錯。
@immutable
class TaskEdit {
  const TaskEdit({this.title, this.description, this.dependsOn, this.affects});

  /// 新標題；沒改回 null。
  final String? title;

  /// 新敘述；沒改回 null。**空字串是「清空」，是使用者真的做了那件事。**
  final String? description;

  /// 新的依賴（task id，整份覆寫）；沒改回 null，**空清單是「清空」**。
  final List<String>? dependsOn;

  /// 新的影響（task id，整份覆寫）；規則同 [dependsOn]。
  final List<String>? affects;

  bool get isEmpty =>
      title == null &&
      description == null &&
      dependsOn == null &&
      affects == null;
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
///
/// 給了 [dependencies] 才會多出「依賴」「影響」兩欄（只有卡片有；週期與階段
/// 沒有這兩個欄位，所以不給）。
Future<TaskEdit?> showTaskEditDialog(
  BuildContext context, {
  required String title,
  required String description,
  DependencyEditSpec? dependencies,
}) =>
    showDialog<TaskEdit>(
      context: context,
      builder: (_) => _TaskEditDialog(
          title: title, description: description, dependencies: dependencies),
    );

class _TaskEditDialog extends StatefulWidget {
  const _TaskEditDialog(
      {required this.title, required this.description, this.dependencies});

  final String title;
  final String description;
  final DependencyEditSpec? dependencies;

  @override
  State<_TaskEditDialog> createState() => _TaskEditDialogState();
}

class _TaskEditDialogState extends State<_TaskEditDialog> {
  late final _title = TextEditingController(text: widget.title);
  late final _desc = TextEditingController(text: widget.description);
  late List<String> _dependsOn = [...?widget.dependencies?.dependsOn];
  late List<String> _affects = [...?widget.dependencies?.affects];
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
      setState(
          () => _error = AppLocalizations.of(context).boardTaskEditTitleEmpty);
      return;
    }
    final desc = _desc.text;
    final dep = widget.dependencies;
    Navigator.of(context).pop(TaskEdit(
      title: title == widget.title.trim() ? null : title,
      // 敘述**不 trim 掉整段**：使用者故意留的換行是內容的一部分。
      // 但與原值相同就是沒改
      description: desc == widget.description ? null : desc,
      // 與原值同一組就是沒改：不送，Hub 就不會多寫一次
      dependsOn: dep != null && !sameIdSet(_dependsOn, dep.dependsOn)
          ? _dependsOn
          : null,
      affects:
          dep != null && !sameIdSet(_affects, dep.affects) ? _affects : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      backgroundColor: s.bgCard,
      title: Text(l10n.boardTaskEditTitle,
          style: UepText.sectionTitle(color: s.inkTitle)),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(l10n.boardTaskEditNoTrace,
                style: UepText.serif(size: 13, color: s.inkMute, height: 1.5)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _title,
            autofocus: true,
            style: UepText.sans(size: 14, color: s.ink),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              labelText: l10n.commonTitleField,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _desc,
            minLines: 3,
            maxLines: 8,
            style: UepText.sans(size: 14, color: s.ink),
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              labelText: l10n.boardTaskEditDescription,
              hintText: l10n.commonOptional,
              hintStyle: UepText.sans(size: 13.5, color: s.inkMute),
            ),
          ),
          if (widget.dependencies != null) ...[
            const SizedBox(height: 14),
            DependencyField(
              label: l10n.boardDependsOnLabel,
              selected: _dependsOn,
              spec: widget.dependencies!,
              excluded: _affects,
              onChanged: (v) => setState(() => _dependsOn = v),
            ),
            const SizedBox(height: 12),
            DependencyField(
              label: l10n.boardAffectsLabel,
              selected: _affects,
              spec: widget.dependencies!,
              excluded: _dependsOn,
              onChanged: (v) => setState(() => _affects = v),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(_error!,
                  style: UepText.serif(size: 13.5, color: UepColors.errorText)),
            ),
          ],
        ]),
        ),
      ),
      actions: [
        UepButton(
          label: l10n.commonCancel,
          variant: UepButtonVariant.outline,
          small: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
        UepButton(label: l10n.commonSave, small: true, onPressed: _submit),
      ],
    );
  }
}
