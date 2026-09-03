import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../core/errors/api_exception.dart';
import '../../models/board.dart';
import '../../state/app_providers.dart';
import '../../state/board_providers.dart';
import '../../state/scratchpad_providers.dart';
import '../../widgets/empty_error_states.dart';
import '../../widgets/kind_badge.dart';
import '../../widgets/uep_button.dart';

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

  /// 在 Library 直接開一塊板：**不掛任何房間**。
  ///
  /// 「先建板、之後再決定掛去哪」是 v2 的正常路徑（`origin_room_id` 選填），
  /// 而剛建好的零掛接板不是邊界案例，是這條路徑的起點。
  Future<void> _createBoard() async {
    final made = await showDialog<({String name, String visibility})>(
      context: context,
      builder: (_) => const _NewBoardDialog(),
    );
    if (made == null || made.name.isEmpty) return;
    try {
      final id = await ref.read(boardsApiProvider).create(
            name: made.name,
            sessionKey: ref.read(appConfigProvider).deviceKey,
            visibility: made.visibility,
          );
      ref.invalidate(boardLibraryProvider);
      if (!mounted || id.isEmpty) return;
      // 建完直接進去——下一個動作幾乎一定是往裡面放東西
      context.go('/boards/$id');
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
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
              // 追蹤收件匣的入口。**紅點在這裡是必要的**，不是裝飾：
              // 裁決 #392 ②A 是「離線通知留著，回來就知道」，而知道的
              // 管道只有這一個——沒有它，通知留著了，但沒有任何地方會
              // 告訴他有東西留著，②A 在使用上就等於「不通知」
              const _NoticesButton(),
              // 開一塊新的板。**這個入口從前不存在**——板只能靠「在房裡寫
              // 第一張卡」長出來（lazy 建立），於是 BOARDS 分頁只看得到板、
              // 開不了板，而「先開一塊板再決定掛去哪」根本走不通
              // （艾斯維爾 2026-09-03：「等同於沒有創立板子的途徑」）。
              // server 這邊一直是支援的，缺的只有這顆按鈕
              IconButton(
                tooltip: '開一塊板',
                visualDensity: VisualDensity.compact,
                onPressed: _createBoard,
                icon: Icon(Icons.add, size: 17, color: s.inkMute),
              ),
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
                      // 舊文案寫「在聊天室裡建立一塊板」——那在有了上面
                      // 那顆＋之後就是**錯的指引**：它把人送回一條更長的路
                      subtitle: _status == 'active'
                          ? '用上面的＋開一塊，或在聊天室裡寫第一張卡。\n'
                              '板不屬於任何一間房——房間封存了也不會跟著消失'
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
              // 私人板要看得出來。**這是「別人看不看得到」的唯一線索**——
              // 它決定的是掛得進哪種聊天室、以及房裡的人會不會在自己的
              // 分頁上看到它，而那兩件事都不會在畫面別處出現
              if (board.isPrivate) ...[
                const SizedBox(width: 6),
                const MonoLabel('私人', size: 8.5, letterSpacing: 1.0),
              ],
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
              // ⚠️ **「掛 1 房」與「掛 1 房但沒有一間活著」在畫面上不能長得
              // 一樣。** 後者表示追蹤者不會再被叫醒，只能自己回來看，而那是
              // 一個會持續下去的狀態（裁決 #431），不是一個閃過去的提示。
              // 封存最後一間活房正是製造這個狀態的路徑
              if (board.inboxOnly) ...[
                const SizedBox(width: 10),
                _Meta(
                  glyph: '⚑',
                  text: '通知要自己來看',
                  color: UepColors.gold,
                ),
              ],
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

/// 「我在等的東西」入口，帶未讀數。
class _NoticesButton extends ConsumerWidget {
  const _NoticesButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final unread = ref.watch(watchNoticesProvider).maybeWhen(
          data: (d) => d.unread,
          orElse: () => 0,
        );
    return IconButton(
      tooltip: unread == 0 ? '我在等的東西' : '我在等的東西（$unread 筆新的）',
      visualDensity: VisualDensity.compact,
      onPressed: () => context.go('/notices'),
      icon: Stack(clipBehavior: Clip.none, children: [
        Icon(Icons.notifications_none,
            size: 15, color: unread == 0 ? s.inkMute : UepColors.gold),
        if (unread > 0)
          Positioned(
            right: -3,
            top: -3,
            child: Container(
              width: 7,
              height: 7,
              decoration: const BoxDecoration(
                  color: UepColors.gold, shape: BoxShape.circle),
            ),
          ),
      ]),
    );
  }
}

/// 開一塊板時只問名字。
///
/// **刻意不在這裡問「要掛哪間房」**：板不屬於任何一間房，而剛開的板通常
/// 還不知道要給誰用——掛接是之後在板上做的決定，塞進建立流程只會讓「我
/// 現在還不確定」變成一個必填欄位。
class _NewBoardDialog extends StatefulWidget {
  const _NewBoardDialog();

  @override
  State<_NewBoardDialog> createState() => _NewBoardDialogState();
}

class _NewBoardDialogState extends State<_NewBoardDialog> {
  final _name = TextEditingController();

  /// **預設公開。** 私人板只掛得進自己開的私人聊天室，是一條窄路——
  /// 預設走窄路的話，多數人會在掛接的時候才撞到那道閘，而那時他已經
  /// 忘記自己選過什麼。
  String _visibility = 'public';

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _name.text.trim();
    if (v.isEmpty) return;
    Navigator.of(context).pop((name: v, visibility: _visibility));
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
      title: Text('開一塊板',
          style: UepText.display(size: 19, color: s.inkTitle)),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _name,
            autofocus: true,
            // 打完直接 Enter 送出——名稱是唯一的必填欄位
            onSubmitted: (_) => _submit(),
            // 空字串時「建立」要是灰的，不重畫的話它永遠亮著
            onChanged: (_) => setState(() {}),
            style: UepText.sans(size: 13, color: s.ink),
            decoration: const InputDecoration(
              labelText: '名稱',
              helperText: '之後可以把聊天室掛上來，一塊板可以掛好幾間',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 18),
          Align(
            alignment: Alignment.centerLeft,
            child: MonoLabel('誰看得到', color: s.inkSoft, letterSpacing: 1.4),
          ),
          const SizedBox(height: 6),
          // 兩個選項各自把**結果**講完，而不是只給「公開／私人」兩個詞——
          // 這裡選錯要到掛接聊天室的時候才會撞到閘，那時人已經忘了自己選過
          _VisibilityOption(
            label: '公開',
            detail: '掛著它的聊天室裡的人，都會在 BOARDS 分頁看到這塊板',
            selected: _visibility == 'public',
            onTap: () => setState(() => _visibility = 'public'),
          ),
          _VisibilityOption(
            label: '私人',
            detail: '只有你看得到；**只能掛進你自己開的私人聊天室**，'
                '房裡的人從聊天室進得來，但它不會出現在他們的分頁上',
            selected: _visibility == 'private',
            onTap: () => setState(() => _visibility = 'private'),
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
          label: '建立',
          small: true,
          onPressed: _name.text.trim().isEmpty ? null : _submit,
        ),
      ],
    );
  }
}

/// 建板時的公開／私人選項。**兩行**：一行是名字，一行是它的實際後果。
class _VisibilityOption extends StatelessWidget {
  const _VisibilityOption({
    required this.label,
    required this.detail,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
        decoration: BoxDecoration(
          border: Border.all(color: selected ? UepColors.gold : s.line),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(selected ? '◉' : '○',
              style: UepText.mono(
                  size: 11, color: selected ? UepColors.gold : s.inkMute)),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: UepText.sans(
                        size: 12.5,
                        color: selected ? s.inkTitle : s.inkSoft)),
                const SizedBox(height: 2),
                Text(detail.replaceAll('**', ''),
                    style: UepText.serif(
                        size: 11, color: s.inkMute, height: 1.4)),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}
