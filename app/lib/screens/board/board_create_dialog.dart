import 'package:flutter/material.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../widgets/kind_badge.dart';
import '../../widgets/uep_button.dart';

/// 建立 Objective / Checklist / Task 的對話框（設計稿 artboard 04）。
///
/// 三層共用同一個表單，差別只在標題文字與「要不要問優先度」——三個各寫一份
/// 的話，改一次欄位就要記得改三個地方，而漏掉的那個不會有任何地方報錯。
class BoardCreateResult {
  const BoardCreateResult({
    required this.title,
    this.description = '',
    this.priority = 'normal',
  });

  final String title;
  final String description;
  final String priority;
}

Future<BoardCreateResult?> showBoardCreateDialog(
  BuildContext context, {
  required String kind,
  String? parentTitle,
  String? initialTitle,
}) =>
    showDialog<BoardCreateResult>(
      context: context,
      builder: (_) => _BoardCreateDialog(
          kind: kind, parentTitle: parentTitle, initialTitle: initialTitle),
    );

class _BoardCreateDialog extends StatefulWidget {
  const _BoardCreateDialog(
      {required this.kind, this.parentTitle, this.initialTitle});

  /// objective / checklist / task
  final String kind;

  /// 它會被放進哪裡（「Board 功能上線 › Hub 端」）。三層樹裡「這張卡會長在
  /// 哪」是最容易搞錯的一件事，所以寫在標題底下而不是讓人自己記。
  final String? parentTitle;

  /// 預先填好的標題。從一則訊息建卡時就是那句話——**還是可以改**，
  /// 訊息本身多半不是一個好的任務名，但要人從空白開始打會讓這條路徑
  /// 變得比複製貼上還麻煩。
  final String? initialTitle;

  @override
  State<_BoardCreateDialog> createState() => _BoardCreateDialogState();
}

class _BoardCreateDialogState extends State<_BoardCreateDialog> {
  late final _title = TextEditingController(text: widget.initialTitle ?? '');
  final _description = TextEditingController();
  String _priority = 'normal';

  static const _labels = {
    'objective': ('新增週期', '一次可交付的成果。做完它就是一個段落。'),
    'checklist': ('新增階段', '這個週期底下的一組事（「Hub 端」「測試與除錯」）。'),
    'task': ('新增任務', '一件一個人做得完的事。'),
  };

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  void _submit() {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    Navigator.of(context).pop(BoardCreateResult(
      title: title,
      description: _description.text.trim(),
      priority: _priority,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final (heading, hint) = _labels[widget.kind]!;

    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(heading, style: UepText.display(size: 22, color: s.inkTitle)),
          if (widget.parentTitle != null) ...[
            const SizedBox(height: 4),
            Text(widget.parentTitle!,
                style: UepText.mono(size: 10, color: s.inkMute)),
          ],
        ],
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _field('標題', _title, hint: hint),
            const SizedBox(height: 14),
            _field('描述（可留白）', _description,
                hint: '之後接手的人需要知道什麼？', lines: 3),
            if (widget.kind == 'task') ...[
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerLeft,
                child: MonoLabel('優先度', color: s.inkSoft,
                    letterSpacing: 1.4),
              ),
              const SizedBox(height: 7),
              Row(
                children: [
                  for (final p in const [
                    ('low', '低'),
                    ('normal', '中'),
                    ('high', '高'),
                  ]) ...[
                    _PriorityChip(
                      label: p.$2,
                      selected: _priority == p.$1,
                      onTap: () => setState(() => _priority = p.$1),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ],
          ]),
        ),
      ),
      actions: [
        UepButton(
          label: '取消',
          variant: UepButtonVariant.outline,
          onPressed: () => Navigator.of(context).pop(),
        ),
        UepButton(label: '建立', onPressed: _submit),
      ],
    );
  }

  Widget _field(String label, TextEditingController controller,
      {String? hint, int lines = 1}) {
    final s = context.uep;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      MonoLabel(label, color: s.inkSoft, letterSpacing: 1.4),
      const SizedBox(height: 7),
      Container(
        decoration: BoxDecoration(
          color: s.bgSunken,
          border: Border.all(color: s.hairlineStrong),
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: TextField(
          controller: controller,
          maxLines: lines,
          autofocus: lines == 1,
          onSubmitted: lines == 1 ? (_) => _submit() : null,
          style: UepText.serif(size: 13, color: s.ink, height: 1.6),
          decoration: InputDecoration(
            isDense: true,
            border: InputBorder.none,
            hintText: hint,
            hintStyle: UepText.serif(size: 12, color: s.inkMute),
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      ),
    ]);
  }
}

class _PriorityChip extends StatelessWidget {
  const _PriorityChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? UepColors.gold.withValues(alpha: .12) : null,
          border: Border.all(
              color: selected ? UepColors.gold : s.hairlineStrong),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(label,
            style: UepText.mono(
                size: 11, color: selected ? UepColors.gold : s.ink)),
      ),
    );
  }
}
