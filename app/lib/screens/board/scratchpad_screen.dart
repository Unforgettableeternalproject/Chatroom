import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/api_exception.dart';
import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../models/board.dart' show reorderedIdsAt;
import '../../models/scratchpad.dart';
import '../../state/app_providers.dart';
import '../../state/board_providers.dart';
import '../../state/scratchpad_providers.dart';
import '../../widgets/empty_error_states.dart';
import '../../widgets/kind_badge.dart';
import '../../widgets/uep_button.dart';

/// 想法板：**先把腦裡的東西倒進去**，之後再整理成卡。
///
/// ## 為什麼是一段一段，不是一個大輸入框
///
/// 「agent 不得改寫人類的段落，只能註解」（艾斯維爾 2026-09-02）要成立，
/// 作者身分就得落在段落層級。而一旦如此，**整份自由文字編輯就不能做**：
/// 人在自由文字裡會併段、拆段、調換、刪行，存回去時段落與 id 的對應
/// 已經不存在，只能重新推斷——猜錯就是把某段的作者從人類換成 agent，
/// **那正好解除它的保護**，而且沒有任何一端會報錯。
///
/// 所以這裡沒有「編輯整份」那顆按鈕，是刻意的。
class ScratchpadScreen extends ConsumerWidget {
  const ScratchpadScreen({
    super.key,
    required this.boardId,
    required this.padId,
  });

  final String boardId;
  final String padId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = scratchpadKey(boardId, padId);
    final async = ref.watch(scratchpadProvider(key));
    return async.when(
      // 🔴 **重算時不要把整棵樹換成轉圈圈。**
      //
      // `skipLoadingOnRefresh` 預設就是 true（invalidate 會保留舊值），但
      // **`skipLoadingOnReload` 預設 false**——這份 provider 的**依賴**一動
      // （身分、deviceKey…）就是 reload，畫面會真的閃過 loading，底下所有
      // State 連同 controller 一起 dispose。
      //
      // 艾斯維爾看到的是「**寫到一半他會跳一下，然後字就被清空了**」
      // （2026-09-04）——那個「跳一下」就是這個 spinner，字是在那一瞬間
      // 沒的。上午把輸入框移出 `ListView` 修掉了另一半（被回收），
      // 這是同一個症狀的第二個成因。
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorState(
        error: e,
        onRetry: () => ref.invalidate(scratchpadProvider(key)),
      ),
      data: (pad) => _PadBody(pad: pad, boardId: boardId),
    );
  }
}

class _PadBody extends ConsumerStatefulWidget {
  const _PadBody({required this.pad, required this.boardId});

  final Scratchpad pad;
  final String boardId;

  @override
  ConsumerState<_PadBody> createState() => _PadBodyState();
}

class _PadBodyState extends ConsumerState<_PadBody> {
  /// 正在編輯哪一段。一次一段——同時開兩段的話，兩份 rev 都會過期，
  /// 而使用者不會知道是哪一段先壞的。
  String? _editing;

  String get _sessionKey => ref.read(appConfigProvider).deviceKey;
  String get _key => scratchpadKey(widget.boardId, widget.pad.id);

  /// 重拉這一份——**連外面那份清單一起**。
  ///
  /// 🔴 只 invalidate 這一份的話，板頁上的「N 段 · N 則未處理」會停在進來
  /// 之前的數字：加了三段、回去看還是舊的（艾斯維爾 2026-09-04）。
  /// 同一份資料在兩個 provider 裡各有一份快照，**改了一邊就得動另一邊**——
  /// 而不同步的那個看起來只是「數字有點怪」，不像壞掉，所以會一直留著。
  void _reload() {
    ref.invalidate(scratchpadProvider(_key));
    ref.invalidate(scratchpadListProvider(widget.boardId));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final pad = widget.pad;
    // 🔴 **輸入框在捲動區外面。**
    //
    // 它原本是清單的最後一項，而 `ListView` 會把捲出可視範圍的 children
    // **dispose**——段落一多，輸入框就落到畫面外，controller 跟著沒了，
    // 回到那裡是空的。艾斯維爾看到的是「輸入框一直清空」，猜「重複渲染」；
    // 實際上是**被當成用完了**（2026-09-04）。
    //
    // ⚠️ `AutomaticKeepAliveClientMixin` 在這條路徑上救不了：實測把
    // `wantKeepAlive` 寫死成 `true` 也一樣被回收。與其留一個看起來有守、
    // 其實沒有的保護，不如讓它根本不在可回收的地方。
    //
    // 副作用剛好是對的：想法板的用法是「隨時往裡丟」，那個框本來就不該
    // 要人先捲到最底下才找得到。
    return Column(children: [
      Expanded(child: _scroller(s, pad)),
      _footer(s, pad),
    ]);
  }

  Widget _scroller(UepSurface s, Scratchpad pad) => ListView(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
      children: [
        Row(children: [
          Expanded(
            child: Text(pad.title,
                style: UepText.display(size: 22, color: s.inkTitle)),
          ),
          MonoLabel('${pad.blocks.length} 段', size: 9, letterSpacing: 1.2),
        ]),
        const SizedBox(height: 4),
        Text(
          '把想到的先放進來，不必先想好順序。'
          'agent 讀得到，也能對每一段留意見——但改不動你寫的東西。',
          style: UepText.serif(size: 12, color: s.inkMute, height: 1.5),
        ),
        const SizedBox(height: 16),
        // 排得動時整段換成可拖曳的清單。**拖不動就不要留拖曳把手**——
        // 那比沒有把手更讓人以為壞了（同 board_screen 的 _canReorder）
        if (pad.canReorder)
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorderItem: (from, to) => _reorderBlocks(from, to),
            children: [
              for (var i = 0; i < pad.blocks.length; i++)
                ReorderableDragStartListener(
                  key: ValueKey('drag-${pad.blocks[i].id}'),
                  index: i,
                  child: _blockCard(pad, pad.blocks[i]),
                ),
            ],
          )
        else
          for (final b in pad.blocks) _blockCard(pad, b),
      ]);

  /// 常駐在底部的輸入區。唯讀時換成一句說明——**位置一樣**，人不會
  /// 覺得是不是哪裡沒載出來。
  Widget _footer(UepSurface s, Scratchpad pad) => Container(
        decoration: BoxDecoration(
          color: s.bg,
          border: Border(top: BorderSide(color: s.line)),
        ),
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
        child: pad.canEdit
            ? _AddBlock(onAdd: _add)
            : Text('你在這塊板上是唯讀的，只能看。',
                style: UepText.serif(size: 12, color: s.inkMute)),
      );

  Widget _blockCard(Scratchpad pad, ScratchpadBlock b) => _BlockCard(
        // ⚠️ **key by id。** 沒有 key 的話，reload 或重排之後 Flutter
        // 會按索引沿用同一顆 State，而那顆 State 裡的 controller 只在
        // initState 建一次——編輯框會裝著**前一段**的舊文字，存下去就
        // 覆蓋錯段落。這正是今天 composer 那個 bug 的同一種
        // （@審核用Codex-2 2026-09-03）
        key: ValueKey(b.id),
        block: b,
        editing: _editing == b.id,
        onEdit: pad.canEdit && b.canEdit
            ? () => setState(() => _editing = b.id)
            : null,
        onCancel: () => setState(() => _editing = null),
        onSave: (text) => _save(b, text),
        onNote: pad.canEdit ? (text) => _note(b, text) : null,
        // ⚠️ 守門用 **`b.canEdit`**，不是 `pad.canEdit`。Hub 那邊
        // resolve 的條件是「這一段的作者，或人類成員」——與 can_edit
        // 同一條（`app.py:6593`）。只看 pad 的話，agent 會在人類寫的
        // 段落上看到一顆「處理掉」，按下去必然 403。
        //
        // **不要自己重算那個條件**，直接用伺服器算好的：自己算的話
        // 兩邊的規則會漂移，而漂移的那一半沒有人在看
        // （@審核用Codex-2 2026-09-03）
        onResolveNote:
            canResolveNote(padCanEdit: pad.canEdit, blockCanEdit: b.canEdit)
                ? (id, undo) => _resolveNote(id, undo)
                : null,
        onDelete: pad.canEdit && b.canEdit ? () => _delete(b) : null,
      );

  /// 拖曳重排。**整批送**：Hub 依收到的順序寫 order_index，只送一部分的話
  /// 沒送的那些保留舊值 ⇒ 兩批號碼交錯，順序變成未定義。
  ///
  /// ⚠️ 帶的是**這份想法板的結構 rev**，不是某一段的。rev 對不上時 Hub
  /// 回 409：那表示有人在你拖的時候插了一段或搬了順序，重拉就好——
  /// 這裡不做樂觀更新，失敗時畫面不會停在一個只有本機看得到的排列上。
  Future<void> _reorderBlocks(int from, int to) async {
    final ids = [for (final b in widget.pad.blocks) b.id];
    try {
      await ref.read(scratchpadApiProvider).reorder(
            widget.boardId,
            widget.pad.id,
            sessionKey: _sessionKey,
            blockIds: reorderedIdsAt(ids, from, to),
            rev: widget.pad.rev,
          );
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
    _reload();
  }

  Future<void> _save(ScratchpadBlock b, String text) async {
    try {
      await ref.read(scratchpadApiProvider).writeBlock(
            widget.boardId,
            widget.pad.id,
            b.id,
            sessionKey: _sessionKey,
            content: text,
            rev: b.rev,
          );
      if (!mounted) return;
      setState(() => _editing = null);
      _reload();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == 'scratchpad_block_stale') {
        // ⚠️ **絕不自動用伺服器版蓋掉輸入框。** 那等於把 CAS 防住的資料
        // 遺失原封不動搬到 client 上——它守住了資料庫，然後我在畫面上
        // 把使用者剛打的那段刪掉，而他甚至看不到自己失去了什麼
        await _resolveConflict(b, mine: text, e: e);
        return;
      }
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  /// 衝突：兩份都攤出來讓人自己挑。
  Future<void> _resolveConflict(
    ScratchpadBlock b, {
    required String mine,
    required ApiException e,
  }) async {
    final theirs = (e.detail['content'] as String?) ?? '';
    final theirRev = (e.detail['rev'] as int?) ?? b.rev;
    final keepMine = await showDialog<bool>(
      context: context,
      builder: (ctx) => _ConflictDialog(mine: mine, theirs: theirs),
    );
    if (keepMine == null || !mounted) {
      // 關掉對話框＝什麼都不做。**輸入框裡那份還在**，他可以再想一下
      return;
    }
    if (!keepMine) {
      setState(() => _editing = null);
      _reload();
      return;
    }
    // 用對方的 rev 再送一次自己的內容——這是「我看過了，還是要蓋掉」
    try {
      await ref.read(scratchpadApiProvider).writeBlock(
            widget.boardId,
            widget.pad.id,
            b.id,
            sessionKey: _sessionKey,
            content: mine,
            rev: theirRev,
          );
      if (!mounted) return;
      setState(() => _editing = null);
      _reload();
    } on ApiException catch (e2) {
      if (!mounted) return;
      // 又被搶了。**不要自動再試**——重試會變成一場誰按得快的比賽，
      // 而每一輪都在覆蓋別人剛寫的東西
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('又被改了一次：${e2.message}')),
      );
    }
  }

  Future<void> _add(String text) async {
    try {
      await ref.read(scratchpadApiProvider).addBlock(
            widget.boardId,
            widget.pad.id,
            sessionKey: _sessionKey,
            content: text,
          );
      _reload();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
      // 同 _note：失敗要傳回去，否則剛打的那一段會被清掉
      rethrow;
    }
  }

  Future<void> _note(ScratchpadBlock b, String text) async {
    try {
      await ref.read(scratchpadApiProvider).addNote(
            widget.boardId,
            widget.pad.id,
            b.id,
            sessionKey: _sessionKey,
            content: text,
          );
      _reload();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
      // ⚠️ **要往上丟。** 吞掉的話呼叫端拿到的是一個成功的 Future，
      // 於是輸入框照樣被清空——toast 說失敗了，而那句話已經沒了
      rethrow;
    }
  }

  /// 把一則註解標成已處理（或收回）。
  ///
  /// ⚠️ **有這條之前，「N 則未處理」只會往上長**——一個只會增加的計數器，
  /// 第三天就沒有人看了，跟永遠亮著的紅點是同一件事。
  /// 有狀態就要有轉移，不然那個狀態是假的（@審核用Codex-2 #500）。
  Future<void> _resolveNote(String noteId, bool undo) async {
    try {
      await ref.read(scratchpadApiProvider).resolveNote(
            widget.boardId,
            widget.pad.id,
            noteId,
            sessionKey: _sessionKey,
            unresolve: undo,
          );
      _reload();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _delete(ScratchpadBlock b) async {
    try {
      await ref.read(scratchpadApiProvider).deleteBlock(
            widget.boardId,
            widget.pad.id,
            b.id,
            sessionKey: _sessionKey,
          );
      _reload();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

/// 一個段落。作者、內容、註解。
class _BlockCard extends StatefulWidget {
  const _BlockCard({
    super.key,
    required this.block,
    required this.editing,
    required this.onEdit,
    required this.onCancel,
    required this.onSave,
    required this.onNote,
    required this.onResolveNote,
    required this.onDelete,
  });

  final ScratchpadBlock block;
  final bool editing;
  final VoidCallback? onEdit;
  final VoidCallback onCancel;
  final ValueChanged<String> onSave;

  /// ⚠️ 回 `Future`，而且**成功才清輸入框**。同步 callback 加上按下就 clear
  /// 的話，POST 失敗時 toast 跳出來，而使用者剛打的那句意見已經沒了
  /// （@審核用Codex-2 2026-09-03）。
  final Future<void> Function(String)? onNote;

  /// `(noteId, undo)`。收回也走同一條——**標錯了要有路可以退**，
  /// 不然人會為了怕標錯而乾脆不標，那個數字就又回到只增不減。
  final void Function(String, bool)? onResolveNote;
  final VoidCallback? onDelete;

  @override
  State<_BlockCard> createState() => _BlockCardState();
}

class _BlockCardState extends State<_BlockCard> {
  late final TextEditingController _text =
      TextEditingController(text: widget.block.content);
  final _note = TextEditingController();

  @override
  void didUpdateWidget(_BlockCard old) {
    super.didUpdateWidget(old);
    // 不在編輯中才跟著外面的值走。編輯中同步的話會推走游標、吃掉組字，
    // 而使用者正在打的東西會被伺服器那份蓋掉——那是 key 解決不了的另一半
    if (!widget.editing && widget.block.content != _text.text) {
      _text.text = widget.block.content;
    }
  }

  /// 註解**預設展開**（艾斯維爾 #402：「段落旁邊，但應該還是要可以摺疊」）。
  ///
  /// ⚠️ 預設收起來的話這個功能等於沒做——agent 的註解就是它的產出，
  /// 而沒有人會去展開一個不知道裡面有沒有東西的區塊。
  bool _notesOpen = true;
  bool _noting = false;
  bool _sendingNote = false;

  @override
  void dispose() {
    _text.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final b = widget.block;
    final open = b.openNotes;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: s.bgCard,
        border: Border(
          left: BorderSide(
            // 人寫的那些用金色標出來——**那條線就是「agent 動不了這裡」**
            color: b.isHuman ? UepColors.gold : s.line,
            width: 2,
          ),
          top: BorderSide(color: s.hairline),
          right: BorderSide(color: s.hairline),
          bottom: BorderSide(color: s.hairline),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          KindBadge(kind: b.authorKind),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              b.authorName.isEmpty ? '（不知道是誰寫的）' : b.authorName,
              style: UepText.mono(size: 9, letterSpacing: 1.1,
                  color: s.inkMute),
            ),
          ),
          if (!widget.editing && widget.onEdit != null)
            _Tiny(label: '編輯', onTap: widget.onEdit!),
          if (!widget.editing && widget.onDelete != null) ...[
            const SizedBox(width: 6),
            _Tiny(label: '刪除', onTap: widget.onDelete!),
          ],
        ]),
        const SizedBox(height: 8),
        if (widget.editing) ...[
          TextField(
            controller: _text,
            maxLines: null,
            autofocus: true,
            style: UepText.sans(size: 13, color: s.ink, height: 1.5),
            decoration: const InputDecoration(
                border: OutlineInputBorder(), isDense: true),
          ),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            UepButton(
              label: '取消',
              variant: UepButtonVariant.outline,
              small: true,
              onPressed: () {
                _text.text = widget.block.content;
                widget.onCancel();
              },
            ),
            const SizedBox(width: 8),
            UepButton(
              label: '存起來',
              small: true,
              onPressed: () => widget.onSave(_text.text),
            ),
          ]),
        ] else
          SelectableText(
            b.content,
            style: UepText.sans(size: 13, color: s.ink, height: 1.55),
          ),
        if (b.notes.isNotEmpty || widget.onNote != null) ...[
          const SizedBox(height: 8),
          Divider(height: 1, color: s.hairline),
          const SizedBox(height: 6),
          InkWell(
            onTap: () => setState(() => _notesOpen = !_notesOpen),
            child: Row(children: [
              Icon(_notesOpen ? Icons.expand_less : Icons.expand_more,
                  size: 14, color: s.inkMute),
              const SizedBox(width: 4),
              Text(
                open.isEmpty ? '註解 ${b.notes.length}' : '註解 ${open.length} 則未處理',
                style: UepText.mono(
                    size: 9,
                    letterSpacing: 1.1,
                    color: open.isEmpty ? s.inkMute : UepColors.gold),
              ),
            ]),
          ),
          if (_notesOpen) ...[
            for (final n in b.notes)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 18),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text.rich(TextSpan(children: [
                        TextSpan(
                          text: '${n.authorName}：',
                          style: UepText.mono(size: 9, color: s.inkMute),
                        ),
                        TextSpan(
                          text: n.content,
                          // 處理過的畫刪除線：**留在原地但不再喊**。直接藏
                          // 起來的話，人會找不到自己剛剛處理的是哪一則
                          style: UepText.serif(
                            size: 12,
                            height: 1.45,
                            color: n.resolved ? s.inkMute : s.inkSoft,
                          ).copyWith(
                            decoration: n.resolved
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                      ])),
                    ),
                    if (widget.onResolveNote != null)
                      _Tiny(
                        label: n.resolved ? '收回' : '處理掉',
                        onTap: () =>
                            widget.onResolveNote!(n.id, n.resolved),
                      ),
                  ],
                ),
              ),
            if (widget.onNote != null) ...[
              const SizedBox(height: 6),
              if (!_noting)
                Align(
                  alignment: Alignment.centerLeft,
                  child: _Tiny(
                      label: '＋ 留一則意見',
                      onTap: () => setState(() => _noting = true)),
                )
              else
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _note,
                      autofocus: true,
                      style: UepText.sans(size: 12, color: s.ink),
                      decoration: const InputDecoration(
                          isDense: true, border: OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: 6),
                  _Tiny(
                    label: _sendingNote ? '送出中…' : '送出',
                    onTap: _sendingNote
                        ? null
                        : () async {
                            final t = _note.text.trim();
                            if (t.isEmpty) return;
                            setState(() => _sendingNote = true);
                            try {
                              await widget.onNote!(t);
                              if (!mounted) return;
                              // 成功了才清。失敗時那句話還在框裡，
                              // 他可以再送一次
                              _note.clear();
                              setState(() => _noting = false);
                            } catch (_) {
                              // ⚠️ **要接住。** 呼叫端已經 toast 過並 rethrow，
                              // 這裡只有 try/finally 的話那個例外會從 async
                              // onTap 逸出去變成未處理錯誤——輸入框裡的字保住
                              // 了，卻多了一個沒有人接的例外
                              // （@審核用Codex-2 2026-09-03）
                            } finally {
                              if (mounted) setState(() => _sendingNote = false);
                            }
                          },
                  ),
                ]),
            ],
          ],
        ],
      ]),
    );
  }
}

/// 兩份都攤出來，讓人自己挑。**不預設選任何一邊。**
class _ConflictDialog extends StatelessWidget {
  const _ConflictDialog({required this.mine, required this.theirs});

  final String mine;
  final String theirs;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return AlertDialog(
      backgroundColor: s.bgCard,
      title: Text('這一段在你打字的時候被改過了',
          style: UepText.display(size: 18, color: s.inkTitle)),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
            '兩份都在下面。**沒有自動合併**——合出來的那份會是誰都沒寫過的東西。',
            style: UepText.serif(size: 12, color: s.inkMute, height: 1.45),
          ),
          const SizedBox(height: 12),
          _Side(label: '你剛打的', text: mine, accent: UepColors.gold),
          const SizedBox(height: 8),
          _Side(label: '現在存著的', text: theirs, accent: s.line),
        ]),
      ),
      actions: [
        UepButton(
          label: '先不決定',
          variant: UepButtonVariant.outline,
          small: true,
          // 關掉＝什麼都不做，輸入框裡那份還在。**這是預設**，因為
          // 任何一邊被自動選中都會讓某個人的字消失
          onPressed: () => Navigator.of(context).pop(),
        ),
        UepButton(
          label: '用現在存著的',
          variant: UepButtonVariant.outline,
          small: true,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        UepButton(
          label: '用我打的蓋過去',
          small: true,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
  }
}

class _Side extends StatelessWidget {
  const _Side({required this.label, required this.text, required this.accent});

  final String label;
  final String text;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: s.bgSunken,
        border: Border(left: BorderSide(color: accent, width: 2)),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        MonoLabel(label, size: 9, letterSpacing: 1.2),
        const SizedBox(height: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 140),
          child: SingleChildScrollView(
            child: SelectableText(
              text.isEmpty ? '（空的）' : text,
              style: UepText.sans(size: 12, color: s.ink, height: 1.5),
            ),
          ),
        ),
      ]),
    );
  }
}

class _AddBlock extends StatefulWidget {
  const _AddBlock({required this.onAdd});

  /// 回 `Future`，**成功才清輸入框**。按下就清的話，POST 失敗時那一段
  /// 想法已經沒了，而 toast 只告訴他「失敗」，沒告訴他「你剛打的不見了」。
  final Future<void> Function(String) onAdd;

  @override
  State<_AddBlock> createState() => _AddBlockState();
}

class _AddBlockState extends State<_AddBlock> {
  final _c = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        controller: _c,
        maxLines: null,
        style: UepText.sans(size: 13, color: s.ink, height: 1.5),
        decoration: InputDecoration(
          hintText: '再想到什麼就往這裡丟…',
          hintStyle: UepText.serif(size: 12, color: s.inkMute),
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerRight,
        child: UepButton(
          label: _sending ? '送出中…' : '加一段',
          small: true,
          onPressed: (_sending || _c.text.trim().isEmpty)
              ? null
              : () async {
                  setState(() => _sending = true);
                  try {
                    await widget.onAdd(_c.text.trim());
                    if (mounted) _c.clear();
                  } catch (_) {
                    // 訊息已經由呼叫端 toast 過了。這裡只要**不清空**
                  } finally {
                    if (mounted) setState(() => _sending = false);
                  }
                },
        ),
      ),
    ]);
  }
}

class _Tiny extends StatelessWidget {
  const _Tiny({required this.label, required this.onTap});

  final String label;

  /// `null` ＝現在按不得（多半是送出中）。InkWell 收 null 就自己變成
  /// 不可點，不必另外做一個停用樣式。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Text(label,
            style: UepText.mono(
                size: 9,
                letterSpacing: 1.1,
                color: onTap == null ? s.inkMute : s.inkSoft)),
      ),
    );
  }
}

/// 一份想法板的整頁版（路由用）。
///
/// [ScratchpadScreen] 只有內容，沒有 Scaffold——那是為了讓它之後也能嵌在
/// 板頁的側欄裡。這一層負責標題列與返回。
class ScratchpadPage extends StatelessWidget {
  const ScratchpadPage({
    super.key,
    required this.boardId,
    required this.padId,
  });

  final String boardId;
  final String padId;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Scaffold(
      backgroundColor: s.bg,
      appBar: AppBar(
        backgroundColor: s.bg,
        title: Text('想法板', style: UepText.display(size: 20, color: s.inkTitle)),
      ),
      body: ScratchpadScreen(boardId: boardId, padId: padId),
    );
  }
}

/// 一份想法板的網址。**從哪裡點進來，就留在哪一軸**。
///
/// 板軸（`/boards/:bid/pads/:pid`）是權威路徑，但它會讓 `AppShell` 的
/// `selectedBoardId` 有值 ⇒ 左欄從 ROOMS 跳到 BOARDS。從聊天室點進來的人
/// 因此被換到另一個世界，而他只是想看一份想法板（艾斯維爾 2026-09-03）。
String padRoute({
  required String boardId,
  required String padId,
  String? roomId,
}) =>
    roomId != null
        ? '/rooms/$roomId/board/pads/$padId'
        : '/boards/$boardId/pads/$padId';

/// 從聊天室走進來的想法板：`/rooms/:roomId/board/pads/:padId`。
///
/// 想法板**屬於板**，所以權威網址是板軸那條（`/boards/:bid/pads/:pid`）。
/// 但從聊天室點進來的人不該被丟到板軸上：`AppShell` 靠 `selectedBoardId`
/// 決定左欄站在哪個分頁，板軸網址一出現，左欄就從 ROOMS 跳到 BOARDS——
/// 內容是對的，人卻被換到另一個世界，而且回去要自己找路。
///
/// 所以這裡多一條**房軸的相容入口**，與 `/rooms/:roomId/board` 同一族：
/// 網址記得你從哪來，boardId 則照 BoardScreen 的老辦法從房間解析。
class RoomScratchpadPage extends ConsumerWidget {
  const RoomScratchpadPage({
    super.key,
    required this.roomId,
    required this.padId,
  });

  final String roomId;
  final String padId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final async = ref.watch(boardProvider(roomId));
    return async.when(
      // 同上：板一有變動（WS 訊號、水位）這裡就 reload，而它底下正是
      // 那份想法板。少了這一行，別人在板上動一張卡就會清掉你打的字
      skipLoadingOnReload: true,
      loading: () => Scaffold(
        backgroundColor: s.bg,
        appBar: AppBar(backgroundColor: s.bg),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        backgroundColor: s.bg,
        appBar: AppBar(backgroundColor: s.bg),
        body: ErrorState(
          error: e,
          onRetry: () => ref.invalidate(boardProvider(roomId)),
        ),
      ),
      data: (snap) => snap.boardId.isEmpty
          // 房間沒掛板就沒有想法板可看。這不是錯誤，講清楚就好
          ? Scaffold(
              backgroundColor: s.bg,
              appBar: AppBar(
                backgroundColor: s.bg,
                title: Text('想法板',
                    style: UepText.display(size: 20, color: s.inkTitle)),
              ),
              body: Center(
                child: Text('這個聊天室還沒有掛上任何板。',
                    style: UepText.serif(size: 13, color: s.inkMute)),
              ),
            )
          : ScratchpadPage(boardId: snap.boardId, padId: padId),
    );
  }
}

/// 板上的想法板清單。**入口就是它**——沒有這一段的話，想法板那個畫面
/// 存在，但沒有任何地方走得到（@審核用Codex-2 2026-09-03）。
class ScratchpadSection extends ConsumerWidget {
  const ScratchpadSection({
    super.key,
    required this.boardId,
    required this.canEdit,
    this.roomId,
  });

  final String boardId;
  final bool canEdit;

  /// 從哪一間房走進這塊板的（板軸進來時是 null）。
  ///
  /// **只影響網址，不影響顯示的內容。** 一律往 `/boards/:bid/pads/:pid` 走的
  /// 話，`AppShell` 看到 `selectedBoardId` 有值就把左欄從 ROOMS 切到 BOARDS
  /// ——人是從聊天室點進來的，畫面卻換了一個世界，回去要自己找路
  /// （艾斯維爾 2026-09-03）。
  final String? roomId;

  String _padRoute(String padId) =>
      padRoute(boardId: boardId, padId: padId, roomId: roomId);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final async = ref.watch(scratchpadListProvider(boardId));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: MonoLabel('想法板', size: 9, letterSpacing: 2.2),
        ),
        if (canEdit)
          _Tiny(label: '＋ 開一份', onTap: () => _create(context, ref)),
      ]),
      const SizedBox(height: 8),
      async.when(
        loading: () => const SizedBox(
          height: 20,
          child: Center(
            child: SizedBox(
                width: 14, height: 14,
                child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        ),
        // 這個 Hub 還沒有想法板時不要畫一塊紅色的錯誤——它不是壞了，
        // 是還沒有。整段收起來，畫面上就當這個功能不存在
        error: (e, _) => e is NotFoundException
            ? const SizedBox.shrink()
            : ErrorState(
                error: e,
                onRetry: () => ref.invalidate(scratchpadListProvider(boardId)),
              ),
        data: (pads) => pads.isEmpty
            ? Text(
                canEdit
                    ? '還沒有想法板。想到什麼但還沒想好怎麼拆成卡的，先丟一份進來。'
                    : '還沒有想法板。',
                style: UepText.serif(size: 12, color: s.inkMute, height: 1.45),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final p in pads)
                    _PadRow(
                      pad: p,
                      onTap: () => context.go(_padRoute(p.id)),
                    ),
                ],
              ),
      ),
    ]);
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NewPadDialog(),
    );
    if (name == null || name.isEmpty) return;
    try {
      final id = await ref.read(scratchpadApiProvider).create(
            boardId,
            sessionKey: ref.read(appConfigProvider).deviceKey,
            title: name,
          );
      ref.invalidate(scratchpadListProvider(boardId));
      if (!context.mounted || id.isEmpty) return;
      context.go(_padRoute(id));
    } on ApiException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

class _PadRow extends StatelessWidget {
  const _PadRow({required this.pad, required this.onTap});

  final ScratchpadSummary pad;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: s.hairline)),
        ),
        child: Row(children: [
          Expanded(
            child: Text(
              pad.title.isEmpty ? '（未命名）' : pad.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: UepText.sans(size: 12.5, color: s.ink),
            ),
          ),
          // 未處理的註解數。**這是唯一能讓人知道「有人對你的段落提了意見」
          // 的線索**——不放在這裡，就只能一份一份打開去發現
          if (pad.unresolvedNotes > 0) ...[
            MonoLabel('${pad.unresolvedNotes} 則意見',
                size: 9, letterSpacing: 1.0, color: UepColors.gold),
            const SizedBox(width: 8),
          ],
          MonoLabel('${pad.blockCount} 段', size: 9, letterSpacing: 1.0),
        ]),
      ),
    );
  }
}

class _NewPadDialog extends StatefulWidget {
  const _NewPadDialog();

  @override
  State<_NewPadDialog> createState() => _NewPadDialogState();
}

class _NewPadDialogState extends State<_NewPadDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return AlertDialog(
      backgroundColor: s.bgCard,
      title: Text('開一份想法板',
          style: UepText.display(size: 18, color: s.inkTitle)),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: _c,
          autofocus: true,
          style: UepText.sans(size: 13, color: s.ink),
          decoration: InputDecoration(
            labelText: '叫什麼',
            helperText: '想到什麼先丟進去，之後再整理成卡',
            helperStyle: UepText.serif(size: 11, color: s.inkMute),
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (v) =>
              v.trim().isEmpty ? null : Navigator.of(context).pop(v.trim()),
        ),
      ),
      actions: [
        UepButton(
          label: '取消',
          variant: UepButtonVariant.outline,
          small: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
        UepButton(
          label: '開',
          small: true,
          onPressed: _c.text.trim().isEmpty
              ? null
              : () => Navigator.of(context).pop(_c.text.trim()),
        ),
      ],
    );
  }
}
