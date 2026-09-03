import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../models/board.dart';
import '../../state/app_providers.dart';
import '../../state/board_providers.dart';
import '../../state/scratchpad_providers.dart';
import 'scratchpad_screen.dart';
import '../../state/rooms_providers.dart';
import '../../widgets/board_task_card.dart';
import '../../widgets/empty_error_states.dart';
import '../../core/errors/api_exception.dart';
import '../../widgets/kind_badge.dart';
import '../../widgets/uep_button.dart';
import 'board_action_feedback.dart';
import 'board_create_dialog.dart';
import 'board_task_drawer.dart';
import 'supervisor_panel.dart';

/// Board 全頁畫面（設計稿 artboard 01）。
///
/// **不做房內側欄**：board 是三層樹狀資料，塞進 400px 側欄會變成沒人想用的
/// 東西。全頁在既有的 ShellRoute 底下，桌面版左側房間列表仍在，切回聊天是
/// 一下的事。
///
/// 版面：左 Objective 清單／右單一 Objective 展開。Checklist 是可摺疊的垂直
/// 區段，**不是看板欄**——三層樹用欄位切會讓「這個週期還剩什麼」散在畫面各處。
class BoardScreen extends ConsumerStatefulWidget {
  const BoardScreen({super.key, this.roomId, this.boardId})
      : assert(roomId != null || boardId != null,
            '要嘛從房間進來，要嘛直接指定一塊板');

  /// 從哪間房進來的。`/boards/:id` 進來時是 null——**v2 起板可以一間房都
  /// 沒掛**，所以這裡不能是必填。
  final String? roomId;

  /// 直接指定的板（權威路由）。從房間進來時是 null，由回應解析出來。
  final String? boardId;

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
  /// 這個畫面是從 Board Library（`/boards/:id`）進來的，手上沒有房間。
  ///
  /// ⚠️ **那表示現在改不了東西**：item 的 claim／狀態／編輯端點維持 v1 形狀，
  /// 要的是 `X-Participant-Id`——而房內身分只有進過房才有。這裡不會替使用者
  /// 偷偷 join 一間房來湊：開一塊板不該有「順便把你加進某個聊天室」這種
  /// 副作用，而那件事發生時他不會知道。
  bool get _boardOnly => widget.roomId == null;

  /// 這個畫面正在看哪塊板。從房間進來時要等回應才知道——**還不知道時
  /// 不畫需要它的入口**，畫了按下去只會拿一個空 id。
  String? get _boardIdOrNull {
    if (widget.boardId != null) return widget.boardId;
    final id = _watchBoard().value?.boardId ?? '';
    return id.isEmpty ? null : id;
  }

  /// 這塊板上的動作。**兩條軸都有**：房軸帶房內身分，板軸帶 session key。
  ///
  /// 從前板軸是 null（「呼叫端自己處理」），而呼叫端處理的方式就是整片唯讀。
  BoardActions? get _actions => widget.roomId != null
      ? ref.read(boardActionsProvider(widget.roomId!))
      : (_boardIdOrNull == null
          ? null
          : ref.read(boardActionsByIdProvider(_boardIdOrNull!)));

  /// 這個畫面的板從哪條路徑拉。兩條路徑共用同一份快取（見 [BoardCache]），
  /// 所以從房間進與從 Library 進看到的是同一塊板、同一個水位。
  AsyncValue<BoardSnapshot> _watchBoard() => widget.roomId != null
      ? ref.watch(boardProvider(widget.roomId!))
      : ref.watch(boardByIdProvider(widget.boardId!));

  void _reloadBoard() => widget.roomId != null
      ? ref.invalidate(boardProvider(widget.roomId!))
      : ref.invalidate(boardByIdProvider(widget.boardId!));

  /// 這塊板現在能不能改。
  ///
  /// **從 Library 進來不再是唯讀的理由**（卡片端點認 `X-Session-Key` 之後）。
  /// 剩下的兩個來源是封存與 viewer 角色，兩者要講不同的話：前者是這段歷史
  /// 結束了，後者是這塊板上你只能看。
  BoardEditability get _editability => boardEditability(
        archived: _archived,
        role: _watchBoard().value?.myRole ?? '',
      );

  bool get _readOnly => _editability != BoardEditability.editable;

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
    final actions = _actions!;
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
    final actions = _actions!;
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
    final actions = _actions!;
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
    final async = _watchBoard();

    final body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context, async.value),
          if (_archived) _archivedNotice(context),
          Expanded(
            child: async.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              // 「你還不是這塊板的成員」**不是錯誤，是狀態**——房裡的人本來
              // 就不自動是板成員（艾斯維爾裁決 A+）。畫成紅色的錯誤 + 重試
              // 按鈕的話，看的人會一直按那顆按鈕，而它一百次都不會成功。
              error: (e, _) => e is BoardAccessException
                  ? _NotAMember(error: e)
                  : ErrorState(error: e, onRetry: () => _reloadBoard()),
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


  /// 拖曳排序。
  ///
  /// ⚠️ **只有看到完整清單時才准拖。**
  ///
  /// `reorder` 只更新傳進去的那些 id，**沒傳的卡 `order_index` 完全不動**。
  /// 所以篩選（例如「只看孤兒」）之下拖動不會弄丟任何卡，它會產生
  /// **重複而交錯的 order_index**：送出的那幾張拿到 0、1、2，畫面外那些
  /// 還停在原本的 0、1、2。之後讀出來的順序就是未定義的。
  ///
  /// 那比資料遺失更難查——**沒有任何一列是錯的，錯的是它們之間的關係**，
  /// 而畫面上只會顯得「順序怪怪的」，不像出過事。
  ///
  /// 這道守門只能在 UI：Hub 分不出「你只想動這兩張」與「你被篩選矇住了」，
  /// 而前者是合法的部分排序，擋掉它是錯的。
  /// ⚠️ 排除 `_orphansOnly` 原本只是「篩選過的清單拖曳沒有意義」，但它
  /// 同時守住了另一件事：**篩選過的清單送出去就是子集合**，而 Hub 依收到
  /// 的順序寫 order_index，沒送的保留舊值 ⇒ 兩批號碼交錯，順序變成未定義
  /// （@審核用Codex-2 #411 第 3 條）。拿掉這個條件的人要先解決那一半。
  bool get _canReorder => !_readOnly && !_orphansOnly && _boardIdOrNull != null;

  /// 把 [ids] 依 Flutter 的 old/new index 語意搬一格，然後整批送出。
  ///
  /// Hub 是整批套用（有一張不屬於這塊板就整批退回），所以這裡不做樂觀更新
  /// 之外的補償：成功就重拉，失敗就重拉——兩種情況畫面都會回到 Hub 說的
  /// 那個順序，不會停在一個只有本機看得到的排列上。
  /// [to] 是 `onReorderItem` 的語意：**移除之後**的最終位置。
  Future<void> _reorder(String kind, List<String> ids, int from, int to) =>
      _reorderIds(kind, reorderedIdsAt(ids, from, to));

  Future<void> _reorderIds(String kind, List<String> next) async {
    try {
      await ref.read(boardsApiProvider).reorder(
            _boardIdOrNull!,
            sessionKey: ref.read(appConfigProvider).deviceKey,
            kind: kind,
            ids: next,
          );
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
    _reloadBoard();
  }

  /// 畫面上只排得動一部分時用這條：[all] 是這個範疇裡的每一個 id，
  /// [movable] 是拖得動的那幾個。拖曳算在 [movable] 上，送出去的是完整順序。
  Future<void> _reorderPartial(String kind, List<String> all,
      List<String> movable, int from, int to) =>
      _reorderIds(kind, spliceOrder(all, reorderedIdsAt(movable, from, to)));

  /// 可拖曳的卡片清單。不能拖時退回原本的 Column——**不要留一個拖不動的
  /// 拖曳把手**，那比沒有把手更讓人以為壞了。
  Widget _taskList(BoardSnapshot snap, List<BoardTask> tasks) {
    if (!_canReorder || tasks.length < 2) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final t in tasks) _taskCard(snap, t)],
      );
    }
    return ReorderableListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      onReorderItem: (from, to) => _reorder(
          'task', [for (final t in tasks) t.id], from, to),
      children: [
        for (var i = 0; i < tasks.length; i++)
          ReorderableDragStartListener(
            key: ValueKey(tasks[i].id),
            index: i,
            child: _taskCard(snap, tasks[i]),
          ),
      ],
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
  /// 板自己的封存狀態。
  ///
  /// ⚠️ **不是房間的。** 曾經看的是 `roomDetailProvider` 的房狀態，那在 v2
  /// 是錯的軸：一塊板掛在 A（已封存）與 B（活著）兩間房時，從 A 進來的人
  /// 會看到一塊整片變灰、動作全收的板——**而那塊板是活的**。畫面說了一件
  /// 不成立的事，沒有任何測試或例外抓得到。
  ///
  /// 現在看 delta 的 `board.status`（Hub 在 c72c92d 補上）。
  bool get _archived => _watchBoard().value?.isArchived ?? false;

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
          boardId: _boardIdOrNull ?? '',
          task: task,
          // 抽屜不吃滿整個視窗：留一段板子看得到，才知道自己還在板上
          width: maxWidth < 480 ? maxWidth : 420,
          checklistTitle: snap.checklists[task.checklistId]?.title ?? '',
          assigneeName: _assigneeName(task),
          readOnly: _readOnly,
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
    // 沒有房就沒有成員名冊可查。指定者的名字本來就只從「現在還在房裡的
    // 人」查得到，這裡回 null 與「人已經不在了」是同一種答案
    if (widget.roomId == null) return null;
    final members = ref.read(roomDetailProvider(widget.roomId!)).value
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
    // 從 Library 進來時沒有房。標題退回板上掛著的房名——
    // ⚠️ 這是**權宜**：delta 還沒帶 board.name（已向 Hub 提，房內 #110）。
    // 欄位到了就直接顯示板名，這幾行連同 fallback 一起刪掉。
    final room = widget.roomId == null
        ? null
        : ref.watch(roomDetailProvider(widget.roomId!)).value?.room;
    final attached = snap?.liveRooms.toList() ?? const [];
    final zone = zoneForRoomId(widget.roomId ?? widget.boardId!);
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
        // 從房間進來：回得去。從 Library 進來：沒有「回去」這回事——
        // 板不屬於任何一間房，硬給一個返回目標只會把人送到他沒去過的地方
        if (widget.roomId != null) ...[
          _HeaderAction(
            label: '← 回到聊天室',
            onTap: () => context.go('/rooms/${widget.roomId}'),
          ),
          const SizedBox(width: 16),
          Container(width: 1, height: 20, color: s.hairline),
          const SizedBox(width: 16),
        ],
        Flexible(
          child: Text(
            // 板有自己的名字了（Hub c72c92d）。房名只是它還沒送到時的退路
            snap?.name.isNotEmpty == true
                ? snap!.name
                : (room?.name ??
                    (attached.isEmpty ? '任務板' : attached.first.name)),
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
        // ⚠️ **「＋ 新週期」不在這裡**，雖然設計稿把它畫在頁首右上。
        //
        // 設計稿那個位置成立的前提是右上角還有 SUPERVISOR 膠囊陪著它；實機上
        // supervisor 多半沒有指定，那顆按鈕就孤懸在一片空白的右上角，
        // 而它作用的對象（Objective 清單）在畫面的最左邊。
        //
        // 移到左欄 `OBJECTIVES` 那一行——**動作要靠近它會產生結果的地方**。
        if (_archived) ...[
          const _ArchivedBadge(),
          const SizedBox(width: 8),
        ],
        // 從 Library 進來時改不了東西。**要講出來而且要講對原因**——
        // 不講的話按鈕都在卻按不動；講成「沒有權限」的話人會去找一個
        // 不存在的權限問題
        // 掛接的聊天室。**有掛沒掛是同一個徽章的兩種文字**——它們回答的是
        // 同一個問題（這塊板現在被哪些對話用著），分成兩個元件只會讓其中
        // 一個被忘記更新（艾斯維爾 2026-09-03）。
        //
        // ⚠️ 判準是「**真的有沒有掛活著的房**」，不是「你從板軸進來」。
        // 從前那個徽章寫「唯讀 · 未從聊天室進入」，用 `_boardOnly` 判剛好
        // 成立；文案改成「未掛接聊天室」之後條件沒跟著改，它就變成一句
        // 事實上錯誤的話：板掛著兩間房，從 BOARDS 分頁進去照樣說沒掛。
        if (!_archived)
          _AttachedRoomsBadge(
            count: attached.length,
            onTap: attached.isEmpty
                ? null
                : () => _showAttachedRooms(context, attached),
          ),
        if (_editability == BoardEditability.viewer) ...[
          const SizedBox(width: 8),
          const _ViewerBadge(),
        ],
        // supervisor 只在真的有指定時出現。沒有指定就不畫一個空殼——
        // 「沒有人在收摘要」與「有人但名字讀不到」不是同一件事
        // ⚠️ **沒有指定時也要有入口**，只是換一句話。舊版只在有 supervisor
        // 時畫這顆膠囊，於是「指派一個人來看著」這件事在畫面上完全不存在
        // ——功能做了，但沒有人找得到它
        // ⚠️ **板軸不畫 SUPERVISOR。** Supervisor 是 per-room 的
        // （艾斯維爾 2026-09-03），而板軸上沒有「這一間房」可言——在這裡
        // 給一個指派入口，等於在那條契約上開一個後門，而那個後門看起來
        // 跟正門一樣。板掛三間房就有三個 supervisor，板軸要顯示的是彙整
        // （另一張票），不是一個可以指派的位置
        if (!_boardOnly && _boardIdOrNull != null) ...[
          const SizedBox(width: 8),
          _SupervisorPill(
            // 房軸站在某一間房裡，那就講**這間房**的 supervisor——
            // Supervisor 是 per-room 的，板上那個是另一回事
            name: _roomSupervisor(snap)?.displayName ??
                (widget.roomId != null ? '' : snap?.supervisor?.displayName) ??
                '',
            departed: widget.roomId != null &&
                (snap?.attachedRooms[widget.roomId!]?.supervisorDeparted ??
                    false),
            onTap: () => showSupervisorPanel(context,
                boardId: _boardIdOrNull!, roomId: widget.roomId),
          ),
        ],
      ]),
    );
  }

  /// 掛接的聊天室列表。**點一間就切過去**——那是這個清單存在的理由：
  /// 板不再屬於單一房間，「它還被哪些對話用著」只有這裡看得到。
  ///
  /// 已解除掛接的房**照樣列出來但標明**：那段歷史真的發生過，而「從來沒掛過」
  /// 與「掛過又拿掉了」是兩件事。
  Future<void> _showAttachedRooms(
      BuildContext context, List<AttachedRoom> rooms) {
    return showDialog<void>(
      context: context,
      builder: (ctx) {
        final s = ctx.uep;
        return SimpleDialog(
          backgroundColor: s.bgCard,
          title: Text('掛在這塊板上的聊天室',
              style: UepText.display(size: 17, color: s.inkTitle)),
          children: [
            for (final r in rooms)
              SimpleDialogOption(
                onPressed: r.detached
                    ? null
                    : () {
                        Navigator.of(ctx).pop();
                        context.go('/rooms/${r.id}');
                      },
                child: Row(children: [
                  Text('◫',
                      style: UepText.mono(
                          size: 10,
                          color: r.detached ? s.inkMute : s.inkSoft)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      r.name.isEmpty ? '（未命名）' : r.name,
                      style: UepText.serif(
                        size: 12.5,
                        color: r.detached ? s.inkMute : s.ink,
                      ),
                    ),
                  ),
                  // 現在站在哪一間，講出來——不然點進去會發現「怎麼沒動」
                  if (r.id == widget.roomId)
                    const MonoLabel('目前', size: 8.5, letterSpacing: 1.0),
                  if (r.detached)
                    const MonoLabel('已解除', size: 8.5, letterSpacing: 1.0),
                  if (!r.detached && r.status == 'archived')
                    const MonoLabel('封存', size: 8.5, letterSpacing: 1.0),
                ]),
              ),
          ],
        );
      },
    );
  }

  /// 這間房綁的 supervisor（板軸進來時沒有「這間房」可言 ⇒ null）。
  BoardActorRef? _roomSupervisor(BoardSnapshot? snap) =>
      widget.roomId == null
          ? null
          : snap?.attachedRooms[widget.roomId!]?.supervisor;

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
              if (!_readOnly && (_actions?.canAddObjective ?? false))
                _BarButton(
                    label: '＋ 新週期', onTap: () => _create('objective')),
            ]),
          ),
          if (_canReorder && active.length > 1)
            ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              // ⚠️ 畫面上只有 active 那幾條拖得動，但**送出去的是完整順序**。
              // 只送子集合的話，沒送的那些保留舊 order_index ⇒ 兩批號碼交錯，
              // 而沒有任何一列是錯的，錯的是它們之間的關係
              // （@開發 Novia (Hub) 2026-09-02，@審核用Codex-2 #411 第 3 條）。
              // 已完成的週期留在原位，不會被這次拖曳擠到最後
              onReorderItem: (from, to) => _reorderPartial(
                  'objective',
                  // ⚠️ 母體是**這塊板上每一個沒被刪掉的週期**，含被取消的
                  // 那些。`objectives` 走的是 sortedObjectives，那條會濾掉
                  // cancelled——送那一份的話 Hub 的全集檢查會回 409
                  // `reorder_incomplete`（Hub `510d6ed` 起），而在那之前
                  // 它是靜默的：被取消的週期保留舊 order_index，與新的
                  // 0、1、2 直接重疊
                  snap.allObjectiveIdsInOrder,
                  [for (final o in active) o.id],
                  from,
                  to),
              children: [
                for (var i = 0; i < active.length; i++)
                  ReorderableDragStartListener(
                    key: ValueKey(active[i].id),
                    index: i,
                    child: _objectiveTile(
                        context, snap, active[i], active[i].id == selected.id),
                  ),
              ],
            )
          else
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
          // 想法板放在左欄最下面：它是這塊板的**旁邊**，不是某個週期底下的
          // 東西。放進週期裡的話，「還沒想好要放哪個週期」的想法就無處可去
          // ——而那正是它存在的理由
          if (_boardIdOrNull != null) ...[
            const SizedBox(height: 26),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              child: ScratchpadSection(
                boardId: _boardIdOrNull!,
                canEdit: !_readOnly,
                // 房軸進來的就留在房軸——否則左欄會跳去 BOARDS 分頁
                roomId: widget.roomId,
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
                      onTap: _readOnly
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
              // ⚠️ **從 Library 進來時沒有房，就沒有 `_actions`。**
              // 收尾那組動作全部要走房內身分（送審／確認／完成都是），
              // 所以那時整組不畫。
              //
              // 🔴 少了這個判斷的後果不是「按鈕壞掉」，是**整頁白不出來**：
              // `_closeoutActions` 是 build 期間跑的，它第一行就 `_actions!`
              // ——null 檢查在 build 裡炸開，畫面是一整片灰，而不是任何
              // 一種空狀態（@開發Novia (除錯) 2026-09-03 的截圖）。
              if (!_boardOnly) _closeoutActions(context, o, stats),
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
    // 第二道防線。呼叫點已經擋了，但這裡再擋一次是刻意的——**在 build 裡
    // 用 `!` 的代價不是一個錯誤訊息，是整頁畫不出來**，而那種畫面不會告訴
    // 任何人是哪一行造成的
    final actions = _actions;
    if (actions == null) return const SizedBox.shrink();
    // 條件本人在 BoardSnapshot.canReviewObjective——放 model 才咬得住測試，
    // 在這裡複製一份判斷的話，測試測到的只會是那份副本
    final canReview = stats.canReview;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // 封存的板不給任何轉移——它是歷史。按鈕留著只會讓人按下去拿 409
        if (!_readOnly)
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
        // 名字的權威在板成員表，卡上那份是快照。查不到就傳 null，
        // 卡片自己退回快照——舊 Hub 與 v1 路徑都沒有 members[]
        holder: snap.memberOf(
            t.claimActorKey.isEmpty ? null : t.claimActorKey),
        onTap: () => setState(() => _openTaskId = t.id),
        isMineToReclaim: snap.reclaimable.any((r) => r.id == t.id),
        onClaim: (t.isClaimable && !_readOnly) ? () => _claim(t.id) : null,
        onRelease: (t.isHeld && !_readOnly)
            ? () => runBoardAction(
                context,
                () => _actions!
                    .release(t.id))
            : null,
        // 零掛接房的板**不支援追蹤**（裁決 #392 ③）。停用並說明原因，
        // 不是讓他追得成然後永遠等不到——「可以追但收不到」比「不能追」
        // 糟得多，前者要等到卡完成才發現，而那時他已經在等了
        onToggleWatch: _canWatch(snap) ? () => _toggleWatch(t) : null,
        watchBlockedReason: _watchBlockedReason(snap),
      );

  /// 追蹤要有落點。板上沒有任何活著的掛接房時，通知沒有地方可以送。
  bool _canWatch(BoardSnapshot snap) =>
      _boardIdOrNull != null && !snap.isArchived && snap.liveRooms.isNotEmpty;

  String _watchBlockedReason(BoardSnapshot snap) {
    if (_boardIdOrNull == null) return '';
    if (snap.isArchived) return '這塊板已經封存，追蹤不會再有任何動靜';
    if (snap.liveRooms.isEmpty) {
      // ⚠️ 講的是「這塊板沒有聊天室」，**不是「你不在房裡」**。
      // 後者是另一件事（人不在房裡時通知會留著，回來就知道），
      // 兩件事用同一句話講，人會以為自己離開房間就追蹤失效了
      return '這塊板還沒有掛接任何聊天室，通知沒有地方可以送。'
          '掛一間房上來就可以追蹤了';
    }
    return '';
  }

  Future<void> _toggleWatch(BoardTask t) async {
    final api = ref.read(watchApiProvider);
    final key = ref.read(appConfigProvider).deviceKey;
    try {
      if (t.watching) {
        await api.unwatch(_boardIdOrNull!,
            sessionKey: key, itemKind: 'task', itemId: t.id);
      } else {
        await api.watch(_boardIdOrNull!,
            sessionKey: key, itemKind: 'task', itemId: t.id);
      }
      // **不做樂觀更新。** watch/unwatch 會推進 board_seq，重拉就會拿到
      // 正確的 watching 與 watcher_count——自己先改的話，失敗時畫面會
      // 停在一個「看起來成功了」的狀態
      _reloadBoard();
      ref.invalidate(watchNoticesProvider);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

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
          _taskList(snap, tasks),
          if (!_readOnly && c.status == 'open' && loose == 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: _BarButton(
                  label: '收尾未分類',
                  onTap: () => runBoardAction(
                      context,
                      () => _actions!
                          .completeChecklist(c.id)),
                ),
              ),
            )
          else if (!_readOnly && c.status == 'open')
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

    // 取消的卡不進分母——它已經有結論了（同 BoardSnapshot.countableTasks）
    final counted =
        snap.tasksOf(c.id).where((t) => t.status != 'cancelled').toList();
    final done = counted.where((t) => t.isDone).length;
    final total = counted.length;

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
              if (!_readOnly) ...[
                // 階段的收尾。**沒有這個入口，週期就送不出審**——Hub 的送審
                // 閘驗的是 Checklist 收尾了沒，而 completeChecklist() 一直
                // 有實作、一直沒有呼叫端，於是每一份清單都永遠停在 open
                if (c.status == 'open') ...[
                  _BarButton(
                    label: '收尾階段',
                    onTap: () => runBoardAction(
                        context,
                        () => _actions!
                            .completeChecklist(c.id)),
                  ),
                  const SizedBox(width: 8),
                  _BarButton(
                    label: '取消階段',
                    onTap: () => runBoardAction(
                        context,
                        () => _actions!
                            .setChecklistStatus(c.id, 'cancelled')),
                  ),
                  const SizedBox(width: 8),
                ] else if (c.status == 'done') ...[
                  _BarButton(
                    label: '重新開啟階段',
                    onTap: () => runBoardAction(
                        context,
                        () => _actions!
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
          _taskList(snap, tasks),
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
    final palette =
        uepZonePalettes[zoneForRoomId(widget.roomId ?? widget.boardId!)]!;
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
              _readOnly
                  ? '這塊板結束時是空的。'
                  : '這塊板還是空的。\n開一條週期，把今天講定的事放進去；\n之後的三百則訊息就不會把它沖走。',
              textAlign: TextAlign.center,
              style: UepText.serif(size: 13.5, color: s.inkSoft, height: 2),
            ),
            if (!_readOnly && (_actions?.canAddObjective ?? false)) ...[
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
      // ⚠️ 分母同樣扣掉取消。這裡原本只有 `remaining` 扣、`total` 沒扣——
      // 同一個概念在同一個函式裡有兩種算法，而 `total` 是進度條的分母，
      // 於是取消過卡的週期永遠填不滿（艾斯維爾 2026-09-02）
      total: tasks.length - cancelled,
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

/// 從 Board Library 進來、手上沒有房內身分。
///
/// 與封存徽章分開是刻意的：**同樣是不能改，原因不一樣，處置也不一樣。**
/// 封存是「這段歷史結束了」，這個是「你要從掛著它的某間房進去才能動手」。
/// 講成同一句話的人會去找一個不存在的封存狀態。
class _AttachedRoomsBadge extends StatelessWidget {
  const _AttachedRoomsBadge({required this.count, this.onTap});

  final int count;

  /// null＝一間都沒掛，沒有東西可以列。**徽章還在**，只是換一句話：
  /// 「這塊板沒掛任何聊天室」本身就是要說出來的事實。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final empty = count == 0;
    return Tooltip(
      message: empty
          // **事實陳述，不是限制。** 板上的變更不會叫醒任何人（通知走房），
          // 追蹤者只能自己回來看。改是改得動的
          ? '這塊板沒有掛任何聊天室——改得動，但變更不會叫醒任何人'
          : '看看它掛在哪些聊天室上',
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(border: Border.all(color: s.hairline)),
          child: Text(
            empty ? '未掛接聊天室' : '◫ $count 間聊天室',
            style: UepText.mono(
                size: 8.5, color: s.inkMute, letterSpacing: 1.4),
          ),
        ),
      ),
    );
  }
}

/// 房裡的人打開一塊他還不是成員的板。
///
/// 這一頁存在的理由：**403 在這裡是常態而不是故障**。沒有它的話，
/// 房內成員按下 Board 按鈕會看到一個紅色的「權限不足」，而他既不知道
/// 那是正常的，也不知道下一步該找誰。
class _NotAMember extends StatelessWidget {
  const _NotAMember({required this.error});

  final BoardAccessException error;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final name = error.boardName;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('卷', style: UepText.display(size: 30, color: s.inkMute)),
            const SizedBox(height: 14),
            Text(
              name.isEmpty
                  ? '這間房掛著一塊任務板，但你還不是它的成員。'
                  : '這間房掛著《$name》，但你還不是它的成員。',
              textAlign: TextAlign.center,
              style: UepText.serif(size: 13.5, color: s.inkSoft, height: 1.8),
            ),
            const SizedBox(height: 8),
            Text(
              // 講得出「找誰」才有用。只說「沒有權限」的人會去翻設定頁
              '請板的 owner 把你加進來——'
              '在同一間房裡不會自動成為板的協作者。',
              textAlign: TextAlign.center,
              style: UepText.sans(size: 12, color: s.inkMute, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }
}

/// 你在這塊板上是 viewer。
///
/// 與「沒從聊天室進來」分開：那個從房間進去就解決了，這個不會——
/// 要板的 owner 把你升成 editor。講成同一句話的人會一直重試同一條路。
class _ViewerBadge extends StatelessWidget {
  const _ViewerBadge();

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Tooltip(
      // A+ 之後「不是板成員」是進房者的預設狀態，所以這顆徽章會從罕見
      // 變常態——它要講的是「下一步怎麼辦」，不是「你的身分是什麼」
      message: '你在這塊板上是唯讀。請板的 owner 把你設為協作者（editor）',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(border: Border.all(color: s.hairline)),
        child: Text('唯讀 · VIEWER',
            style:
                UepText.mono(size: 8.5, color: s.inkMute, letterSpacing: 1.4)),
      ),
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
  const _SupervisorPill({
    required this.name,
    required this.onTap,
    this.departed = false,
  });

  /// 現任 Supervisor 的名字。空字串＝還沒指定。
  final String name;

  /// 那個人已經離開這間房了。**退場是標記不是清空**，所以膠囊上要說得出
  /// 第三種狀態——只有「有人」與「沒人」兩種畫法時，這個情況會被畫成
  /// 「有人在看」，而實際上沒有。
  final bool departed;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final empty = name.isEmpty;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: s.hairline),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('◎',
              style: UepText.mono(
                  size: 9, color: empty ? s.inkMute : s.inkSoft)),
          const SizedBox(width: 8),
          Text(
            // 沒有指定時講「未指派」而不是留一個空的「SUPERVISOR · 」——
            // 後者看起來像名字讀不出來，而那是完全不同的一件事
            empty
                ? 'SUPERVISOR · 未指派'
                : departed
                    ? 'SUPERVISOR · ${name.toUpperCase()}（已離開）'
                    : 'SUPERVISOR · ${name.toUpperCase()}',
            style: UepText.mono(
                size: 9,
                color: empty
                    ? s.inkMute
                    : departed
                        ? UepColors.gold
                        : s.inkSoft,
                letterSpacing: 1.2),
          ),
        ]),
      ),
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
