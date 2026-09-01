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
import 'board_action_feedback.dart';
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
    final result = await showBoardCreateDialog(
        context, kind: kind, parentTitle: parentTitle);
    if (result == null) return;
    await _submitCreate(kind, parentId, result);
  }

  /// 送出建立。**與對話框分開**是為了讓「重新開啟並繼續」能原樣重送一次，
  /// 而不是要人把剛剛打的字再打一遍。
  Future<void> _submitCreate(
      String kind, String? parentId, BoardCreateResult result) async {
    final actions = ref.read(boardActionsProvider(widget.roomId));
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
    } on ConflictException catch (e) {
      if (!mounted) return;
      // 收尾的容器拒收。被擋下來的人要拿得到往下走的路——Hub 在拒絕裡就
      // 附上了「哪一層擋的、要打回哪個狀態」，這裡照著它做，不自己猜：
      // 擋的可能是**祖父層**（週期已收尾、階段還開著），那時該重開的不是
      // 眼前這個階段
      final blocked = e.detail['item_id'] as String?;
      final blockedKind = e.detail['kind'] as String?;
      if (e.code == 'container_settled' && blocked != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.message),
          action: SnackBarAction(
            label: '重新開啟並繼續',
            onPressed: () =>
                _reopenAndRetry(blockedKind, blocked, kind, parentId, result),
          ),
        ));
        return;
      }
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } on ApiException catch (e) {
      // 沒有這個 catch 的話，失敗只會拋進 framework，畫面上什麼都不會發生
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  /// 把被擋下的那一層打回進行中，然後原樣重送。
  ///
  /// **重開是一個明確的動作，由人按下去**——這正是「拒收」勝過「自動打回
  /// 父層」的地方：週期被拖回未完成這件事，要有人真的決定它。
  Future<void> _reopenAndRetry(String? blockedKind, String blockedId,
      String kind, String? parentId, BoardCreateResult result) async {
    final actions = ref.read(boardActionsProvider(widget.roomId));
    // 這兩個動作都回 void，所以用旗標判成敗——`runBoardAction` 回 null 只
    // 代表「沒有值」，在 void 的情況下分不出失敗
    var reopened = false;
    await runBoardAction(context, () async {
      if (blockedKind == 'objective') {
        await actions.reopenObjective(blockedId);
      } else {
        await actions.setChecklistStatus(blockedId, 'open');
      }
      reopened = true;
    });
    // 重開自己也可能被拒（例如週期已取消）。那時 runBoardAction 已經說過
    // 話了，不要再往下送一次必然失敗的建立
    if (!reopened || !mounted) return;
    await _submitCreate(kind, parentId, result);
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
                  final board = wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              width: 300,
                              child: _objectiveList(
                                  context, snap, objectives, selected),
                            ),
                            Container(width: 1, color: s.hairline),
                            Expanded(child: detail),
                          ],
                        )
                      : detail;

                  // 🔑 **抽屜是浮起來的，不是版面裡的一欄。**
                  //
                  // 設計稿 artboard 03 畫得很清楚：抽屜底下那塊板是**被遮罩
                  // 的**（`opacity: .35`），不是被擠窄的。第一版做成 Row 的
                  // 第三欄，結果在 1267px 的視窗上中間只剩 274px——「未分類」
                  // 四個字直排成一行，30px 的標題把整欄吃光。
                  //
                  // 板的寬度**不該由抽屜開不開決定**：同一塊板在抽屜開闔之間
                  // 重排一次，讀的人會失去自己剛才在看哪一張卡。
                  return Stack(children: [
                    board,
                    ?_drawer(context, snap, c.maxWidth),
                  ]);
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
    void close() => setState(() => _openTaskId = null);
    return Positioned.fill(
      child: Row(children: [
        // 遮罩：點板子的任何地方就關掉抽屜。**它同時是那句「底下這塊還在，
        // 只是現在不是主角」**——設計稿用 opacity .35 講同一件事
        Expanded(
          child: GestureDetector(
            onTap: close,
            child: ColoredBox(
              color: Colors.black.withValues(alpha: .45),
            ),
          ),
        ),
        BoardTaskDrawer(
          roomId: widget.roomId,
          task: task,
          // 抽屜不吃滿整個視窗：留一段板子看得到，才知道自己還在板上
          width: maxWidth < 480 ? maxWidth : 420,
          checklistTitle: snap.checklists[task.checklistId]?.title ?? '',
          assigneeName: _assigneeName(task),
          readOnly: _archived,
          onClose: close,
        ),
      ]),
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
        // ⚠️ **「＋ 新週期」不在這裡**，雖然設計稿把它畫在頁首右上。
        //
        // 設計稿那個位置成立的前提是右上角還有 SUPERVISOR 膠囊陪著它；實機上
        // supervisor 多半沒有指定，那顆按鈕就孤懸在一片空白的右上角，
        // 而它作用的對象（Objective 清單）在畫面的最左邊。
        //
        // 移到左欄 `OBJECTIVES` 那一行——**動作要靠近它會產生結果的地方**。
        if (_archived) const _ArchivedBadge(),
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
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 11),
            child: Row(children: [
              Expanded(
                child: MonoLabel('OBJECTIVES · ${active.length} ACTIVE',
                    color: s.inkMute, letterSpacing: 2.2),
              ),
              if (!_archived)
                _BarButton(
                    label: '＋ 新週期', onTap: () => _create('objective')),
            ]),
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
              for (final c in checklists)
                if (c.isUncategorised)
                  _looseTasks(context, snap, c)
                else
                  _checklistSection(context, snap, c),
              // 空的時候才在這裡再給一次入口——抬頭那顆已經在了，
              // 兩顆一樣的按鈕只會讓人懷疑它們是不是不同的東西
              if (checklists.isEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text('這個週期還沒有階段。',
                      style: UepText.mono(size: 11, color: s.inkMute)),
                ),
                if (o.acceptsNewChecklists)
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
    // 條件本人在 BoardSnapshot.canReviewObjective——放 model 才咬得住測試，
    // 在這裡複製一份判斷的話，測試測到的只會是那份副本
    final canReview = stats.canReview;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // 封存的板不給任何轉移——它是歷史。按鈕留著只會讓人按下去拿 409
        if (!_archived)
        Row(mainAxisSize: MainAxisSize.min, children: [
          // 送審之後也不收——`review` / `verified` 加進來的階段是 open 的，
          // 而閘只在送審那一刻驗過一次：週期會一路走到 done，底下卻掛著一段
          // 從沒做完的東西。要加就先按「打回」
          if (o.acceptsNewChecklists) ...[
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
              onTap: canReview
                  ? () => runBoardAction(
                      context, () => actions.reviewObjective(o.id))
                  : null,
            )
          else if (o.status == 'review') ...[
            _BarButton(
                label: '打回',
                onTap: () => runBoardAction(
                    context, () => actions.reopenObjective(o.id))),
            const SizedBox(width: 8),
            _BarButton(
              label: '確認',
              accent: true,
              onTap: () => runBoardAction(
                  context, () => actions.verifyObjective(o.id)),
            ),
          ] else if (o.status == 'verified')
            _BarButton(
              label: '結束週期',
              accent: true,
              onTap: () => runBoardAction(
                  context, () => actions.completeObjective(o.id)),
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
      // 說的是**擋住送審的那件事**。原本寫「N 張未完成」，而真正擋著的是
      // 清單沒收尾——照著它做完所有卡，按鈕依然不會亮
      'active' when stats.stages == 0 => '還沒有階段，先開一個',
      'active' when stats.stagesOpen > 0 => [
          '${stats.stagesOpen} 個階段還沒收尾',
          if (stats.remaining > 0) '${stats.remaining} 張未完成',
          if (stats.orphans > 0) '${stats.orphans} 張沒有人在上面',
        ].join(' · '),
      'active' when stats.stagesDone == 0 =>
        '每個階段都被取消了，這個週期沒有東西可以驗收',
      'active' => '所有階段都收尾了，可以送審',
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

  Widget _taskCard(BoardSnapshot snap, BoardTask t) => BoardTaskCard(
        task: t,
        conflict: _conflicts[t.id],
        assigneeName: _assigneeName(t),
        onTap: () => setState(() => _openTaskId = t.id),
        isMineToReclaim: snap.reclaimable.any((r) => r.id == t.id),
        onClaim: (t.isClaimable && !_archived) ? () => _claim(t.id) : null,
        onRelease: (t.isHeld && !_archived)
            ? () => runBoardAction(
                context,
                () => ref
                    .read(boardActionsProvider(widget.roomId))
                    .release(t.id))
            : null,
      );

  /// 「未分類」那一層：**只藏中間那格，卡片平鋪在週期底下**（艾斯維爾裁
  /// 決 #13）。整個週期藏掉會讓人找不到自己隨手記的東西。
  ///
  /// 它不是使用者安排出來的階段，是 Hub 為了滿足三層結構墊的一格，所以
  /// 沒有標題列、沒有「＋ 任務」——隨手記那條路徑在聊天室裡，不在這裡。
  ///
  /// ⚠️ 唯一留下來的是收尾：它在 Hub 眼裡仍是一份 Checklist，**沒收尾就
  /// 送不出審**。藏了那一層又不給收尾的入口，週期會永遠卡在送審前一步，
  /// 而畫面上完全看不出是什麼擋著。
  Widget _looseTasks(
      BuildContext context, BoardSnapshot snap, BoardChecklist c) {
    final s = context.uep;
    var tasks = snap.tasksOf(c.id);
    if (_orphansOnly) tasks = tasks.where((t) => t.isOrphaned).toList();
    if (tasks.isEmpty) return const SizedBox.shrink();

    final loose = tasks.where((t) => !t.isSettled).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final t in tasks) _taskCard(snap, t),
          if (!_archived && c.status == 'open' && loose == 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: _BarButton(
                  label: '收尾未分類',
                  onTap: () => runBoardAction(
                      context,
                      () => ref
                          .read(boardActionsProvider(widget.roomId))
                          .completeChecklist(c.id)),
                ),
              ),
            )
          else if (!_archived && c.status == 'open')
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('未分類還有 $loose 張沒收尾，週期送不出審。',
                  style: UepText.mono(size: 9, color: s.inkMute)),
            ),
        ],
      ),
    );
  }

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
              // 收尾與否要看得見——送審擋在它上面，而卡片全綠時最容易
              // 以為已經收好了
              if (c.isDone) ...[
                const SizedBox(width: 8),
                Text('· 已收尾',
                    style: UepText.mono(
                        size: 9, color: UepColors.gold, letterSpacing: 1.4)),
              ],
              const SizedBox(width: 12),
              // 標題與動作之間拉一條線：讓每一段的抬頭在視覺上自成一列
              Expanded(child: Container(height: 1, color: s.hairline)),
              const SizedBox(width: 12),
              if (!_archived) ...[
                // 階段的收尾。**沒有這個入口，週期就送不出審**——Hub 的送審
                // 閘驗的是 Checklist 收尾了沒，而 completeChecklist() 一直
                // 有實作、一直沒有呼叫端，於是每一份清單都永遠停在 open
                if (c.status == 'open') ...[
                  _BarButton(
                    label: '收尾階段',
                    onTap: () => runBoardAction(
                        context,
                        () => ref
                            .read(boardActionsProvider(widget.roomId))
                            .completeChecklist(c.id)),
                  ),
                  const SizedBox(width: 8),
                  _BarButton(
                    label: '取消階段',
                    onTap: () => runBoardAction(
                        context,
                        () => ref
                            .read(boardActionsProvider(widget.roomId))
                            .setChecklistStatus(c.id, 'cancelled')),
                  ),
                  const SizedBox(width: 8),
                ] else if (c.status == 'done') ...[
                  _BarButton(
                    label: '重新開啟階段',
                    onTap: () => runBoardAction(
                        context,
                        () => ref
                            .read(boardActionsProvider(widget.roomId))
                            .setChecklistStatus(c.id, 'open')),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
              // 🔴 **收尾了就不再收新卡。**
              //
              // 送審閘驗的是 Checklist 的狀態，不是底下 Task 的狀態 ⇒ 一份
              // done 的清單底下躺著一張 todo 的卡時，週期照樣送得出去、
              // 確認得了、完成得掉：板上寫著全部做完，實際上有一件沒做，
              // 而且沒有任何地方會報錯。
              //
              // 這是 B4 的鏡像——那次是「母體數錯」，這次是「**收尾之後母體
              // 還會變**」。閘沒寫錯，是驗的那一刻與事實變動的那一刻之間有縫。
              //
              // 要往這裡加東西，先按旁邊那顆「重新開啟階段」。**讓人明確做一
              // 次「我要重開這一段」，比幫他默默把週期拖回未完成好**——按下
              // 「＋ 任務」的人不會預期自己撤銷了一次驗收。
              if (c.acceptsNewTasks)
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
          for (final t in tasks) _taskCard(snap, t),
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

  List<BoardTask> _tasksOf(BoardSnapshot snap, BoardObjective o) =>
      snap.tasksOfObjective(o.id);

  _Stats _statsOf(BoardSnapshot snap, BoardObjective o) {
    final checklists = snap.checklistsOf(o.id);
    final tasks = _tasksOf(snap, o);
    final done = tasks.where((t) => t.isDone).length;
    final cancelled = tasks.where((t) => t.status == 'cancelled').length;
    return _Stats(
      // 「N 階段」數的是**看得見的**那些：未分類那一格畫面上不存在，
      // 把它算進去，數字就會跟畫面對不起來（同 B3 的母體問題）
      stages: checklists.where((c) => !c.isUncategorised).length,
      // ⚠️ 收尾與送審相反，**必須含未分類**——Hub 的閘算它。排除它的話
      // 按鈕會亮而拿 409，那正是這次要修掉的形狀
      // 可見的清單都不是 cancelled，所以「不是 done」就是還開著
      stagesOpen: checklists.where((c) => !c.isDone).length,
      stagesDone: checklists.where((c) => c.isDone).length,
      canReview: snap.canReviewObjective(o.id),
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
    required this.stagesOpen,
    required this.stagesDone,
    required this.canReview,
    required this.total,
    required this.done,
    required this.remaining,
    required this.orphans,
  });

  final int stages;

  /// 還沒收尾的階段數。**送審擋在這個數字上**，不是擋在剩幾張卡上。
  final int stagesOpen;
  final int stagesDone;
  final bool canReview;
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
  const _HeaderAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.zero,
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
