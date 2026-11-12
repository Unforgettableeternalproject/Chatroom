import 'package:flutter/material.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/l10n.dart';
import '../../models/board.dart';
import '../../widgets/mention_field.dart';
import '../../widgets/uep_button.dart';

/// 依賴／影響欄可以選的卡。
///
/// 沿用 `#` 卡片指涉的候選型別 [CardCandidate]（同一塊板的卡），但條件更寬：
/// 範圍是**整塊板**（可跨週期、階段），不是只有本房掛接的板。排除自己、已刪除、
/// 已取消與已搬走的卡——後兩者不會再擋任何事，選了只是噪音。
List<CardCandidate> dependencyCandidates(BoardSnapshot snap,
    {String? excludeId}) {
  return [
    for (final t in snap.tasks.values)
      if (t.id != excludeId &&
          !t.deleted &&
          t.status != 'cancelled' &&
          t.status != 'moved')
        CardCandidate(
          boardId: snap.boardId,
          taskId: t.id,
          title: t.title,
          status: t.status,
        ),
  ];
}

/// 卡所在的階段名稱（id → 階段標題），選擇器用來在同名卡之間分辨。
Map<String, String> dependencyPlaces(BoardSnapshot snap) => {
      for (final t in snap.tasks.values)
        t.id: snap.checklists[t.checklistId]?.title ?? '',
    };

/// 編輯／建立卡片時，依賴與影響兩欄需要的資料。
@immutable
class DependencyEditSpec {
  const DependencyEditSpec({
    required this.candidates,
    this.titles = const {},
    this.places = const {},
    this.dependsOn = const [],
    this.affects = const [],
  });

  /// 可以選的卡（已排除自己）。
  final List<CardCandidate> candidates;

  /// id → 標題，涵蓋已選但不在 [candidates] 裡的卡（例如已取消）。
  final Map<String, String> titles;

  /// id → 階段名稱。
  final Map<String, String> places;

  /// 目前已設定的依賴／影響（task id）。
  final List<String> dependsOn;
  final List<String> affects;

  /// 從一塊板的快照組出來。[task] 為 null 代表正在建立新卡。
  factory DependencyEditSpec.fromSnapshot(BoardSnapshot snap,
      {BoardTask? task}) {
    final titles = {
      for (final t in snap.tasks.values) t.id: t.title,
      if (task != null) ...{
        for (final d in task.dependsOn) d.id: d.title,
        for (final a in task.affects) a.id: a.title,
      },
    };
    return DependencyEditSpec(
      candidates: dependencyCandidates(snap, excludeId: task?.id),
      titles: titles,
      places: dependencyPlaces(snap),
      dependsOn: [
        for (final d in task?.dependsOn ?? const <TaskDependency>[]) d.id
      ],
      affects: [for (final a in task?.affects ?? const <TaskAffect>[]) a.id],
    );
  }
}

/// 兩個 id 清單是不是同一組（不看順序）。
bool sameIdSet(List<String> a, List<String> b) =>
    a.length == b.length && a.toSet().containsAll(b) && b.toSet().containsAll(a);

/// 依賴／影響欄：已選的卡用小標籤排開，旁邊一顆「加入」開選擇器。
class DependencyField extends StatelessWidget {
  const DependencyField({
    super.key,
    required this.label,
    required this.selected,
    required this.spec,
    required this.excluded,
    required this.onChanged,
  });

  final String label;
  final List<String> selected;
  final DependencyEditSpec spec;

  /// 另一欄已選的卡：同一張卡不能同時是依賴也是影響（會形成循環），
  /// 所以選擇器不列出來。
  final List<String> excluded;
  final ValueChanged<List<String>> onChanged;

  String _titleOf(String id) {
    final t = spec.titles[id];
    return (t == null || t.isEmpty)
        ? L10n.current.commonUnknownParenthesised
        : t;
  }

  Future<void> _add(BuildContext context) async {
    final picked = await showCardPickerDialog(
      context,
      candidates: [
        for (final c in spec.candidates)
          if (!excluded.contains(c.taskId)) c,
      ],
      places: spec.places,
      selected: selected,
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(label, style: UepText.fieldLabel(color: s.inkSoft)),
        const Spacer(),
        InkWell(
          key: ValueKey('dep-add-$label'),
          onTap: () => _add(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Text(l10n.commonAdd,
                style: UepText.mono(
                    size: 10.5, color: UepColors.gold, letterSpacing: 1.2)),
          ),
        ),
      ]),
      const SizedBox(height: 6),
      if (selected.isEmpty)
        Text(l10n.boardDependencyNone,
            style: UepText.sans(size: 13, color: s.inkMute))
      else
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final id in selected)
            InputChip(
              key: ValueKey('dep-chip-$id'),
              label: Text(_titleOf(id),
                  overflow: TextOverflow.ellipsis,
                  style: UepText.sans(size: 12.5, color: s.ink)),
              visualDensity: VisualDensity.compact,
              onDeleted: () =>
                  onChanged([for (final x in selected) if (x != id) x]),
            ),
        ]),
    ]);
  }
}

/// 多選卡片的對話框。回傳選好的 task id 清單；取消回 null。
Future<List<String>?> showCardPickerDialog(
  BuildContext context, {
  required List<CardCandidate> candidates,
  required List<String> selected,
  Map<String, String> places = const {},
}) =>
    showDialog<List<String>>(
      context: context,
      builder: (_) => _CardPickerDialog(
          candidates: candidates, selected: selected, places: places),
    );

class _CardPickerDialog extends StatefulWidget {
  const _CardPickerDialog(
      {required this.candidates, required this.selected, required this.places});

  final List<CardCandidate> candidates;
  final List<String> selected;
  final Map<String, String> places;

  @override
  State<_CardPickerDialog> createState() => _CardPickerDialogState();
}

class _CardPickerDialogState extends State<_CardPickerDialog> {
  late final Set<String> _picked = {...widget.selected};
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final q = _query.trim().toLowerCase();
    final shown = [
      for (final c in widget.candidates)
        if (q.isEmpty || c.title.toLowerCase().contains(q)) c,
    ];
    return AlertDialog(
      backgroundColor: s.bgCard,
      title: Text(l10n.boardDependencyPickTitle,
          style: UepText.sectionTitle(color: s.inkTitle)),
      content: SizedBox(
        width: 460,
        height: 380,
        child: Column(children: [
          TextField(
            autofocus: true,
            onChanged: (v) => setState(() => _query = v),
            style: UepText.sans(size: 14, color: s.ink),
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              hintText: l10n.boardDependencyPickSearch,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: shown.isEmpty
                ? Center(
                    child: Text(l10n.boardDependencyPickEmpty,
                        style: UepText.sans(size: 13, color: s.inkMute)))
                : ListView(children: [
                    for (final c in shown)
                      CheckboxListTile(
                        key: ValueKey('pick-${c.taskId}'),
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _picked.contains(c.taskId),
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            _picked.add(c.taskId);
                          } else {
                            _picked.remove(c.taskId);
                          }
                        }),
                        title: Text(c.title,
                            overflow: TextOverflow.ellipsis,
                            style: UepText.sans(size: 13.5, color: s.ink)),
                        subtitle: (widget.places[c.taskId] ?? '').isEmpty
                            ? null
                            : Text(widget.places[c.taskId]!,
                                overflow: TextOverflow.ellipsis,
                                style:
                                    UepText.mono(size: 10, color: s.inkMute)),
                      ),
                  ]),
          ),
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
          label: l10n.boardDependencyPickDone,
          small: true,
          // 保留原有順序，新選的接在後面
          onPressed: () => Navigator.of(context).pop([
            for (final id in widget.selected)
              if (_picked.contains(id)) id,
            for (final id in _picked)
              if (!widget.selected.contains(id)) id,
          ]),
        ),
      ],
    );
  }
}
