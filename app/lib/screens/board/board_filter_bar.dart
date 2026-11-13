import 'package:flutter/material.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/l10n.dart';
import '../../models/board_task_filter.dart';

/// 任務板的篩選列：關鍵字＋狀態、依賴、認領三顆下拉。
class BoardFilterBar extends StatefulWidget {
  const BoardFilterBar({super.key, required this.filter, required this.onChanged});

  final BoardTaskFilter filter;
  final ValueChanged<BoardTaskFilter> onChanged;

  @override
  State<BoardFilterBar> createState() => _BoardFilterBarState();
}

class _BoardFilterBarState extends State<BoardFilterBar> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.filter.keyword);

  @override
  void didUpdateWidget(BoardFilterBar old) {
    super.didUpdateWidget(old);
    // 外部清除時同步輸入框；打字當中 keyword 與輸入框一致，不會動到游標
    if (widget.filter.keyword != _ctrl.text) {
      _ctrl.text = widget.filter.keyword;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Map<String, String> _statusLabels(AppLocalizations l10n) => {
        'todo': l10n.boardStatusTodo,
        'in_progress': l10n.boardStatusInProgress,
        'blocked': l10n.boardStatusBlocked,
        'done': l10n.boardStatusDone,
        'cancelled': l10n.boardStatusCancelled,
      };

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final f = widget.filter;
    final statuses = _statusLabels(l10n);
    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 10, 26, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 220,
            child: TextField(
              key: const ValueKey('board-filter-keyword'),
              controller: _ctrl,
              onChanged: (v) => widget.onChanged(f.copyWith(keyword: v)),
              style: UepText.sans(size: 13, color: s.ink),
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                prefixIcon: Icon(Icons.search, size: 16, color: s.inkMute),
                prefixIconConstraints:
                    const BoxConstraints(minWidth: 32, minHeight: 32),
                hintText: l10n.boardFilterSearch,
              ),
            ),
          ),
          _Choice<String?>(
            key: const ValueKey('board-filter-status'),
            label: l10n.boardFilterStatus,
            value: f.status,
            options: [
              (null, l10n.boardFilterAny),
              for (final e in statuses.entries) (e.key, e.value),
            ],
            onSelected: (v) => widget.onChanged(f.copyWith(status: () => v)),
          ),
          _Choice<TriFilter>(
            key: const ValueKey('board-filter-dependency'),
            label: l10n.boardFilterDependency,
            value: f.dependency,
            options: [
              (TriFilter.any, l10n.boardFilterAny),
              (TriFilter.yes, l10n.boardFilterHasDependency),
              (TriFilter.no, l10n.boardFilterNoDependency),
            ],
            onSelected: (v) => widget.onChanged(f.copyWith(dependency: v)),
          ),
          _Choice<TriFilter>(
            key: const ValueKey('board-filter-claimed'),
            label: l10n.boardFilterClaim,
            value: f.claimed,
            options: [
              (TriFilter.any, l10n.boardFilterAny),
              (TriFilter.yes, l10n.boardFilterClaimed),
              (TriFilter.no, l10n.boardFilterUnclaimed),
            ],
            onSelected: (v) => widget.onChanged(f.copyWith(claimed: v)),
          ),
          if (f.isActive)
            InkWell(
              key: const ValueKey('board-filter-clear'),
              onTap: () => widget.onChanged(const BoardTaskFilter()),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                child: Text(l10n.boardFilterClear,
                    style: UepText.mono(
                        size: 10.5, color: UepColors.gold, letterSpacing: 1.2)),
              ),
            ),
        ],
      ),
    );
  }
}

/// 下拉小按鈕：「標籤：目前值」，選了非預設值時框線轉金色。
class _Choice<T> extends StatelessWidget {
  const _Choice({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onSelected,
  });

  final String label;
  final T value;

  /// 第一項是「不限」。
  final List<(T, String)> options;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final on = value != options.first.$1;
    final current = options.firstWhere((o) => o.$1 == value).$2;
    final color = on ? UepColors.gold : s.ink;
    return PopupMenuButton<int>(
      tooltip: label,
      onSelected: (i) => onSelected(options[i].$1),
      itemBuilder: (_) => [
        for (var i = 0; i < options.length; i++)
          PopupMenuItem(value: i, child: Text(options[i].$2)),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: color.withValues(alpha: .5)),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(on ? current : label,
              style: UepText.mono(size: 10.5, color: color, letterSpacing: .5)),
          Icon(Icons.arrow_drop_down, size: 16, color: color),
        ]),
      ),
    );
  }
}
