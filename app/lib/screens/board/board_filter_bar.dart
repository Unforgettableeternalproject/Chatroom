import 'package:flutter/material.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/l10n.dart';
import '../../models/board_task_filter.dart';

/// 任務板的篩選列：關鍵字＋狀態、依賴、認領三顆下拉（展開後才顯示，
/// 開關見 [BoardFilterToggle]）。
class BoardFilterBar extends StatefulWidget {
  const BoardFilterBar({
    super.key,
    required this.filter,
    required this.onChanged,
  });

  final BoardTaskFilter filter;
  final ValueChanged<BoardTaskFilter> onChanged;

  @override
  State<BoardFilterBar> createState() => _BoardFilterBarState();
}

class _BoardFilterBarState extends State<BoardFilterBar> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.filter.keyword,
  );

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
    // 面板橫跨整個卡片區、內容靠左，「清除」固定在最右；窄了條件在面板內折行
    final clear = InkWell(
      key: const ValueKey('board-filter-clear'),
      onTap: () => widget.onChanged(const BoardTaskFilter()),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Text(
          l10n.boardFilterClear,
          style: UepText.mono(
            size: 10.5,
            color: UepColors.gold,
            letterSpacing: 1.2,
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(kBoardPaneGutter, 0, kBoardPaneGutter, 10),
      child: Container(
        padding: const EdgeInsets.all(kBoardFilterPanelPadding),
        decoration: BoxDecoration(
          color: s.bgCard,
          border: Border.all(color: s.hairline),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _fields(
                children: [
                  SizedBox(
                    child: TextField(
                      key: const ValueKey('board-filter-keyword'),
                      controller: _ctrl,
                      onChanged: (v) =>
                          widget.onChanged(f.copyWith(keyword: v)),
                      style: UepText.sans(size: 13, color: s.ink),
                      decoration: InputDecoration(
                        isDense: true,
                        border: const OutlineInputBorder(),
                        prefixIcon: Icon(
                          Icons.search,
                          size: 16,
                          color: s.inkMute,
                        ),
                        prefixIconConstraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
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
                    onSelected: (v) =>
                        widget.onChanged(f.copyWith(status: () => v)),
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
                    onSelected: (v) =>
                        widget.onChanged(f.copyWith(dependency: v)),
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
                ],
              ),
            ),
            if (f.isActive) clear,
          ],
        ),
      ),
    );
  }
}

/// 篩選面板的內距。
const double kBoardFilterPanelPadding = 12;

/// 面板內寬小於此值就分兩列（關鍵字一列、三個下拉一列）。
const double kBoardFilterNarrow = 480;

/// 條件欄位的排法：寬時一列、flex 2:1:1:1 撐滿；窄時兩列各自撐滿。
/// [children] 依序是關鍵字欄與三個下拉。
Widget _fields({required List<Widget> children}) {
  return LayoutBuilder(builder: (context, box) {
    final kw = children.first;
    final choices = children.skip(1).toList();
    Widget row(List<Widget> items, [int firstFlex = 1]) => Row(children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(flex: i == 0 ? firstFlex : 1, child: items[i]),
          ],
        ]);
    if (box.maxWidth < kBoardFilterNarrow) {
      return Column(children: [
        row([kw]),
        const SizedBox(height: 8),
        row(choices),
      ]);
    }
    return row([kw, ...choices], 2);
  });
}

/// 週期窗格左右內距：抬頭、橫幅、篩選、階段列與卡片的右緣共用這一個值。
const double kBoardPaneGutter = 26;

/// 釘在清單頂端的「篩選」按鈕列固定高度。
const double kBoardFilterToggleHeight = 44;

/// 「篩選」按鈕：靠右、預設收合時只有它。有條件生效時轉金色並附條件數。
class BoardFilterToggle extends StatelessWidget {
  const BoardFilterToggle({
    super.key,
    required this.filter,
    required this.open,
    required this.onTap,
  });

  final BoardTaskFilter filter;
  final bool open;
  final VoidCallback onTap;

  int get _count =>
      (filter.keyword.trim().isNotEmpty ? 1 : 0) +
      (filter.status != null ? 1 : 0) +
      (filter.dependency != TriFilter.any ? 1 : 0) +
      (filter.claimed != TriFilter.any ? 1 : 0);

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final on = filter.isActive;
    final color = on ? UepColors.gold : s.ink;
    final label = AppLocalizations.of(context).boardFilterToggle;
    return Container(
      height: kBoardFilterToggleHeight,
      color: s.bg,
      padding: const EdgeInsets.fromLTRB(kBoardPaneGutter, 0, kBoardPaneGutter, 0),
      alignment: Alignment.centerRight,
      child: InkWell(
        key: const ValueKey('board-filter-toggle'),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            border: Border.all(color: color.withValues(alpha: .5)),
            borderRadius: BorderRadius.circular(3),
            color: open ? color.withValues(alpha: .08) : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                on ? '$label · $_count' : label,
                style: UepText.mono(
                  size: 10.5,
                  color: color,
                  letterSpacing: .5,
                ),
              ),
              Icon(
                open ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                size: 16,
                color: color,
              ),
            ],
          ),
        ),
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
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                on ? current : label,
                overflow: TextOverflow.ellipsis,
                style: UepText.mono(size: 10.5, color: color, letterSpacing: .5),
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 16, color: color),
          ],
        ),
      ),
    );
  }
}
