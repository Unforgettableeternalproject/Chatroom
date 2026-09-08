import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/api_exception.dart';
import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../models/board.dart';
import '../../state/board_providers.dart';
import '../../widgets/uep_button.dart';

/// 把一張卡**搬到別的週期**（09/08 卡 240838ab）。
///
/// ## 為什麼是「建一張新卡」而不是「挑一張既有卡」
///
/// Hub 的 `moved_to` 存的是**目標卡 id**，不是週期 id——所以「選一個週期」
/// 這個動作本身生不出去向。裁定（決策Novia 09/08）走的是：選週期＋清單，
/// **在那裡建一張沿用標題／描述／優先度的新卡**，再把舊卡指向它。
///
/// 另一條路（只讓人挑一張既有卡）被否掉的理由是它逼使用者先手動建卡再回來
/// 搬，而「先收舊卡、新週期開起來才建新卡」正是這個功能要省掉的那段手工。
///
/// ⚠️ **去向留白是有代價的**：一張 `moved` 卡會離開它原本那份清單，去向空著
/// 就等於它從畫面上消失且追不回來。這個對話框的存在就是為了讓那一欄永遠有
/// 值——所以沒有「先搬了再說」的按鈕。
Future<String?> showBoardMoveDialog(
  BuildContext context, {
  required BoardTask task,
  required String boardId,
  String? roomId,
}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _MoveDialog(task: task, boardId: boardId, roomId: roomId),
    );

class _MoveDialog extends ConsumerStatefulWidget {
  const _MoveDialog({required this.task, required this.boardId, this.roomId});

  final BoardTask task;
  final String boardId;
  final String? roomId;

  @override
  ConsumerState<_MoveDialog> createState() => _MoveDialogState();
}

class _MoveDialogState extends ConsumerState<_MoveDialog> {
  String? _objectiveId;
  String? _checklistId;
  bool _busy = false;
  String? _error;

  /// 搬得進去的週期：**還在跑的**。
  ///
  /// `done` / `verified` 的週期收掉了，把活的工作丟進去等於讓一個已經結案的
  /// 東西重新長出待辦；`cancelled` 由 [BoardSnapshot.sortedObjectives] 擋掉。
  List<BoardObjective> _targets(BoardSnapshot snap) => snap.sortedObjectives
      .where((o) => o.status == 'active' || o.status == 'review')
      .toList();

  /// 目標清單：那個週期底下**還開著**的，而且不是這張卡現在待的那一份。
  /// 搬到自己原地不是一個搬法，留著只會讓人按下去才發現什麼都沒發生。
  List<BoardChecklist> _lists(BoardSnapshot snap, String objectiveId) => snap
      .checklistsOf(objectiveId)
      .where((c) => c.status == 'open' && c.id != widget.task.checklistId)
      .toList();

  Future<void> _submit(BoardActions actions) async {
    final target = _checklistId;
    if (target == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final newId = await actions.moveTask(
        widget.task.id,
        targetChecklistId: target,
        title: widget.task.title,
        description: widget.task.description,
        priority: widget.task.priority,
      );
      if (!mounted) return;
      if (newId == null) {
        setState(() => _error = '沒有可用的身分，這個動作送不出去。');
        return;
      }
      Navigator.of(context).pop(newId);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final snap = widget.roomId != null
        ? ref.watch(boardProvider(widget.roomId!)).value
        : ref.watch(boardByIdProvider(widget.boardId)).value;
    final actions = widget.roomId != null
        ? ref.read(boardActionsProvider(widget.roomId!))
        : ref.read(boardActionsByIdProvider(widget.boardId));

    final objectives = snap == null ? <BoardObjective>[] : _targets(snap);
    final lists = (snap == null || _objectiveId == null)
        ? <BoardChecklist>[]
        : _lists(snap, _objectiveId!);

    return AlertDialog(
      backgroundColor: s.bgCard,
      title: Text('搬到別處', style: UepText.display(size: 18, color: s.inkTitle)),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '「${widget.task.title}」會在你選的地方長出一張新卡（標題、描述、'
              '優先度都跟著走），這張則標成「已搬走」並指向那一張。'
              '\n\n搬錯了可以按「收回這裡」拿回來。',
              style: UepText.serif(size: 12, color: s.inkMute, height: 1.55),
            ),
          ),
          const SizedBox(height: 14),
          if (snap == null)
            Align(
              alignment: Alignment.centerLeft,
              child: Text('還在讀這塊板…',
                  style: UepText.sans(size: 12, color: s.inkMute)),
            )
          else if (objectives.isEmpty)
            // 停用要說得出理由，而且理由要導向下一步
            Align(
              alignment: Alignment.centerLeft,
              child: Text('這塊板上沒有還在跑的週期，先開一個才有地方搬。',
                  style: UepText.sans(size: 12, color: s.inkMute)),
            )
          else ...[
            DropdownButtonFormField<String>(
              initialValue: _objectiveId,
              isExpanded: true,
              hint: Text('搬到哪個週期…',
                  overflow: TextOverflow.ellipsis,
                  style: UepText.sans(size: 12, color: s.inkMute)),
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                labelText: '週期',
              ),
              style: UepText.sans(size: 12, color: s.ink),
              // 換週期時把清單清掉——留著上一個週期的選擇，送出的會是一個
              // 與畫面上那行字無關的目標
              onChanged: (v) => setState(() {
                _objectiveId = v;
                _checklistId = null;
              }),
              items: [
                for (final o in objectives)
                  DropdownMenuItem(
                    value: o.id,
                    child: Text(o.title,
                        overflow: TextOverflow.ellipsis,
                        style: UepText.sans(size: 12, color: s.ink)),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _checklistId,
              isExpanded: true,
              hint: Text(_objectiveId == null ? '先選週期' : '搬到哪份清單…',
                  overflow: TextOverflow.ellipsis,
                  style: UepText.sans(size: 12, color: s.inkMute)),
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                labelText: '清單',
              ),
              style: UepText.sans(size: 12, color: s.ink),
              onChanged:
                  lists.isEmpty ? null : (v) => setState(() => _checklistId = v),
              items: [
                for (final c in lists)
                  DropdownMenuItem(
                    value: c.id,
                    child: Text(c.title,
                        overflow: TextOverflow.ellipsis,
                        style: UepText.sans(size: 12, color: s.ink)),
                  ),
              ],
            ),
            // 選了週期卻沒有清單可挑，與「還沒選週期」在畫面上長得一樣，
            // 但處置完全不同：一個是你還沒動，一個是那裡沒地方放
            if (_objectiveId != null && lists.isEmpty) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('這個週期底下沒有別的開著的清單可以放。',
                    style: UepText.sans(size: 11.5, color: s.inkMute)),
              ),
            ],
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(_error!,
                  style: UepText.sans(
                      size: 12, color: UepColors.error, height: 1.45)),
            ),
          ],
        ]),
      ),
      actions: [
        UepButton(
          label: '取消',
          variant: UepButtonVariant.outline,
          small: true,
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
        ),
        UepButton(
          label: '搬過去',
          small: true,
          onPressed:
              (_busy || _checklistId == null) ? null : () => _submit(actions),
        ),
      ],
    );
  }
}
