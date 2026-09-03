import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/api_exception.dart';
import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../models/scratchpad.dart';
import '../../state/app_providers.dart';
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

  void _reload() => ref.invalidate(scratchpadProvider(_key));

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final pad = widget.pad;
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 40),
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
        for (final b in pad.blocks)
          _BlockCard(
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
            onDelete: pad.canEdit && b.canEdit ? () => _delete(b) : null,
          ),
        if (pad.canEdit) ...[
          const SizedBox(height: 12),
          _AddBlock(onAdd: _add),
        ] else
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text('你在這塊板上是唯讀的，只能看。',
                style: UepText.serif(size: 12, color: s.inkMute)),
          ),
      ],
    );
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
                child: Text.rich(TextSpan(children: [
                  TextSpan(
                    text: '${n.authorName}：',
                    style: UepText.mono(size: 9, color: s.inkMute),
                  ),
                  TextSpan(
                    text: n.content,
                    style: UepText.serif(
                      size: 12,
                      height: 1.45,
                      color: n.resolved ? s.inkMute : s.inkSoft,
                    ),
                  ),
                ])),
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
