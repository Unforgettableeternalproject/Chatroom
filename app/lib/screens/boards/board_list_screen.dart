import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../models/board.dart';
import '../../state/board_providers.dart';
import '../../widgets/empty_error_states.dart';
import '../../widgets/kind_badge.dart';

/// Board Library：左欄 BOARDS 分頁的內容。
///
/// 與 ROOMS 分頁**刻意不共用同一個清單元件**。兩者長得像，但回答的問題不同：
/// 房間清單問「現在有哪些對話」，Board 清單問「有哪些工作還沒收尾」——
/// 所以這裡排序看的是最後更新，卡片上放的是進度而不是成員數。
class BoardListPane extends ConsumerStatefulWidget {
  const BoardListPane({super.key, this.selectedBoardId});

  final String? selectedBoardId;

  @override
  ConsumerState<BoardListPane> createState() => _BoardListPaneState();
}

class _BoardListPaneState extends ConsumerState<BoardListPane> {
  String _status = 'active';

  Future<void> _refresh() async {
    ref.invalidate(boardLibraryProvider);
    await ref.read(boardLibraryProvider(_status).future);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final boardsAsync = ref.watch(boardLibraryProvider(_status));

    return Container(
      color: s.bgSoft,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(children: [
            Row(children: [
              const MonoLabel('BOARDS', letterSpacing: 2.0),
              const Spacer(),
              IconButton(
                tooltip: '重新整理',
                visualDensity: VisualDensity.compact,
                onPressed: _refresh,
                icon: Icon(Icons.refresh, size: 15, color: s.inkMute),
              ),
            ]),
            const SizedBox(height: 8),
            _BoardStatusToggle(
              status: _status,
              onChanged: (v) => setState(() => _status = v),
            ),
          ]),
        ),
        Expanded(
          child: RefreshIndicator(
            color: UepColors.gold,
            onRefresh: _refresh,
            child: boardsAsync.when(
              loading: () => const Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: UepColors.gold),
                ),
              ),
              // 端點還沒上線與「真的壞了」要分開講。兩者都會走到這裡，
              // 但一個該等、一個該修，而錯誤畫面若都寫「載入失敗」，
              // 看的人只能去猜。
              error: (e, _) => boardLibraryUnavailable(e)
                  ? const _LibraryNotReady()
                  : ErrorState(error: e, onRetry: _refresh),
              data: (boards) {
                if (boards.isEmpty) {
                  return ListView(children: [
                    const SizedBox(height: 120),
                    EmptyState(
                      title: _status == 'active'
                          ? '目前沒有進行中的任務板'
                          : '沒有已封存的任務板',
                      subtitle: _status == 'active'
                          ? '在聊天室裡建立一塊板，\n它就會留在這裡——'
                              '房間封存了也不會跟著消失'
                          : null,
                    ),
                  ]);
                }
                return ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: boards.length,
                  itemBuilder: (_, i) => _BoardTile(
                    board: boards[i],
                    selected: boards[i].id == widget.selectedBoardId,
                    onTap: () => context.go('/boards/${boards[i].id}'),
                  ),
                );
              },
            ),
          ),
        ),
      ]),
    );
  }
}

/// Hub 還沒有 `/api/boards`。
///
/// 這一格存在的唯一理由：**空清單與「端點不存在」在畫面上長得一模一樣**。
/// 沒有這句話的話，遷移期間打開 BOARDS 分頁的人會以為自己一塊板都沒有，
/// 然後去建一塊——而建立同樣會失敗。
class _LibraryNotReady extends StatelessWidget {
  const _LibraryNotReady();

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MonoLabel('NOT READY', color: s.inkMute.withValues(alpha: .6)),
            const SizedBox(height: 10),
            Text(
              '這個 Hub 還沒有 Board Library',
              textAlign: TextAlign.center,
              style: UepText.serif(size: 13, color: s.inkSoft),
            ),
            const SizedBox(height: 6),
            Text(
              '不是沒有任務板，是伺服器還沒開這個端點。\n升級 Hub 之後就會出現。',
              textAlign: TextAlign.center,
              style: UepText.sans(size: 11.5, color: s.inkMute),
            ),
          ],
        ),
      ),
    );
  }
}

class _BoardStatusToggle extends StatelessWidget {
  const _BoardStatusToggle({required this.status, required this.onChanged});

  final String status;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    Widget segment(String value, String label) {
      final active = status == value;
      return Expanded(
        child: InkWell(
          onTap: () => onChanged(value),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 5),
            color: active ? UepColors.gold : Colors.transparent,
            alignment: Alignment.center,
            child: Text(
              label,
              style: UepText.mono(
                size: 9,
                letterSpacing: 1.2,
                color: active ? UepColors.goldInkOn : s.inkMute,
                weight: active ? FontWeight.w500 : FontWeight.w400,
              ),
            ),
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: s.line),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(children: [
          segment('active', '進行中'),
          segment('archived', '已封存'),
        ]),
      ),
    );
  }
}

class _BoardTile extends StatelessWidget {
  const _BoardTile({
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
        padding: const EdgeInsets.fromLTRB(16, 11, 16, 11),
        decoration: BoxDecoration(
          color: selected ? s.bgSunken : Colors.transparent,
          border: Border(
            bottom: BorderSide(color: s.line),
            left: BorderSide(
              color: selected ? UepColors.gold : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(
                  board.name.isEmpty ? '（未命名）' : board.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: UepText.serif(
                    size: 13.5,
                    // 封存的板去飽和，與封存的房同一套語彙
                    color: board.isArchived ? s.inkMute : s.ink,
                  ),
                ),
              ),
              if (board.isArchived) ...[
                const SizedBox(width: 6),
                const MonoLabel('封存', size: 8.5, letterSpacing: 1.0),
              ],
            ]),
            const SizedBox(height: 5),
            Row(children: [
              // 掛了幾間房——這是 v2 才有的資訊，也是 Board 與 room 分家
              // 之後唯一看得出「這塊板被多少對話共用」的地方
              _Meta(
                glyph: '◫',
                text: '${board.attachedRoomCount} 房',
                color: s.inkMute,
              ),
              const SizedBox(width: 10),
              _Meta(
                glyph: '✓',
                text: '${board.taskDone}/${board.taskTotal}',
                color: s.inkMute,
              ),
              if (board.taskClaimed > 0) ...[
                const SizedBox(width: 10),
                // 有人在上面做事——這是唯一會上色的一項，因為它是唯一
                // 隨時可能變的
                _Meta(
                  glyph: '●',
                  text: '${board.taskClaimed} 進行中',
                  color: UepColors.gold,
                ),
              ],
            ]),
          ],
        ),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.glyph, required this.text, required this.color});

  final String glyph;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(glyph, style: TextStyle(fontSize: 9, color: color)),
          const SizedBox(width: 3),
          Text(text, style: UepText.mono(size: 9.5, color: color)),
        ],
      );
}
