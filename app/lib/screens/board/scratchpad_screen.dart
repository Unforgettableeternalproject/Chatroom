import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/board_api.dart' show BoardsApi;
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
import '../../widgets/scratchpad_tag.dart';
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
      // 標籤選單只有板知道（預設 ∪ 板自訂）。**拿不到就是空的**——這時
      // 整套標籤 UI 不出現，而不是退回一份寫死的預設集合（見 BoardDelta）。
      //
      // ⚠️ 讀的是**快取裡已經有的那份**，不另外去要一次板：想法板一定是
      // 從板頁進來的，那份快照已經在手上。為了一排標籤而讓這個畫面多一個
      // 網路依賴，代價是它會跟著板的載入一起失敗——而標籤只是點綴
      data: (pad) => _PadBody(
        pad: pad,
        boardId: boardId,
        allowedTags:
            ref.watch(boardCacheProvider)[boardId]?.allowedTags ?? const [],
      ),
    );
  }
}

class _PadBody extends ConsumerStatefulWidget {
  const _PadBody({
    required this.pad,
    required this.boardId,
    this.allowedTags = const [],
  });

  final Scratchpad pad;
  final String boardId;

  /// 標籤選單的內容，來自板（`allowed_tags`）。空的時候整套標籤 UI 不出現。
  final List<String> allowedTags;

  @override
  ConsumerState<_PadBody> createState() => _PadBodyState();
}

class _PadBodyState extends ConsumerState<_PadBody> {
  /// 正在編輯哪一段。一次一段——同時開兩段的話，兩份 rev 都會過期，
  /// 而使用者不會知道是哪一段先壞的。
  String? _editing;

  /// 只看某一個標籤的段落。`null` = 全部。
  ///
  /// ⚠️ **這是純畫面上的過濾，不動資料。** 篩選中時排序功能要關掉——
  /// 拖曳送的是「整份新順序」，而手上只有一部分，送出去等於把沒顯示的
  /// 那些的位置一起重寫。
  String? _filter;

  /// 篩選之後看得到的段落。
  List<ScratchpadBlock> get _visible => _filter == null
      ? widget.pad.blocks
      : [
          for (final b in widget.pad.blocks)
            if (b.tag == _filter) b,
        ];

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
          // 管理這塊板的自訂標籤。**只在標籤功能真的在時出現**——
          // 舊 Hub 沒有 `allowed_tags`，那時這顆按鈕按下去是一個空對話框
          if (pad.canEdit && widget.allowedTags.isNotEmpty) ...[
            const SizedBox(width: 8),
            _Tiny(label: '標籤', onTap: _manageTags),
          ],
        ]),
        const SizedBox(height: 4),
        Text(
          '把想到的先放進來，不必先想好順序。'
          'agent 讀得到，也能對每一段留意見——但改不動你寫的東西。',
          style: UepText.serif(size: 12, color: s.inkMute, height: 1.5),
        ),
        if (widget.allowedTags.isNotEmpty) ...[
          const SizedBox(height: 12),
          _TagFilterBar(
            allowed: widget.allowedTags,
            selected: _filter,
            counts: {
              for (final t in widget.allowedTags)
                t: [
                  for (final b in pad.blocks)
                    if (b.tag == t) b,
                ].length,
            },
            onPick: (t) => setState(() => _filter = t),
          ),
        ],
        const SizedBox(height: 16),
        // 排得動時整段換成可拖曳的清單。**拖不動就不要留拖曳把手**——
        // 那比沒有把手更讓人以為壞了（同 board_screen 的 _canReorder）
        //
        // 🔴 篩選中時**一律不給拖**：拖曳送的是整份新順序，而手上只有符合
        // 篩選的那一部分，送出去會把沒顯示的那些位置一起重寫——畫面上完全
        // 看不出發生了什麼
        if (pad.canReorder && _filter == null)
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
        else ...[
          for (final b in _visible) _blockCard(pad, b),
          // 篩掉了全部時要說出來。空白畫面與「這塊板還沒有東西」看起來
          // 一模一樣，而使用者多半已經忘記自己按了篩選
          if (_visible.isEmpty && pad.blocks.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                '這個標籤底下還沒有段落。',
                textAlign: TextAlign.center,
                style: UepText.serif(size: 12, color: s.inkMute),
              ),
            ),
        ],
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
            ? _AddBlock(
                onAdd: _add,
                allowedTags: widget.allowedTags,
                initialTag: _filter,
              )
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
        allowedTags: widget.allowedTags,
        onSetTag: pad.canEdit && b.canEdit ? (t) => _setTag(b, t) : null,
      );

  /// 管理這塊板的自訂標籤。
  ///
  /// 開完之後**一定要 invalidate 板的快取**：選單內容是從那份快照讀的，
  /// 不重拉的話新增的標籤要等下一次板變動才會出現在段落的選單裡。
  Future<void> _manageTags() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _TagManagerDialog(
        boardId: widget.boardId,
        allowed: widget.allowedTags,
        sessionKey: _sessionKey,
        api: ref.read(boardsApiProvider),
      ),
    );
    if (!mounted) return;
    ref.invalidate(boardByIdProvider(widget.boardId));
    _reload();
  }

  /// 只改標籤，內容原封不動送回去。
  ///
  /// ⚠️ 走的是同一支 `writeBlock`（Hub 沒有單獨改標籤的端點），所以 **rev
  /// 照樣會被檢查**——別人在你按下選單的那一刻改了內容的話這裡會 409，
  /// 而正確的處置是重拉，不是把手上的舊內容連著新標籤寫回去（那會把他
  /// 剛寫的字蓋掉，而使用者以為自己只是點了一個標籤）。
  Future<void> _setTag(ScratchpadBlock b, String? tag) async {
    try {
      await ref.read(scratchpadApiProvider).writeBlock(
            widget.boardId,
            widget.pad.id,
            b.id,
            sessionKey: _sessionKey,
            content: b.content,
            rev: b.rev,
            tags: tag == null ? const [] : [tag],
          );
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.code == 'scratchpad_block_stale'
              ? '這一段剛被別人改過，重新載入後再標一次'
              : e.message),
        ));
      }
    }
    _reload();
  }

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
            // ⚠️ **`tags` 送的是整份新值，不是差異。** 不帶的話「改一個錯字」
            // 會順手把這一段的標籤清掉——不會報錯，只有下次去篩選時才發現
            // 它從分堆裡消失了
            tags: b.tags,
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
            // 同 _save：整份送，不帶等於清掉
            tags: b.tags,
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

  Future<void> _add(String text, String? tag) async {
    try {
      await ref.read(scratchpadApiProvider).addBlock(
            widget.boardId,
            widget.pad.id,
            sessionKey: _sessionKey,
            content: text,
            tags: tag == null ? const [] : [tag],
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
/// 管理板自訂標籤。
///
/// ⚠️ **這裡分不出哪些是預設標籤、哪些是這塊板自己加的**——Hub 的
/// `allowed_tags` 是兩者的聯集，而 `custom_tags` 沒有隨板回來。所以刪除
/// 對每一顆都開放，預設集合由 Hub 用 422 `tag_is_default` 擋下。
///
/// 這不是理想的形狀（專案的規矩是「畫一個永遠按不動的按鈕比不畫更難懂」，
/// 這裡等於反過來：畫一顆註定失敗的按鈕）。正解是 Hub 隨板回 `custom_tags`，
/// 已在房內提出；補上之後這裡把預設那些鎖起來就好，是一行的事。
/// **在那之前，錯誤訊息要說得夠清楚**，不能只丟一句「操作失敗」。
class _TagManagerDialog extends StatefulWidget {
  const _TagManagerDialog({
    required this.boardId,
    required this.allowed,
    required this.sessionKey,
    required this.api,
  });

  final String boardId;
  final List<String> allowed;
  final String sessionKey;
  final BoardsApi api;

  @override
  State<_TagManagerDialog> createState() => _TagManagerDialogState();
}

class _TagManagerDialogState extends State<_TagManagerDialog> {
  late List<String> _allowed = [...widget.allowed];
  final _input = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final t = _input.text.trim();
    if (t.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.api
          .addTags(widget.boardId, sessionKey: widget.sessionKey, tags: [t]);
      if (!mounted) return;
      setState(() {
        _allowed = r.allowed;
        _input.clear();
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(String tag) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.api
          .removeTag(widget.boardId, tag, sessionKey: widget.sessionKey);
      if (!mounted) return;
      setState(() => _allowed = r.allowed);
    } on ApiException catch (e) {
      if (!mounted) return;
      // 🔴 **`tag_in_use` 要指得出是哪幾則。** 擋下來而已是把問題換個地方
      // 放——使用者會反覆按同一顆刪除鈕，因為畫面沒告訴他該先去改什麼
      setState(() => _error = tagRemovalError(
            e.code,
            tag,
            blockCount: (e.detail['block_ids'] as List?)?.length ?? 0,
            fallback: e.message,
          ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return AlertDialog(
      backgroundColor: s.bgCard,
      title: Text('這塊板的標籤',
          style: UepText.display(size: 18, color: s.inkTitle)),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
            '段落一次只標一個。新增的標籤這塊板上的人都用得到；'
            '預設的四個每塊板都有，刪不掉。',
            style: UepText.serif(size: 12, color: s.inkMute, height: 1.5),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final t in _allowed)
              Container(
                padding: const EdgeInsets.only(left: 8, right: 2),
                decoration: BoxDecoration(
                  border: Border.all(
                      color: tagColor(t).withValues(alpha: .5)),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(tagLabel(t),
                      style: UepText.mono(
                          size: 9, letterSpacing: 1.0, color: tagColor(t))),
                  IconButton(
                    tooltip: '刪掉',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 26, minHeight: 26),
                    onPressed: _busy ? null : () => _remove(t),
                    icon: Icon(Icons.close, size: 12, color: s.inkMute),
                  ),
                ]),
              ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _input,
                style: UepText.sans(size: 13, color: s.ink),
                decoration: InputDecoration(
                  hintText: '新增一個標籤…',
                  hintStyle: UepText.serif(size: 12, color: s.inkMute),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (_) => _add(),
              ),
            ),
            const SizedBox(width: 8),
            UepButton(label: '新增', small: true, onPressed: _busy ? null : _add),
          ]),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style: UepText.sans(size: 12, color: UepColors.error,
                    height: 1.45)),
          ],
        ]),
      ),
      actions: [
        UepButton(
          label: '關起來',
          variant: UepButtonVariant.outline,
          small: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

/// 依標籤篩選。**數字跟著每一顆走**——「Bug 0」與「沒有 Bug 這個標籤」
/// 是兩件事，而使用者要的是前者：他想知道自己有沒有漏標。
class _TagFilterBar extends StatelessWidget {
  const _TagFilterBar({
    required this.allowed,
    required this.selected,
    required this.counts,
    required this.onPick,
  });

  final List<String> allowed;
  final String? selected;
  final Map<String, int> counts;
  final ValueChanged<String?> onPick;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Wrap(spacing: 6, runSpacing: 6, children: [
      _pill(s, label: '全部', on: selected == null, onTap: () => onPick(null),
          color: s.inkMute),
      for (final t in allowed)
        _pill(
          s,
          label: '${tagLabel(t)} ${counts[t] ?? 0}',
          on: selected == t,
          color: tagColor(t),
          // 再按一次收起來——按了才發現不是想看的那一堆時，路要在原地
          onTap: () => onPick(selected == t ? null : t),
        ),
    ]);
  }

  Widget _pill(UepSurface s,
          {required String label,
          required bool on,
          required Color color,
          required VoidCallback onTap}) =>
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(3),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: on ? color.withValues(alpha: .13) : null,
            border: Border.all(
                color: on ? color.withValues(alpha: .55) : s.line),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text(
            label,
            style: UepText.mono(
              size: 9,
              letterSpacing: 1.0,
              color: on ? color : s.inkMute,
            ),
          ),
        ),
      );
}

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
    this.allowedTags = const [],
    this.onSetTag,
  });

  final ScratchpadBlock block;
  final bool editing;

  /// 選單內容，一律來自 Hub（見 [ScratchpadTagChip]）。
  final List<String> allowedTags;

  /// 改這一段的標籤（`null` = 取消標籤）。唯讀時給 `null`。
  final ValueChanged<String?>? onSetTag;
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
          // 標籤放在動作按鈕之前：它是這一段「是什麼」，不是能對它做什麼
          ScratchpadTagChip(
            tag: b.tag,
            allowed: widget.allowedTags,
            onPick: widget.onSetTag,
          ),
          if (b.tag != null || widget.allowedTags.isNotEmpty)
            const SizedBox(width: 6),
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
  const _AddBlock({
    required this.onAdd,
    this.allowedTags = const [],
    this.initialTag,
  });

  /// 回 `Future`，**成功才清輸入框**。按下就清的話，POST 失敗時那一段
  /// 想法已經沒了，而 toast 只告訴他「失敗」，沒告訴他「你剛打的不見了」。
  final Future<void> Function(String, String?) onAdd;

  final List<String> allowedTags;

  /// 正在篩某個標籤時預設帶上它。**不帶的話新增的那一段會當場從畫面上
  /// 消失**（它不符合篩選），而人會以為沒有存成功。
  final String? initialTag;

  @override
  State<_AddBlock> createState() => _AddBlockState();
}

class _AddBlockState extends State<_AddBlock> {
  final _c = TextEditingController();
  bool _sending = false;
  late String? _tag = widget.initialTag;

  @override
  void didUpdateWidget(_AddBlock old) {
    super.didUpdateWidget(old);
    // 篩選換了就跟著換——除非人已經自己挑過別的
    if (widget.initialTag != old.initialTag && _tag == old.initialTag) {
      _tag = widget.initialTag;
    }
  }

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
      Row(children: [
        ScratchpadTagChip(
          tag: _tag,
          allowed: widget.allowedTags,
          onPick: (t) => setState(() => _tag = t),
        ),
        const Spacer(),
        UepButton(
          label: _sending ? '送出中…' : '加一段',
          small: true,
          onPressed: (_sending || _c.text.trim().isEmpty)
              ? null
              : () async {
                  setState(() => _sending = true);
                  try {
                    await widget.onAdd(_c.text.trim(), _tag);
                    if (mounted) _c.clear();
                  } catch (_) {
                    // 訊息已經由呼叫端 toast 過了。這裡只要**不清空**
                  } finally {
                    if (mounted) setState(() => _sending = false);
                  }
                },
        ),
      ]),
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
