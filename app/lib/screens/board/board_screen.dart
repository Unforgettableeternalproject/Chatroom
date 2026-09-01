import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../models/board.dart';
import '../../state/board_providers.dart';
import '../../state/rooms_providers.dart';
import '../../widgets/board_task_card.dart';
import '../../widgets/empty_error_states.dart';
import '../../core/errors/api_exception.dart';
import '../../widgets/kind_badge.dart';
import '../../widgets/uep_button.dart';
import 'board_create_dialog.dart';
import 'board_task_drawer.dart';

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

/// `filter: saturate(.35)` 的色彩矩陣（設計稿封存板）。
///
/// 亮度權重用標準的 Rec.601（.2126/.7152/.0722）——用等權重會讓綠色的
/// claude 軸退得比藍色的 codex 軸多，而封存要的是一起退，不是挑人退。
const List<double> _desaturate35 = <double>[
  0.2126 + 0.7874 * .35, 0.7152 - 0.7152 * .35, 0.0722 - 0.0722 * .35, 0, 0, //
  0.2126 - 0.2126 * .35, 0.7152 + 0.2848 * .35, 0.0722 - 0.0722 * .35, 0, 0, //
  0.2126 - 0.2126 * .35, 0.7152 - 0.7152 * .35, 0.0722 + 0.9278 * .35, 0, 0, //
  0, 0, 0, 1, 0, //
];

class _BoardScreenState extends ConsumerState<BoardScreen> {
  String? _selectedObjectiveId;

  /// 只看孤兒。**不持久化**——它是「我現在要處理這批」，不是一個偏好。
  bool _orphansOnly = false;

  /// 收起來的階段。同樣不持久化：它是這一次的閱讀動作。
  final Set<String> _collapsed = {};

  /// 開著詳情抽屜的那張卡。
  String? _openTaskId;

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

    final body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context, async.value),
          if (_archived) _archivedNotice(context),
          Expanded(
            child: async.when(
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
                  // 窄螢幕收掉左欄，只留展開的那一條
                  final wide = c.maxWidth >= 900;
                  final detail = _objectivePane(context, snap, selected);
                  final drawer = _drawer(context, snap, c.maxWidth);
                  if (!wide) {
                    // 窄螢幕的抽屜蓋滿——420px 的抽屜配上更窄的板，
                    // 剩下的那條縫誰都用不上
                    return drawer == null
                        ? detail
                        : Stack(children: [detail, Positioned.fill(child: drawer)]);
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: 300,
                        child: _objectiveList(
                            context, snap, objectives, selected),
                      ),
                      Container(width: 1, color: s.hairline),
                      Expanded(child: detail),
                      ?drawer,
                    ],
                  );
                });
              },
            ),
          ),
        ],
      );

    return Scaffold(
      backgroundColor: s.bg,
      // 封存的板整塊降飽和——顏色在這塊板上都是「誰在上面、還要做什麼」，
      // 而這裡兩件事都已經結束了。它是歷史，不是待辦
      body: _archived
          ? ColorFiltered(
              colorFilter: const ColorFilter.matrix(_desaturate35),
              child: body,
            )
          : body,
    );
  }

  /// 這塊板是不是唯讀的歷史。
  ///
  /// 🔴 **v2 遷移必改：訊號源會變，但這裡不會有任何地方報錯。**
  ///
  /// v1 是一房一板，房封存了板就沒有別的入口，所以「房封存 ⇒ 板唯讀」成立。
  /// **v2 把這條反過來**（`BOARD_DESIGN.md` §3.2 + 驗收條件 2）：
  ///
  /// > room 封存：該 room 唯讀；**Board 仍可從其他 room 或 Board Library 編輯**。
  ///
  /// 一塊 Board 掛 A、B 兩房，A 封存後 B 照樣在寫它。屆時這個 getter 會讓
  /// 從 A 進來的人看到一塊整片變灰、動作全收的板——**而那塊板是活的**。
  /// 畫面說了一件不成立的事，而且不會有任何測試或例外抓得到。
  ///
  /// ⇒ Hub 一有 `board.status` 就改看它。§11 的遷移八步沒有一步會撞到這裡，
  /// 所以這段註解是它唯一的守衛。
  bool get _archived =>
      ref.watch(roomDetailProvider(widget.roomId)).value?.room.status ==
      'archived';

  Widget _archivedNotice(BuildContext context) {
    final s = context.uep;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
      decoration: BoxDecoration(
        color: s.bgSoft,
        border: Border(bottom: BorderSide(color: s.hairline)),
      ),
      child: Text('房間已封存。板是唯讀的歷史，不能認領、不能改狀態。',
          style: UepText.serif(size: 12, color: s.inkMute)),
    );
  }

  /// 詳情抽屜。**卡不在了就自己關掉**——它可能被刪掉、或被別人移走，
  /// 留一個指向不存在的卡的抽屜會定在最後一次的畫面上不動。
  Widget? _drawer(BuildContext context, BoardSnapshot snap, double maxWidth) {
    if (_openTaskId == null) return null;
    final task = snap.tasks[_openTaskId];
    if (task == null || task.deleted) return null;
    return BoardTaskDrawer(
      roomId: widget.roomId,
      task: task,
      checklistTitle: snap.checklists[task.checklistId]?.title ?? '',
      assigneeName: _assigneeName(task),
      readOnly: _archived,
      onClose: () => setState(() => _openTaskId = null),
    );
  }

  /// 被指定者的顯示名稱。
  ///
  /// ⚠️ 從**現在還在房裡的人**查，查不到就是 null。Hub 刻意不為
  /// `assignee_participant_id` 存名字快照——指定是「現在該由誰做」，
  /// 人不在了就該看得出這個指定已經沒有意義。
  String? _assigneeName(BoardTask task) {
    final id = task.assigneeParticipantId;
    if (id == null) return null;
    final members = ref.read(roomDetailProvider(widget.roomId)).value
            ?.participants ??
        const [];
    for (final p in members) {
      if (p.id == id && p.isActive) return p.displayName;
    }
    return null;
  }

  /// 頁首（設計稿 artboard 01，56px）。
  ///
  /// **「← 回到聊天室」是這條列存在的主要理由**：board 是全頁，沒有這個入口
  /// 就只剩系統返回鍵。房名與 zone 徽章跟著，讓人知道自己在哪個房間的板上
  /// ——桌面版同時開著好幾個房間時，光看板子是分不出來的。
  Widget _header(BuildContext context, BoardSnapshot? snap) {
    final s = context.uep;
    final detail = ref.watch(roomDetailProvider(widget.roomId));
    final room = detail.value?.room;
    final zone = zoneForRoomId(widget.roomId);
    final palette = uepZonePalettes[zone]!;
    final dark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: s.bgSoft,
        border: Border(bottom: BorderSide(color: s.hairline)),
      ),
      child: Row(children: [
        _HeaderAction(
          label: '← 回到聊天室',
          onTap: () => context.go('/rooms/${widget.roomId}'),
        ),
        const SizedBox(width: 16),
        Container(width: 1, height: 20, color: s.hairline),
        const SizedBox(width: 16),
        Flexible(
          child: Text(
            room?.name ?? '',
            overflow: TextOverflow.ellipsis,
            style: UepText.display(
                size: 19, weight: FontWeight.w600, color: s.inkTitle),
          ),
        ),
        if (room != null) ...[
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              border: Border.all(
                  color: dark ? palette.strokeDark : palette.strokeLight),
            ),
            child: Text(zone.name.toUpperCase(),
                style: UepText.mono(
                    size: 8.5, color: palette.soft, letterSpacing: 1.2)),
          ),
        ],
        const SizedBox(width: 12),
        Text('BOARD',
            style:
                UepText.mono(size: 9, color: s.inkMute, letterSpacing: 1.6)),
        const Spacer(),
        // supervisor 只在真的有指定時出現。沒有指定就不畫一個空殼——
        // 「沒有人在收摘要」與「有人但名字讀不到」不是同一件事
        if (snap?.supervisor != null && snap!.supervisor!.isNotEmpty) ...[
          _SupervisorPill(name: snap.supervisor!),
          const SizedBox(width: 12),
        ],
        if (_archived)
          const _ArchivedBadge()
        else
          _HeaderAction(
            label: '＋ 新週期',
            bordered: true,
            onTap: () => _create('objective'),
          ),
      ]),
    );
  }

  // ---------- 左：Objective 清單 ----------

  Widget _objectiveList(BuildContext context, BoardSnapshot snap,
      List<BoardObjective> objectives, BoardObjective selected) {
    final s = context.uep;
    final active = objectives.where((o) => o.status != 'done').toList();
    final done = objectives.where((o) => o.status == 'done').toList();

    // 左欄的底色比主區暗一階——它是索引不是內容，退後一層才不會跟右邊搶
    return Container(
      color: s.bgSoft,
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 11),
            child: MonoLabel('OBJECTIVES · ${active.length} ACTIVE',
                color: s.inkMute, letterSpacing: 2.2),
          ),
          for (final o in active)
            _objectiveTile(context, snap, o, o.id == selected.id),
          // 完成的週期退成一份名單：它們不再需要被點開，但要看得到做過什麼
          if (done.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 22, 16, 10),
              child: MonoLabel('已完成 · ${done.length}',
                  color: s.inkMute, letterSpacing: 2.2),
            ),
            Opacity(
              opacity: .5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final o in done)
                    InkWell(
                      onTap: () =>
                          setState(() => _selectedObjectiveId = o.id),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 3, 16, 3),
                        child: Text(o.title,
                            overflow: TextOverflow.ellipsis,
                            style:
                                UepText.sans(size: 12.5, color: s.inkSoft)),
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _objectiveTile(BuildContext context, BoardSnapshot snap,
      BoardObjective o, bool selected) {
    final s = context.uep;
    final stats = _statsOf(snap, o);
    return InkWell(
      onTap: () => setState(() => _selectedObjectiveId = o.id),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 13, 15, 14),
        decoration: BoxDecoration(
          // 選中不換底色而是**加一層金調**：換 bgCard 會讓它看起來像卡片，
          // 而它是清單的一列
          color: selected ? UepColors.gold.withValues(alpha: .07) : null,
          border: Border(
            left: BorderSide(
              color: selected ? UepColors.gold : Colors.transparent,
              width: 2,
            ),
            bottom: BorderSide(color: s.hairline),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(o.title,
                      style: UepText.sans(
                          size: 13.5,
                          weight: FontWeight.w600,
                          height: 1.5,
                          color: o.status == 'done'
                              ? s.inkMute
                              : selected
                                  ? s.inkTitle
                                  : s.ink)),
                ),
                // ⚠️ 這兩個標籤第一版寫反了。`review` 是「送審完、**等人類
                // 確認**」，`verified` 是「已確認、**等人類按完成**」——
                // 兩者都只有人類推得動，所以**兩者都是金色**。
                // 讓 verified 退成灰色會變成畫面主動說「已經好了」，
                // 而那個週期其實還停在倒數第二格（測試端 2026-09-01 指出）。
                if (o.status == 'review') ...[
                  const SizedBox(width: 9),
                  const _ObjectiveBadge(label: '等你確認', gold: true),
                ] else if (o.status == 'verified') ...[
                  const SizedBox(width: 9),
                  const _ObjectiveBadge(label: '等你收尾', gold: true),
                ],
              ],
            ),
            const SizedBox(height: 9),
            Row(children: [
              Text(
                o.status == 'done' ? '${stats.summary} · 已結束' : stats.summary,
                style: UepText.mono(size: 8.5, color: s.inkMute),
              ),
              // 孤兒直接寫在清單上——它是「看起來有人在做、實際上沒有」，
              // 價值全在於有人在點開之前就注意到
              if (stats.orphans > 0) ...[
                const SizedBox(width: 8),
                _Dot(color: s.inkMute),
                const SizedBox(width: 8),
                Text('${stats.orphans} 孤兒',
                    style:
                        UepText.mono(size: 8.5, color: UepColors.error)),
              ],
            ]),
            const SizedBox(height: 9),
            // 2px 的進度條：清單上唯一能一眼看出「這條走到哪」的東西
            _ProgressBar(
              ratio: stats.total == 0 ? 0 : stats.done / stats.total,
              color: switch (o.status) {
                'active' => UepColors.gold,
                'review' || 'verified' => UepColors.goldSoft,
                _ => s.inkSoft,
              },
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

    // 週期的抬頭與孤兒橫幅**不跟著捲**：橫幅講的是「這塊板現在有問題」，
    // 捲下去看任務時它更該留著
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _objectiveHeader(context, o, stats),
        if (stats.orphans > 0) _orphanBanner(context, snap, o, stats),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(26, 20, 26, 48),
            children: [
              for (final c in checklists) _checklistSection(context, snap, c),
              // 空的時候才在這裡再給一次入口——抬頭那顆已經在了，
              // 兩顆一樣的按鈕只會讓人懷疑它們是不是不同的東西
              if (checklists.isEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text('這個週期還沒有階段。',
                      style: UepText.mono(size: 11, color: s.inkMute)),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: _BarButton(
                    label: '＋ 階段',
                    onTap: _archived
                        ? null
                        : () => _create('checklist',
                            parentId: o.id, parentTitle: o.title),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 週期抬頭（設計稿 artboard 01 右上）：標題、描述、收尾動作、進度。
  ///
  /// 收尾動作放在**標題右邊**而不是另外框一塊——它是這個週期的動作，
  /// 跟標題同一層；獨立成框會變成第四個層級。
  Widget _objectiveHeader(
      BuildContext context, BoardObjective o, _Stats stats) {
    final s = context.uep;
    return Container(
      padding: const EdgeInsets.fromLTRB(26, 22, 26, 18),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: s.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(o.title,
                        style: UepText.display(
                            size: 30,
                            weight: FontWeight.w600,
                            color: s.inkTitle,
                            height: 1.25)),
                    if (o.description.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 620),
                        child: Text(o.description,
                            style: UepText.serif(
                                size: 13, color: s.inkSoft, height: 1.85)),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 18),
              _closeoutActions(context, o, stats),
            ],
          ),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: _ProgressBar(
                ratio: stats.total == 0 ? 0 : stats.done / stats.total,
                color: UepColors.gold,
              ),
            ),
            const SizedBox(width: 14),
            Text('${stats.done} / ${stats.total} 完成',
                style: UepText.mono(size: 9, color: s.inkSoft)),
          ]),
        ],
      ),
    );
  }

  /// 送審 → 確認 → 完成（設計稿 artboard 05）。
  ///
  /// ⚠️ **人類與 agent 看到的不是同一件事**：確認那顆按鈕只有人類有。
  /// 這個畫面本身跑在人類的 App 上，所以按鈕在；agent 走 MCP，那邊根本
  /// 沒有 verify 工具——不是按了才失敗。
  Widget _closeoutActions(
      BuildContext context, BoardObjective o, _Stats stats) {
    final s = context.uep;
    final actions = ref.read(boardActionsProvider(widget.roomId));
    final canReview = stats.remaining == 0 && o.status == 'active';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // 封存的板不給任何轉移——它是歷史。按鈕留著只會讓人按下去拿 409
        if (!_archived)
        Row(mainAxisSize: MainAxisSize.min, children: [
          if (o.status != 'done') ...[
            _BarButton(
              label: '＋ 階段',
              onTap: () =>
                  _create('checklist', parentId: o.id, parentTitle: o.title),
            ),
            const SizedBox(width: 8),
          ],
          if (o.status == 'active')
            _BarButton(
              label: '送審',
              // 條件未滿時按鈕是死的，而且底下寫著為什麼
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
        ]),
        const SizedBox(height: 10),
        Text(_closeoutHint(o, stats),
            textAlign: TextAlign.right,
            style: UepText.mono(size: 8.5, color: s.inkMute)),
      ],
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

    // 橫貫整寬的一條帶，不是左邊框的方塊：它講的是整塊板的狀況，
    // 不從屬於底下任何一段
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 11),
      decoration: BoxDecoration(
        color: UepColors.error.withValues(alpha: .07),
        border: Border(
          bottom:
              BorderSide(color: UepColors.error.withValues(alpha: .25)),
        ),
      ),
      child: Row(
        children: [
          Text('${stats.orphans} 張卡的持有者已不在房內',
              style: UepText.mono(
                  size: 9, color: UepColors.error, letterSpacing: 1.4)),
          if (lines.isNotEmpty) ...[
            const SizedBox(width: 12),
            Flexible(
              child: Text('$lines。',
                  overflow: TextOverflow.ellipsis,
                  style: UepText.serif(size: 12.5, color: s.inkSoft)),
            ),
          ],
          const Spacer(),
          const SizedBox(width: 12),
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

    final collapsed = _collapsed.contains(c.id);

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 摺疊控制。三層樹在一個週期有五、六個階段時就會超過一屏，
              // 沒有它就只能一直捲
              InkWell(
                onTap: () => setState(() {
                  if (collapsed) {
                    _collapsed.remove(c.id);
                  } else {
                    _collapsed.add(c.id);
                  }
                }),
                child: SizedBox(
                  width: 16,
                  child: Text(collapsed ? '＋' : '−',
                      style: UepText.mono(size: 9, color: s.inkMute)),
                ),
              ),
              Text(c.title,
                  style: UepText.sans(
                      size: 14,
                      weight: FontWeight.w600,
                      color: s.inkTitle)),
              const SizedBox(width: 12),
              Text('$done / $total DONE',
                  style: UepText.mono(
                      size: 9, color: s.inkMute, letterSpacing: 1.4)),
              const SizedBox(width: 12),
              // 標題與動作之間拉一條線：讓每一段的抬頭在視覺上自成一列
              Expanded(child: Container(height: 1, color: s.hairline)),
              const SizedBox(width: 12),
              _BarButton(
                label: '＋ 任務',
                onTap: () =>
                    _create('task', parentId: c.id, parentTitle: c.title),
              ),
            ],
          ),
          if (collapsed) const SizedBox(height: 4),
          if (!collapsed) ...[
          const SizedBox(height: 10),
          for (final t in tasks)
            BoardTaskCard(
              task: t,
              conflict: _conflicts[t.id],
              assigneeName: _assigneeName(t),
              onTap: () => setState(() => _openTaskId = t.id),
              isMineToReclaim:
                  snap.reclaimable.any((r) => r.id == t.id),
              onClaim: (t.isClaimable && !_archived)
                  ? () => _claim(t.id)
                  : null,
              onRelease: (t.isHeld && !_archived)
                  ? () => ref
                      .read(boardActionsProvider(widget.roomId))
                      .release(t.id)
                  : null,
            ),
          if (tasks.isEmpty)
            Text('這個階段還沒有任務。',
                style: UepText.mono(size: 10, color: s.inkMute)),
          ],
        ],
      ),
    );
  }

  /// 空板（設計稿 artboard 08）。要邀請人開始，而不是看起來壞掉。
  Widget _emptyBoard(BuildContext context) {
    final s = context.uep;
    final palette = uepZonePalettes[zoneForRoomId(widget.roomId)]!;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 房間 zone 色的「卷」。空畫面需要一個焦點，而它同時
            // 說出這是哪個房間的板
            Opacity(
              opacity: .5,
              child: Text('卷',
                  style: UepText.display(size: 34, color: palette.soft)),
            ),
            const SizedBox(height: 16),
            Text(
              _archived
                  ? '這塊板結束時是空的。'
                  : '這塊板還是空的。\n開一條週期，把今天講定的事放進去；\n之後的三百則訊息就不會把它沖走。',
              textAlign: TextAlign.center,
              style: UepText.serif(size: 13.5, color: s.inkSoft, height: 2),
            ),
            if (!_archived) ...[
              const SizedBox(height: 16),
              UepButton(
                  label: '＋ 新週期', onPressed: () => _create('objective')),
            ],
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

/// 封存徽章。它站在「＋ 新週期」原本的位置——**那個動作沒有了，
/// 取而代之的是為什麼沒有**。
class _ArchivedBadge extends StatelessWidget {
  const _ArchivedBadge();

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(border: Border.all(color: s.hairline)),
      child: Text('封存 · 唯讀',
          style:
              UepText.mono(size: 8.5, color: s.inkMute, letterSpacing: 1.4)),
    );
  }
}

/// Objective 清單上的狀態徽章。
///
/// ⚠️ **只有需要人類動一下的兩個狀態是金色**（`review`／`verified`），
/// 其餘一律中性。金色在這塊板上等於「這件事在等你」，濫用它就等於沒有。
class _ObjectiveBadge extends StatelessWidget {
  const _ObjectiveBadge({required this.label, this.gold = false});

  final String label;
  final bool gold;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final color = gold ? UepColors.gold : s.inkSoft;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(
            color: gold
                ? UepColors.gold.withValues(alpha: .45)
                : s.hairlineStrong),
      ),
      child: Text(label,
          style: UepText.mono(size: 8, color: color, letterSpacing: 1.1)),
    );
  }
}

/// 2px 的進度條。滿格用一條線講完「還剩多少」，不佔垂直空間。
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.ratio, required this.color});

  final double ratio;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 2,
      child: Row(children: [
        Expanded(
          flex: (ratio.clamp(0, 1) * 1000).round(),
          child: ColoredBox(color: color),
        ),
        Expanded(
          flex: 1000 - (ratio.clamp(0, 1) * 1000).round(),
          child: ColoredBox(color: context.uep.hairline),
        ),
      ]),
    );
  }
}

/// 3px 的分隔圓點。
class _Dot extends StatelessWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 3,
        height: 3,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}

/// 頁首上的動作。[bordered] 的那種是主要動作（設計稿只有「＋ 新週期」是）。
class _HeaderAction extends StatelessWidget {
  const _HeaderAction({
    required this.label,
    required this.onTap,
    this.bordered = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool bordered;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: bordered
            ? const EdgeInsets.symmetric(horizontal: 11, vertical: 5)
            : EdgeInsets.zero,
        decoration: bordered
            ? BoxDecoration(border: Border.all(color: s.hairline))
            : null,
        child: Text(label,
            style: UepText.mono(
                size: 9.5, color: s.inkSoft, letterSpacing: 1.3)),
      ),
    );
  }
}

/// SUPERVISOR 膠囊。它是「誰在收這塊板的摘要」，不是一個動作，所以不可點。
///
/// Hub 目前只給名字（沒有 kind），所以那顆點是中性的——**不要拿名字去猜種類**，
/// 猜錯的話它會用別人的顏色說「他是 claude」。
class _SupervisorPill extends StatelessWidget {
  const _SupervisorPill({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: s.hairline),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text('◎', style: UepText.mono(size: 9, color: s.inkSoft)),
        const SizedBox(width: 8),
        Text('SUPERVISOR · ${name.toUpperCase()}',
            style:
                UepText.mono(size: 9, color: s.inkSoft, letterSpacing: 1.2)),
      ]),
    );
  }
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
