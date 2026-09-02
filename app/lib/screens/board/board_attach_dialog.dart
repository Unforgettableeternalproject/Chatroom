import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../models/board.dart';
import '../../state/board_providers.dart';
import '../../widgets/empty_error_states.dart';
import '../../widgets/kind_badge.dart';
import '../../widgets/uep_button.dart';

/// 這間房要掛哪塊板：建一塊新的，或掛一塊已經存在的。
///
/// v2 的核心差別就在這個對話框裡——**板不再跟著房間長出來**。建房不自動
/// 生一塊空板（`BOARD_DESIGN` §1.2），要不要有板、要不要跟別的對話共用同
/// 一塊，是進來之後才決定的事。
///
/// 「掛既有的」是一對多那條路的唯一入口：需求討論房與實作房掛同一塊板，
/// 兩邊看到的是同一份進度，而不是兩份各走各的。
Future<BoardAttachResult?> showBoardAttachDialog(
  BuildContext context, {
  required String roomName,
}) =>
    showDialog<BoardAttachResult>(
      context: context,
      builder: (_) => _BoardAttachDialog(roomName: roomName),
    );

/// 使用者選了什麼。二選一：建新的（帶名字），或掛既有的（帶 id）。
class BoardAttachResult {
  const BoardAttachResult.create(this.name, {this.importMembers = false})
      : boardId = null;
  const BoardAttachResult.attach(this.boardId, {this.importMembers = false})
      : name = null;

  final String? name;
  final String? boardId;

  /// 把這間房**當下的**成員一併加為板的 editor。
  final bool importMembers;

  bool get isCreate => name != null;
}

class _BoardAttachDialog extends ConsumerStatefulWidget {
  const _BoardAttachDialog({required this.roomName});

  final String roomName;

  @override
  ConsumerState<_BoardAttachDialog> createState() => _BoardAttachDialogState();
}

class _BoardAttachDialogState extends ConsumerState<_BoardAttachDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.roomName);

  /// 預設停在「建新的」。**多數情況確實是新的**——共用一塊板是刻意的安排，
  /// 而刻意的安排值得多按一下；把它設成預設反而會讓人不小心掛錯板。
  bool _existing = false;

  String? _picked;

  /// 預設不勾。**不是因為危險**（Hub 不覆寫既有角色），是因為授權應該是
  /// 一個看得見的動作——預設把寫入權發給一整間房的人，沒有人會記得
  /// 自己做過這個決定。
  bool _importMembers = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return AlertDialog(
      backgroundColor: s.bgCard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: BorderSide(color: s.lineStrong),
      ),
      title: Text('這間房要掛哪塊任務板',
          style: UepText.display(size: 20, color: s.inkTitle)),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(
              child: _Choice(
                label: '建一塊新的',
                active: !_existing,
                onTap: () => setState(() => _existing = false),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _Choice(
                label: '掛既有的板',
                active: _existing,
                onTap: () => setState(() => _existing = true),
              ),
            ),
          ]),
          const SizedBox(height: 14),
          if (!_existing)
            TextField(
              controller: _name,
              autofocus: true,
              style: UepText.sans(size: 13, color: s.ink),
              decoration: InputDecoration(
                labelText: '板的名字',
                labelStyle: UepText.mono(size: 10, color: s.inkMute),
                helperText: '這塊板會活得比這間房久——封存房間不會封存它',
                helperStyle: UepText.serif(size: 11, color: s.inkMute),
                border: const OutlineInputBorder(),
              ),
            )
          else
            SizedBox(height: 260, child: _ExistingList(
              picked: _picked,
              onPick: (id) => setState(() => _picked = id),
            )),
          const SizedBox(height: 10),
          CheckboxListTile(
            value: _importMembers,
            onChanged: (v) => setState(() => _importMembers = v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text('把這間房現在的成員加為板的協作者',
                style: UepText.sans(size: 12.5, color: s.ink)),
            subtitle: Text(
                '只加現在在房裡的人。之後才進來的不會自動拿到權限——'
                '那要由板的 owner 另外決定',
                style: UepText.serif(
                    size: 11.5, color: s.inkMute, height: 1.4)),
          ),
        ]),
      ),
      actions: [
        UepButton(
          label: '取消',
          variant: UepButtonVariant.outline,
          small: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
        UepButton(
          label: _existing ? '掛上去' : '建立並掛上',
          small: true,
          // 沒選、沒填就不給按。灰掉的按鈕會讓人回頭看自己漏了什麼，
          // 按下去彈一句錯誤只是把同一件事講得比較晚
          onPressed: _existing
              ? (_picked == null
                  ? null
                  : () => Navigator.of(context).pop(
                      BoardAttachResult.attach(_picked!,
                          importMembers: _importMembers)))
              : (_name.text.trim().isEmpty
                  ? null
                  : () => Navigator.of(context).pop(
                      BoardAttachResult.create(_name.text.trim(),
                          importMembers: _importMembers))),
        ),
      ],
    );
  }
}

class _ExistingList extends ConsumerWidget {
  const _ExistingList({required this.picked, required this.onPick});

  final String? picked;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final async = ref.watch(boardLibraryProvider('active'));
    return async.when(
      loading: () => const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      error: (e, _) => boardLibraryUnavailable(e)
          ? Center(
              child: Text(
                '這個 Hub 還沒有 Board Library，\n只能建新的板。',
                textAlign: TextAlign.center,
                style: UepText.serif(size: 12, color: s.inkMute),
              ),
            )
          : ErrorState(
              error: e,
              onRetry: () => ref.invalidate(boardLibraryProvider),
            ),
      data: (boards) {
        // 只有 owner／editor 掛得上去。列出 viewer 的板再讓他撞 403，
        // 等於把一個必然失敗的選項擺在那裡
        final usable = boards.where((b) => b.canEdit).toList();
        if (usable.isEmpty) {
          return Center(
            child: Text(
              '沒有你能掛的板。\n（只有板的 owner 或 editor 掛得上去）',
              textAlign: TextAlign.center,
              style: UepText.serif(size: 12, color: s.inkMute),
            ),
          );
        }
        return ListView.builder(
          itemCount: usable.length,
          itemBuilder: (_, i) => _BoardRow(
            board: usable[i],
            selected: usable[i].id == picked,
            onTap: () => onPick(usable[i].id),
          ),
        );
      },
    );
  }
}

class _BoardRow extends StatelessWidget {
  const _BoardRow({
    required this.board,
    required this.selected,
    required this.onTap,
  });

  final BoardSummary board;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? s.bgSunken : Colors.transparent,
          border: Border(
            bottom: BorderSide(color: s.hairline),
            left: BorderSide(
              color: selected ? UepColors.gold : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(children: [
          Expanded(
            child: Text(
              board.name.isEmpty ? '（未命名）' : board.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: UepText.sans(size: 12.5, color: s.ink),
            ),
          ),
          // 已經掛了幾間房——**這是掛既有板時唯一要判斷的事**：
          // 它是不是已經在別的對話裡用著
          MonoLabel('${board.attachedRoomCount} 房',
              size: 9, letterSpacing: 1.0),
          const SizedBox(width: 8),
          MonoLabel('${board.taskDone}/${board.taskTotal}',
              size: 9, letterSpacing: 1.0),
        ]),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? UepColors.gold : Colors.transparent,
          border: Border.all(color: active ? UepColors.gold : s.line),
        ),
        child: Text(
          label,
          style: UepText.mono(
            size: 10,
            letterSpacing: 1.2,
            color: active ? UepColors.goldInkOn : s.inkSoft,
          ),
        ),
      ),
    );
  }
}
