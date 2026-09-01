import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../models/board.dart';
import '../../state/board_providers.dart';
import '../../widgets/board_task_card.dart';
import '../../widgets/empty_error_states.dart';
import '../../core/errors/api_exception.dart';
import '../../widgets/kind_badge.dart';
import '../../widgets/uep_button.dart';
import 'board_create_dialog.dart';

/// Board 全頁畫面（設計稿 artboard 01）。
///
/// **不做房內側欄**：board 是三層樹狀資料，塞進 400px 側欄會變成沒人想用的
/// 東西。全頁在既有的 ShellRoute 底下，桌面版左側房間列表仍在，切回聊天是
/// 一下的事。
///
/// 版面：左 Objective 清單／右單一 Objective 展開。Checklist 是可摺疊的垂直
/// 區段，**不是看板欄**——三層樹用欄位切會讓「這個週期還剩什麼」散在畫面各處。
class BoardScreen extends ConsumerStatefulWidget {
  const BoardScreen({super.key, required this.roomId});

  final String roomId;

  @override
  ConsumerState<BoardScreen> createState() => _BoardScreenState();
}

class _BoardScreenState extends ConsumerState<BoardScreen> {
  String? _selectedObjectiveId;

  /// 只看孤兒。**不持久化**——它是「我現在要處理這批」，不是一個偏好。
  bool _orphansOnly = false;

  /// 剛剛認領失敗的卡 → 現任持有者。顯示在卡片上當成事實。
  final Map<String, String> _conflicts = {};

  Future<void> _claim(String taskId) async {
    final actions = ref.read(boardActionsProvider(widget.roomId));
    try {
      final r = await actions.claim(taskId);
      if (!mounted) return;
      setState(() => _conflicts.remove(taskId));
      if (r?.reclaimed == true) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('撿回了你上一世領走的卡。先看一下它的描述。')));
      }
    } catch (e) {
      // 領不到是正常結果，不是錯誤畫面：把「誰贏了」畫回卡片上
      if (!mounted) return;
      setState(() => _conflicts[taskId] = _holderFrom(e));
    }
  }

  /// 從 409 的訊息裡取出現任持有者。取不到就講一句誠實的話，不要留白。
  String _holderFrom(Object e) {
    final m = RegExp(r'「(.+?)」').firstMatch('$e');
    return m?.group(1) ?? '別人';
  }

  /// 開一張新卡。三層共用同一個對話框，差別只在它會長在哪。
  Future<void> _create(String kind,
      {String? parentId, String? parentTitle}) async {
    final actions = ref.read(boardActionsProvider(widget.roomId));
    final result = await showBoardCreateDialog(
        context, kind: kind, parentTitle: parentTitle);
    if (result == null) return;
    try {
      switch (kind) {
        case 'objective':
          final id = await actions.addObjective(result.title,
              description: result.description);
          // 新開的週期直接選起來——建立完的下一個動作幾乎一定是往裡面加東西
          if (id != null && mounted) setState(() => _selectedObjectiveId = id);
        case 'checklist':
          await actions.addChecklist(parentId!, result.title,
              description: result.description);
        case 'task':
          await actions.addTask(parentId!, result.title,
              description: result.description, priority: result.priority);
      }
    } on ApiException catch (e) {
      // 沒有這個 catch 的話，失敗只會拋進 framework，畫面上什麼都不會發生
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final async = ref.watch(boardProvider(widget.roomId));

    return Scaffold(
      backgroundColor: s.bgSunken,
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorState(
          error: e,
          onRetry: () => ref.invalidate(boardProvider(widget.roomId)),
        ),
        data: (snap) {
          final objectives = snap.sortedObjectives;
          if (objectives.isEmpty) return _emptyBoard(context);

          final selected = objectives.firstWhere(
            (o) => o.id == _selectedObjectiveId,
            orElse: () => objectives.first,
          );
          return LayoutBuilder(builder: (context, c) {
            // 窄螢幕收掉左欄，只留展開的那一條（清單走頂端的下拉）
            final wide = c.maxWidth >= 900;
            final detail = _objectivePane(context, snap, selected);
            if (!wide) return detail;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 300,
                  child: _objectiveList(context, snap, objectives, selected),
                ),
                Container(width: 1, color: s.hairline),
                Expanded(child: detail),
              ],
            );
          });
        },
      ),
    );
  }

  // ---------- 左：Objective 清單 ----------

  Widget _objectiveList(BuildContext context, BoardSnapshot snap,
      List<BoardObjective> objectives, BoardObjective selected) {
    final s = context.uep;
    final active = objectives.where((o) => o.status != 'done').toList();
    final done = objectives.where((o) => o.status == 'done').toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 12, 24),
      children: [
        Row(children: [
          Expanded(child: MonoLabel('OBJECTIVES · ${active.length} ACTIVE')),
          _BarButton(label: '＋ 新週期', onTap: () => _create('objective')),
        ]),
        const SizedBox(height: 10),
        for (final o in active)
          _objectiveTile(context, snap, o, o.id == selected.id),
        if (done.isNotEmpty) ...[
          const SizedBox(height: 16),
          MonoLabel('已完成 · ${done.length}', color: s.inkMute),
          const SizedBox(height: 8),
          for (final o in done)
            _objectiveTile(context, snap, o, o.id == selected.id),
        ],
      ],
    );
  }

  Widget _objectiveTile(BuildContext context, BoardSnapshot snap,
      BoardObjective o, bool selected) {
    final s = context.uep;
    final stats = _statsOf(snap, o);
    return InkWell(
      onTap: () => setState(() => _selectedObjectiveId = o.id),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
        decoration: BoxDecoration(
          color: selected ? s.bgCard : null,
          border: Border(
            left: BorderSide(
              color: selected ? UepColors.gold : s.hairline,
              width: selected ? 2 : 1,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(o.title,
                      style: UepText.sans(
                          size: 12.5,
                          weight: FontWeight.w600,
                          color: o.status == 'done' ? s.inkMute : s.inkTitle)),
                ),
                // ⚠️ 這兩個標籤第一版寫反了。`review` 是「送審完、**等人類
                // 確認**」，`verified` 是「已確認、**等人類按完成**」——
                // 兩者都只有人類推得動，所以**兩者都是金色**。
                // 讓 verified 退成灰色會變成畫面主動說「已經好了」，
                // 而那個週期其實還停在倒數第二格（測試端 2026-09-01 指出）。
                if (o.status == 'review')
                  Text('等你確認',
                      style: UepText.mono(size: 9, color: UepColors.gold))
                else if (o.status == 'verified')
                  Text('等你收尾',
                      style: UepText.mono(size: 9, color: UepColors.gold)),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              stats.summary,
              style: UepText.mono(size: 9, color: s.inkMute),
            ),
            // 孤兒直接寫在清單上——它是「看起來有人在做、實際上沒有」，
            // 價值全在於有人注意到
            if (stats.orphans > 0)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('${stats.orphans} 孤兒',
                    style:
                        UepText.mono(size: 9, color: UepColors.kindOther)),
              ),
          ],
        ),
      ),
    );
  }

  // ---------- 右：單一 Objective 展開 ----------

  Widget _objectivePane(
      BuildContext context, BoardSnapshot snap, BoardObjective o) {
    final s = context.uep;
    final stats = _statsOf(snap, o);
    final checklists = snap.checklistsOf(o.id);

    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 22, 28, 48),
      children: [
        Text(o.title,
            style: UepText.serif(
                size: 22, weight: FontWeight.w600, color: s.inkTitle)),
        if (o.description.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(o.description,
              style: UepText.serif(size: 12.5, color: s.ink, height: 1.6)),
        ],
        const SizedBox(height: 16),
        _closeoutBar(context, o, stats),
        if (stats.orphans > 0) ...[
          const SizedBox(height: 12),
          _orphanBanner(context, snap, o, stats),
        ],
        const SizedBox(height: 20),
        for (final c in checklists) _checklistSection(context, snap, c),
        if (checklists.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 12),
            child: Text('這個週期還沒有階段。',
                style: UepText.mono(size: 11, color: s.inkMute)),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: _BarButton(
            label: '＋ 階段',
            onTap: () =>
                _create('checklist', parentId: o.id, parentTitle: o.title),
          ),
        ),
      ],
    );
  }

  /// 送審 → 確認 → 完成（設計稿 artboard 05）。
  ///
  /// ⚠️ **人類與 agent 看到的不是同一件事**：確認那顆按鈕只有人類有。
  /// 這個畫面本身跑在人類的 App 上，所以按鈕在；agent 走 MCP，那邊根本
  /// 沒有 verify 工具——不是按了才失敗。
  Widget _closeoutBar(
      BuildContext context, BoardObjective o, _Stats stats) {
    final s = context.uep;
    final actions = ref.read(boardActionsProvider(widget.roomId));
    final canReview = stats.remaining == 0 && o.status == 'active';

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: s.bgSoft,
        border: Border.all(color: s.hairline),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${stats.done} / ${stats.total} 完成',
                    style: UepText.mono(size: 11, color: s.ink)),
                const SizedBox(height: 3),
                Text(_closeoutHint(o, stats),
                    style: UepText.mono(size: 9, color: s.inkMute)),
              ],
            ),
          ),
          if (o.status == 'active')
            _BarButton(
              label: '送審',
              // 條件未滿時按鈕是死的，而且旁邊寫著為什麼
              onTap: canReview ? () => actions.reviewObjective(o.id) : null,
            )
          else if (o.status == 'review') ...[
            _BarButton(
                label: '打回', onTap: () => actions.reopenObjective(o.id)),
            const SizedBox(width: 8),
            _BarButton(
              label: '確認',
              accent: true,
              onTap: () => actions.verifyObjective(o.id),
            ),
          ] else if (o.status == 'verified')
            _BarButton(
              label: '結束週期',
              accent: true,
              onTap: () => actions.completeObjective(o.id),
            ),
        ],
      ),
    );
  }

  String _closeoutHint(BoardObjective o, _Stats stats) {
    return switch (o.status) {
      'active' when stats.remaining > 0 => [
          '${stats.remaining} 張未完成',
          if (stats.orphans > 0) '${stats.orphans} 張沒有人在上面',
        ].join(' · '),
      'active' => '全部完成，可以送審',
      'review' => '已送審，等人確認過才能結束週期',
      'verified' => '已確認，可以結束這個週期',
      'done' => '這個週期已經結束',
      _ => '',
    };
  }

  /// 孤兒橫幅。設計稿把它放在最上面，因為它是這塊板上最需要有人接手的東西。
  Widget _orphanBanner(BuildContext context, BoardSnapshot snap,
      BoardObjective o, _Stats stats) {
    final s = context.uep;
    final orphans = _tasksOf(snap, o).where((t) => t.isOrphaned).toList();
    // 每張卡各自說自己的原因——「因閒置移出」與「session 已結束」不是同
    // 一件事，混成一句「有人離開了」就等於沒說
    final lines = orphans
        .take(3)
        .map((t) => t.orphanedReasonLabel.isEmpty
            ? '${t.claimName} 已不在房內'
            : '${t.claimName} ${t.orphanedReasonLabel}')
        .toSet()
        .join('，');

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        border: Border(
            left: BorderSide(color: UepColors.kindOther, width: 2)),
        color: UepColors.kindOther.withValues(alpha: .06),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${stats.orphans} 張卡的持有者已不在房內',
                    style: UepText.sans(size: 12, color: s.inkTitle)),
                if (lines.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(lines,
                      style: UepText.mono(size: 9, color: s.inkMute)),
                ],
              ],
            ),
          ),
          _BarButton(
            label: _orphansOnly ? '看全部' : '只看孤兒 →',
            onTap: () => setState(() => _orphansOnly = !_orphansOnly),
          ),
        ],
      ),
    );
  }

  // ---------- Checklist 區段 ----------

  Widget _checklistSection(
      BuildContext context, BoardSnapshot snap, BoardChecklist c) {
    final s = context.uep;
    var tasks = snap.tasksOf(c.id);
    if (_orphansOnly) tasks = tasks.where((t) => t.isOrphaned).toList();
    if (_orphansOnly && tasks.isEmpty) return const SizedBox.shrink();

    final done = snap.tasksOf(c.id).where((t) => t.isDone).length;
    final total = snap.tasksOf(c.id).length;

    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(c.title,
                  style: UepText.sans(
                      size: 13,
                      weight: FontWeight.w600,
                      color: s.inkTitle)),
              const SizedBox(width: 10),
              Text('$done / $total DONE',
                  style: UepText.mono(size: 9, color: s.inkMute)),
              const Spacer(),
              _BarButton(
                label: '＋ 任務',
                onTap: () =>
                    _create('task', parentId: c.id, parentTitle: c.title),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final t in tasks)
            BoardTaskCard(
              task: t,
              conflict: _conflicts[t.id],
              isMineToReclaim:
                  snap.reclaimable.any((r) => r.id == t.id),
              onClaim: t.isClaimable ? () => _claim(t.id) : null,
              onRelease: t.isHeld
                  ? () => ref
                      .read(boardActionsProvider(widget.roomId))
                      .release(t.id)
                  : null,
            ),
          if (tasks.isEmpty)
            Text('這個階段還沒有任務。',
                style: UepText.mono(size: 10, color: s.inkMute)),
        ],
      ),
    );
  }

  /// 空板（設計稿 artboard 08）。要邀請人開始，而不是看起來壞掉。
  Widget _emptyBoard(BuildContext context) {
    final s = context.uep;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('這塊板還是空的。',
                style: UepText.serif(size: 17, color: s.inkTitle)),
            const SizedBox(height: 10),
            Text(
              '開一條週期，把今天講定的事放進去；\n之後的三百則訊息就不會把它沖走。',
              textAlign: TextAlign.center,
              style: UepText.serif(size: 12.5, color: s.inkMute, height: 1.7),
            ),
            const SizedBox(height: 20),
            UepButton(label: '＋ 新週期', onPressed: () => _create('objective')),
          ],
        ),
      ),
    );
  }

  // ---------- 聚合 ----------

  List<BoardTask> _tasksOf(BoardSnapshot snap, BoardObjective o) => [
        for (final c in snap.checklistsOf(o.id)) ...snap.tasksOf(c.id),
      ];

  _Stats _statsOf(BoardSnapshot snap, BoardObjective o) {
    final checklists = snap.checklistsOf(o.id);
    final tasks = _tasksOf(snap, o);
    final done = tasks.where((t) => t.isDone).length;
    final cancelled = tasks.where((t) => t.status == 'cancelled').length;
    return _Stats(
      stages: checklists.length,
      total: tasks.length,
      done: done,
      // 取消的不算「還沒做完」——它已經有結論了
      remaining: tasks.length - done - cancelled,
      orphans: tasks.where((t) => t.isOrphaned).length,
    );
  }
}

class _Stats {
  const _Stats({
    required this.stages,
    required this.total,
    required this.done,
    required this.remaining,
    required this.orphans,
  });

  final int stages;
  final int total;
  final int done;
  final int remaining;
  final int orphans;

  String get summary => '$stages 階段 · $total 任務';
}

class _BarButton extends StatelessWidget {
  const _BarButton({required this.label, this.onTap, this.accent = false});

  final String label;

  /// null＝這顆按鈕是死的（條件未滿）。旁邊的說明會講為什麼。
  final VoidCallback? onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final enabled = onTap != null;
    final color = !enabled
        ? s.inkMute
        : accent
            ? UepColors.gold
            : s.ink;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: color.withValues(alpha: enabled ? .5 : .2)),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(label,
            style: UepText.mono(size: 10.5, color: color, letterSpacing: .5)),
      ),
    );
  }
}
