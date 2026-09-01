import 'package:flutter/foundation.dart';

/// Board（共同任務板）的三層資料模型與本機增量快取。
///
/// 契約見 `docs/BOARD_DESIGN.md`：Objective（一個週期）1—N Checklist
/// （階段分組）1—N Task（一個人做得完的一件事）。
///
/// ⚠️ **軟刪除的列會照樣從 Hub 回傳**（帶 `deleted: true`），那是 tombstone。
/// 增量讀取的 client 若把它們當成一般資料塞進快取，board 上會留著一批已經
/// 不存在的卡；若直接忽略，那些卡同樣不會消失。正確作法是**收到就從快取
/// 移除**，見 [BoardSnapshot.merge]。

/// Objective：一個週期。可以有多條並行。
@immutable
class BoardObjective {
  const BoardObjective({
    required this.id,
    required this.roomId,
    required this.title,
    required this.boardSeq,
    this.description = '',
    this.status = 'active',
    this.orderIndex = 0,
    this.createdBy,
    this.reviewedBy,
    this.reviewedAt,
    this.verifiedBy,
    this.verifiedAt,
    this.completedBy,
    this.completedAt,
    this.deleted = false,
    this.createdAt = '',
  });

  final String id;
  final String roomId;
  final String title;
  final String description;

  /// active / review / verified / done / cancelled
  ///
  /// `review` 與 `verified` 是兩件事：前者是「該做的都做完了」（機器判得
  /// 出來），後者是「確認過沒問題」（只有人判得出來）。
  final String status;
  final int orderIndex;
  final String? createdBy;

  /// 送審者。確認者不得與他是同一個人——**但只在他是 agent 時**
  /// （見設計文件 §1.5 的閘 4 與 Q8）。
  final String? reviewedBy;
  final String? reviewedAt;
  final String? verifiedBy;
  final String? verifiedAt;
  final String? completedBy;
  final String? completedAt;
  final bool deleted;
  final int boardSeq;
  final String createdAt;

  bool get isOpen => status == 'active' || status == 'review';
  bool get isVerified => status == 'verified' || status == 'done';

  factory BoardObjective.fromJson(Map<String, dynamic> json) => BoardObjective(
    id: json['id'] as String,
    roomId: (json['room_id'] as String?) ?? '',
    title: (json['title'] as String?) ?? '',
    description: (json['description'] as String?) ?? '',
    status: (json['status'] as String?) ?? 'active',
    orderIndex: (json['order_index'] as int?) ?? 0,
    createdBy: json['created_by'] as String?,
    reviewedBy: json['reviewed_by'] as String?,
    reviewedAt: json['reviewed_at'] as String?,
    verifiedBy: json['verified_by'] as String?,
    verifiedAt: json['verified_at'] as String?,
    completedBy: json['completed_by'] as String?,
    completedAt: json['completed_at'] as String?,
    deleted: (json['deleted'] as bool?) ?? false,
    boardSeq: (json['board_seq'] as int?) ?? 0,
    createdAt: (json['created_at'] as String?) ?? '',
  );
}

/// Hub 給 loose task 用的收納層名稱。兩邊寫死同一個字串是刻意的：
/// 它是 Hub 找回同一格的鍵，不是可翻譯的文案。
const kUncategorisedTitle = '未分類';

/// Checklist：Objective 底下的階段分組（「Hub 端」「App 端」「測試與除錯」）。
///
/// **不是驗收條件清單**——這點在需求原文裡有歧義，已由艾斯維爾拍板
/// （設計文件 Q3）。
@immutable
class BoardChecklist {
  const BoardChecklist({
    required this.id,
    required this.roomId,
    required this.objectiveId,
    required this.title,
    required this.boardSeq,
    this.description = '',
    this.status = 'open',
    this.orderIndex = 0,
    this.createdBy,
    this.completedBy,
    this.completedAt,
    this.deleted = false,
    this.createdAt = '',
  });

  final String id;
  final String roomId;
  final String objectiveId;
  final String title;
  final String description;

  /// open / done / cancelled
  final String status;
  final int orderIndex;
  final String? createdBy;
  final String? completedBy;
  final String? completedAt;
  final bool deleted;
  final int boardSeq;
  final String createdAt;

  bool get isDone => status == 'done';

  /// Hub 為「隨手記一件事」備妥的收納層（`POST .../board/tasks`）。
  ///
  /// 名字是固定的——**固定才找得回同一個**，每次新建的話板上會長出一排
  /// 空殼。畫面把這一層藏起來（艾斯維爾裁決）：它不是使用者安排出來的
  /// 階段，是系統為了滿足三層結構而墊的一格。
  bool get isUncategorised => title == kUncategorisedTitle;

  factory BoardChecklist.fromJson(Map<String, dynamic> json) => BoardChecklist(
    id: json['id'] as String,
    roomId: (json['room_id'] as String?) ?? '',
    objectiveId: (json['objective_id'] as String?) ?? '',
    title: (json['title'] as String?) ?? '',
    description: (json['description'] as String?) ?? '',
    status: (json['status'] as String?) ?? 'open',
    orderIndex: (json['order_index'] as int?) ?? 0,
    createdBy: json['created_by'] as String?,
    completedBy: json['completed_by'] as String?,
    completedAt: json['completed_at'] as String?,
    deleted: (json['deleted'] as bool?) ?? false,
    boardSeq: (json['board_seq'] as int?) ?? 0,
    createdAt: (json['created_at'] as String?) ?? '',
  );
}

/// Task 狀態機，**Hub `TASK_TRANSITIONS`（`app.py`）的鏡像**。
///
/// 這份副本存在的理由只有一個：畫面必須在使用者按下去**之前**就知道要出
/// 哪幾顆按鈕，而 `allowed` 要等 409 回來才拿得到。副本的代價是它會與 Hub
/// 各自演化，所以它被一條契約測試釘著——那條測試直接讀 `app.py` 的表來比
/// 對，兩邊不一致就紅。**沒有那條測試的話這份表不該存在。**
///
/// 曾經缺的那一格是 `todo → in_progress`：App 心裡是三態（待辦／完成／
/// 卡住），Hub 是五態，而 `in_progress` 是通往 `done` 的唯一樞紐。中間那格
/// 沒被畫出來的結果是使用者完全無法把一張卡做完。
const kTaskTransitions = <String, Set<String>>{
  'todo': {'in_progress', 'cancelled'},
  'in_progress': {'blocked', 'done', 'cancelled'},
  'blocked': {'in_progress', 'cancelled'},
  'done': {'in_progress'},
  'cancelled': {'todo'},
};

/// 抽屜底部的一顆動作按鈕。
///
/// 標籤依**來源狀態**而定，不是依目標狀態：同樣是推去 `in_progress`，
/// 從 `todo` 是「開始」、從 `blocked` 是「解除卡住」、從 `done` 是
/// 「重新開啟」。三句話講的是三件不同的事。
class TaskAction {
  const TaskAction(this.label, this.target,
      {this.danger = false, this.trailing = false});

  final String label;

  /// 要把 Task 推去的狀態。必在 [kTaskTransitions] 允許的集合裡。
  final String target;

  /// 破壞性動作（紅色）。
  final bool danger;

  /// 靠右擺——「取消」與其他動作之間要有距離，不然會被誤按。
  final bool trailing;
}

/// 某個狀態下該出哪幾顆按鈕。
///
/// ⚠️ **不可以憑「還沒收尾就全部出」來決定**——那正是舊版的寫法，它讓
/// `todo` 長出「標記完成」、`blocked` 長出「標記完成」、`done` 長出打回
/// `todo`，四顆按下去只會拿 409。
///
/// [allowed] 給的是 Hub 在 409 裡回的實際可去狀態；有它就以它為準，讓畫面
/// 在副本漂移時自己修正回來。
List<TaskAction> taskActionsFor(String status, {Set<String>? allowed}) {
  final actions = _kTaskActions[status] ?? const <TaskAction>[];
  if (allowed == null) return actions;
  return actions.where((a) => allowed.contains(a.target)).toList();
}

const _kTaskActions = <String, List<TaskAction>>{
  'todo': [
    TaskAction('開始', 'in_progress'),
    TaskAction('取消任務', 'cancelled', danger: true, trailing: true),
  ],
  'in_progress': [
    TaskAction('標記完成', 'done'),
    TaskAction('標記卡住', 'blocked', danger: true),
    TaskAction('取消任務', 'cancelled', danger: true, trailing: true),
  ],
  'blocked': [
    TaskAction('解除卡住', 'in_progress'),
    TaskAction('取消任務', 'cancelled', danger: true, trailing: true),
  ],
  // 打回與復原限人類。這個畫面本身跑在人類的 App 上，所以按鈕在
  'done': [TaskAction('重新開啟', 'in_progress')],
  'cancelled': [TaskAction('復原', 'todo')],
};

/// Task 卡片左側色軸的五種樣子（設計稿 artboard 02）。
///
/// ⚠️ 它**只描述認領那一維**。狀態（待辦／進行中／卡住／完成）走徽章，
/// 兩者不可以互相污染——孤兒卡的狀態徽章必須維持原樣，因為「變的是人不是
/// 進度」，那件事確實做到一半。
enum ClaimAxis {
  /// 中性線色：沒有人。
  none,

  /// 半透明：有人被指名（assignee），但還沒有人站上去。
  suggested,

  /// 實色（持有者的 kind 色）：現任持有者還在房裡。
  held,

  /// 斷開 + 名字劃掉：持有者已經不在房內。
  orphaned,

  /// 無軸、收合成單行：事情結束，誰做的退成註記。
  completed,
}

/// Task：葉節點，一個人做得完的一件事。
///
/// **認領與狀態是兩個獨立維度**：[status] 描述「這件事進行到哪」，
/// `claim*` 描述「誰在這張卡上」。把認領塞進 status 的話，持有者被 sweeper
/// 掃出房間、卡片打回 todo 之後，一張做到一半的卡會跟沒人碰過的長得一模一樣。
@immutable
class BoardTask {
  const BoardTask({
    required this.id,
    required this.roomId,
    required this.checklistId,
    required this.title,
    required this.boardSeq,
    this.description = '',
    this.status = 'todo',
    this.orderIndex = 0,
    this.priority = 'normal',
    this.claimParticipantId,
    this.claimSessionKey = '',
    this.claimName = '',
    this.claimKind = '',
    this.claimState = '',
    this.claimedAt,
    this.orphanedAt,
    this.orphanedReason = '',
    this.sourceSeq,
    this.assigneeParticipantId,
    this.assignedBy,
    this.assignedByName = '',
    this.createdBy,
    this.createdByName = '',
    this.completedBy,
    this.completedAt,
    this.deleted = false,
    this.createdAt = '',
  });

  final String id;
  final String roomId;
  final String checklistId;
  final String title;
  final String description;

  /// todo / in_progress / blocked / done / cancelled
  final String status;
  final int orderIndex;

  /// low / normal / high
  final String priority;

  final String? claimParticipantId;

  /// 持有者的 session_key。participant_id 跨世代會變，這個才是 agent 的持久
  /// 身分——「這是你上一世領的」認得出來靠的是它。
  final String claimSessionKey;

  /// 認領當下的 display_name。持有者離場之後 participant 查不回名字，
  /// 而「上一個是誰在做」正是接手的人最需要知道的一件事。
  final String claimName;

  /// 認領當下的 kind（claude / codex / human / other）。與 [claimName] 同一個
  /// 理由存快照：持有者離場後 participant 查不回種類，而卡片要畫他的色軸。
  final String claimKind;

  /// ''（未認領）/ held（持有中）/ orphaned（持有者已不在房內）
  final String claimState;
  final String? claimedAt;
  final String? orphanedAt;

  /// 為什麼不在了：idle / left / kicked / subagent。
  /// **只有離場的當下知道**，事後查不回來。
  final String orphanedReason;

  /// 來源訊息的房內 seq。存 seq 不存 message id——訊息可以被軟刪除，seq 不會。
  final int? sourceSeq;

  /// 人類指定的執行者。**是建議不是鎖**：認領仍要對方自己來，
  /// 否則指派一個沒醒著的 agent 就會讓那張卡永遠不動。
  final String? assigneeParticipantId;

  /// 誰指定的（設計稿：「Swift-Falcon　奈留指定 · 建議」）。
  final String? assignedBy;
  final String assignedByName;

  final String? createdBy;

  /// 建立者的名字快照。**建立者常常是 subagent**——回收之後那一列可能整個
  /// 不在了，這是所有 participant 參照裡最先斷的一種。
  final String createdByName;

  final String? completedBy;
  final String? completedAt;
  final bool deleted;
  final int boardSeq;
  final String createdAt;

  /// 卡片左側色軸該畫成哪一種。
  ///
  /// 設計的核心是**「色軸講誰，徽章講到哪」**——認領與狀態是兩個正交的維度，
  /// 各走各的視覺通道。把它放進 model 而不是 widget，是因為這個對應本身就是
  /// 規格（設計稿 artboard 02 的五種組合），而不是畫面的實作細節。
  ClaimAxis get axis {
    // 🔴 已收尾的卡**不該同時是孤兒**——一張完成的卡「沒有人在上面」不是
    // 問題，它不需要有人。Hub 的孤兒化若沒排除 done/cancelled 就會產出這個
    // 組合，而它的 claim CAS **有**排除 ⇒ Hub 自己造出一個它自己拒絕的狀態
    // （2026-09-01 F6，`reclaimable_tasks` 因此會建議認回一張領不回來的卡）。
    //
    // ⚠️ 底下的判斷順序讓這個矛盾在畫面上**看不出來**（completed 先中），
    // 那是防禦性優先序的副作用：**下游處理得越漂亮，上游的錯誤越安靜**。
    // 用 assert 把它叫出來——debug build 會炸、release build 整段被移除，
    // 所以開發時抓得到、使用者不會看到任何東西。代價是零。
    assert(
      !((isDone || status == 'cancelled') && isOrphaned),
      '這張卡同時是「已收尾」與「孤兒」：id=$id status=$status '
      'claim_state=$claimState。Hub 的孤兒化沒有排除已收尾的卡（F6）。'
      'UI 這側會顯示成 completed，但那是遮蔽不是修正——根本解在 Hub。',
    );
    if (isDone || status == 'cancelled') return ClaimAxis.completed;
    if (isOrphaned) return ClaimAxis.orphaned;
    if (isHeld) return ClaimAxis.held;
    if (assigneeParticipantId != null) return ClaimAxis.suggested;
    return ClaimAxis.none;
  }

  /// 孤兒的成因，給人讀的一句話。空字串表示 Hub 沒給（舊資料）——
  /// 那時只說「已不在房內」，不要猜。
  String get orphanedReasonLabel => switch (orphanedReason) {
    'idle' => '因閒置移出',
    'left' => 'session 已結束',
    'kicked' => '被移出聊天室',
    'subagent' => '子代理已回收',
    _ => '',
  };

  bool get isHeld => claimState == 'held';

  /// 持有者已經不在房裡了。這是 board 上**最需要被人看到**的一種卡：
  /// 它看起來有人在做，實際上沒有。
  bool get isOrphaned => claimState == 'orphaned';

  /// 還能不能被認領。`orphaned` 也算——持有者已經不在房內，就不算「同時」。
  bool get isClaimable =>
      (claimState.isEmpty || isOrphaned) &&
      status != 'done' &&
      status != 'cancelled';

  bool get isDone => status == 'done';

  /// 已經有結論了（完成或取消）。收尾的閘看的是這個，不是只看 done——
  /// 取消不是失敗，它同樣是一個結論。
  bool get isSettled => status == 'done' || status == 'cancelled';

  factory BoardTask.fromJson(Map<String, dynamic> json) => BoardTask(
    id: json['id'] as String,
    roomId: (json['room_id'] as String?) ?? '',
    checklistId: (json['checklist_id'] as String?) ?? '',
    title: (json['title'] as String?) ?? '',
    description: (json['description'] as String?) ?? '',
    status: (json['status'] as String?) ?? 'todo',
    orderIndex: (json['order_index'] as int?) ?? 0,
    priority: (json['priority'] as String?) ?? 'normal',
    claimParticipantId: json['claim_participant_id'] as String?,
    claimSessionKey: (json['claim_session_key'] as String?) ?? '',
    claimName: (json['claim_name'] as String?) ?? '',
    claimKind: (json['claim_kind'] as String?) ?? '',
    claimState: (json['claim_state'] as String?) ?? '',
    claimedAt: json['claimed_at'] as String?,
    orphanedAt: json['orphaned_at'] as String?,
    orphanedReason: (json['orphaned_reason'] as String?) ?? '',
    sourceSeq: json['source_seq'] as int?,
    assigneeParticipantId: json['assignee_participant_id'] as String?,
    assignedBy: json['assigned_by'] as String?,
    assignedByName: (json['assigned_by_name'] as String?) ?? '',
    createdBy: json['created_by'] as String?,
    createdByName: (json['created_by_name'] as String?) ?? '',
    completedBy: json['completed_by'] as String?,
    completedAt: json['completed_at'] as String?,
    deleted: (json['deleted'] as bool?) ?? false,
    boardSeq: (json['board_seq'] as int?) ?? 0,
    createdAt: (json['created_at'] as String?) ?? '',
  );
}

/// 可以撿回來的孤兒 Task（同一把 session_key 上一世領走的）。
///
/// **不自動認回**——agent 重啟多半是上一輪出事了，自動把一份它已經完全沒有
/// 記憶的工作扛回身上，board 會顯示「有人在做」而實際上沒有。
@immutable
class ReclaimableTask {
  const ReclaimableTask({
    required this.id,
    required this.title,
    this.orphanedAt,
    this.claimName = '',
  });

  final String id;
  final String title;
  final String? orphanedAt;
  final String claimName;

  factory ReclaimableTask.fromJson(Map<String, dynamic> json) =>
      ReclaimableTask(
        id: json['id'] as String,
        title: (json['title'] as String?) ?? '',
        orphanedAt: json['orphaned_at'] as String?,
        claimName: (json['claim_name'] as String?) ?? '',
      );
}

/// Hub 一次增量回應的原始內容。
@immutable
class BoardDelta {
  const BoardDelta({
    required this.boardSeq,
    this.full = false,
    this.objectives = const [],
    this.checklists = const [],
    this.tasks = const [],
    this.reclaimable = const [],
    this.supervisor,
  });

  /// 這次的水位。下次帶著它當 `after_board_seq`。
  final int boardSeq;

  /// 這是全量（`after_board_seq=0` 的回應），不是增量。
  final bool full;

  final List<BoardObjective> objectives;
  final List<BoardChecklist> checklists;
  final List<BoardTask> tasks;
  final List<ReclaimableTask> reclaimable;
  final String? supervisor;

  factory BoardDelta.fromJson(Map<String, dynamic> json) => BoardDelta(
    boardSeq: (json['board_seq'] as int?) ?? 0,
    full: (json['full'] as bool?) ?? false,
    objectives: ((json['objectives'] as List?) ?? const [])
        .map((e) => BoardObjective.fromJson(e as Map<String, dynamic>))
        .toList(),
    checklists: ((json['checklists'] as List?) ?? const [])
        .map((e) => BoardChecklist.fromJson(e as Map<String, dynamic>))
        .toList(),
    tasks: ((json['tasks'] as List?) ?? const [])
        .map((e) => BoardTask.fromJson(e as Map<String, dynamic>))
        .toList(),
    reclaimable: ((json['reclaimable_tasks'] as List?) ?? const [])
        .map((e) => ReclaimableTask.fromJson(e as Map<String, dynamic>))
        .toList(),
    supervisor: json['supervisor'] as String?,
  );
}

/// Board 入口要顯示的東西。
@immutable
class BoardEntryHint {
  const BoardEntryHint({this.label = '', this.needsYou = false});

  /// 接在「❖ Board」後面的那一小段。空字串＝平常，板上沒有需要你的東西。
  final String label;

  /// 點亮。**只給「需要你動手、而且只有你能動」的那一種。**
  final bool needsYou;
}

/// 本機的 board 快取。不可變——每次合併產生一份新的。
@immutable
class BoardSnapshot {
  const BoardSnapshot({
    this.boardSeq = 0,
    this.objectives = const {},
    this.checklists = const {},
    this.tasks = const {},
    this.reclaimable = const [],
    this.supervisor,
  });

  /// 已經套用到哪個水位。**下次請求帶這個值**。
  final int boardSeq;

  final Map<String, BoardObjective> objectives;
  final Map<String, BoardChecklist> checklists;
  final Map<String, BoardTask> tasks;
  final List<ReclaimableTask> reclaimable;
  final String? supervisor;

  /// 套用一次增量。三種變更各有各的處理：
  ///
  /// - **新增／修改**——直接以 id 覆蓋（Hub 回的永遠是該列的現況，不是 patch）
  /// - **刪除**——`deleted: true` 是 tombstone，**從快取移除**。留著會讓
  ///   board 上出現一張已經不存在的卡；忽略它則那張卡永遠不會消失
  ///
  /// [BoardDelta.full] 為 true 時整份取代而不是疊加——那是全量回應，
  /// 疊加會讓上一輪已經被刪除、而這次不再出現的列留在快取裡。
  BoardSnapshot merge(BoardDelta delta) {
    final objs = delta.full
        ? <String, BoardObjective>{}
        : Map<String, BoardObjective>.from(objectives);
    final lists = delta.full
        ? <String, BoardChecklist>{}
        : Map<String, BoardChecklist>.from(checklists);
    final tsks = delta.full
        ? <String, BoardTask>{}
        : Map<String, BoardTask>.from(tasks);

    for (final o in delta.objectives) {
      if (o.deleted) {
        objs.remove(o.id);
      } else {
        objs[o.id] = o;
      }
    }
    for (final c in delta.checklists) {
      if (c.deleted) {
        lists.remove(c.id);
      } else {
        lists[c.id] = c;
      }
    }
    for (final t in delta.tasks) {
      if (t.deleted) {
        tsks.remove(t.id);
      } else {
        tsks[t.id] = t;
      }
    }

    return BoardSnapshot(
      // 水位只進不退：增量回應可能因為這一輪沒有任何變更而回一個較小的值，
      // 倒退會讓下一次請求重拉已經套用過的東西
      boardSeq: delta.boardSeq > boardSeq ? delta.boardSeq : boardSeq,
      objectives: objs,
      checklists: lists,
      tasks: tsks,
      reclaimable: delta.reclaimable,
      supervisor: delta.supervisor,
    );
  }

  /// 聊天室 app bar 上那顆 Board 入口該顯示什麼（設計稿 artboard 06）。
  ///
  /// 四種狀態同一個位置，**只有「等你確認」點亮**：那是唯一需要人動手、
  /// 而且只有人能動的事。有進度、有孤兒都只是資訊——每個按鈕都在喊的話，
  /// 就沒有一個在喊了。
  ///
  /// 放進 model 而不是 widget，理由同 [BoardTask.axis]：這個優先序是規格，
  /// 畫面怎麼排都不該改變它，而且**測試要能測到它本人**而不是它的副本。
  /// 畫面上真的看得到的 Task——**計數的母體只能是這個**。
  ///
  /// 顯示側從 [sortedObjectives] 走到 [checklistsOf] 再走到 [tasksOf]，一路
  /// 濾掉了被取消的父層；計數側原本直接拿整張 tasks map 只濾 `deleted`。
  /// 兩個母體不一樣的後果不是短暫的不一致，是**穩定殘留**：app bar 永遠寫
  /// 著 N 張孤兒，而點進去永遠找不到那些卡。
  ///
  /// 父層不在快取裡的也算不可見——那條路徑畫不出來，計數卻算得到的話，
  /// 就是同一個 bug 的另一面。
  Iterable<BoardTask> get visibleTasks =>
      tasks.values.where((t) => !t.deleted && _parentAlive(t));

  bool _parentAlive(BoardTask t) {
    final c = checklists[t.checklistId];
    if (c == null || c.status == 'cancelled') return false;
    final o = objectives[c.objectiveId];
    return o != null && o.status != 'cancelled';
  }

  /// 這個週期現在能不能送審。
  ///
  /// ⚠️ **母體是 Checklist，不是 Task。** Hub 的送審閘驗的是「所有清單都收
  /// 尾了，且至少一份真的完成」（全部取消不算完成——那是「這一段不做了」）。
  /// 畫面原本數的是剩幾張 Task，兩邊數的不是同一種東西：Task 全做完而清單
  /// 還開著時，按鈕會亮，而按下去必然拿 409。
  ///
  /// [checklistsOf] 已經濾掉 cancelled，所以「非空且全部 done」與 Hub 那句
  /// 話等價。
  bool canReviewObjective(String objectiveId) {
    final o = objectives[objectiveId];
    if (o == null || o.status != 'active') return false;
    final lists = checklistsOf(objectiveId);
    return lists.isNotEmpty && lists.every((c) => c.isDone);
  }

  /// 一個週期底下所有看得到的 Task，依階段順序、再依卡片順序。
  List<BoardTask> tasksOfObjective(String objectiveId) => [
        for (final c in checklistsOf(objectiveId)) ...tasksOf(c.id),
      ];

  BoardEntryHint get entryHint {
    final live = visibleTasks;
    // ⚠️ **`review` 與 `verified` 都在等人類**，第一版只算了 review。
    // Objective 是四段（active → review → verified → done），而最後兩步
    // 都只有人類推得動：`verify` 與 `complete` 是兩個獨立的動作。
    //
    // 漏掉 verified 的後果比漏掉 review 更糟：那個週期會停在**倒數第二格**，
    // 入口不亮、沒有通知，而畫面上寫著「已確認」——看起來像收工了。
    // 不是沒人被叫醒，是畫面主動告訴你已經好了（測試端 2026-09-01 指出）。
    final review = objectives.values.where((o) => o.status == 'review').length;
    final verified = objectives.values
        .where((o) => o.status == 'verified')
        .length;
    if (review + verified > 0) {
      return BoardEntryHint(
        label: switch ((review, verified)) {
          (0, final v) => '$v 等你收尾',
          (final r, 0) => '$r 等你確認',
          _ => '${review + verified} 等你',
        },
        needsYou: true,
      );
    }
    final orphans = live.where((t) => t.isOrphaned).length;
    if (orphans > 0) return BoardEntryHint(label: '$orphans 孤兒');
    if (live.isEmpty) return const BoardEntryHint();
    final done = live.where((t) => t.isDone).length;
    return BoardEntryHint(label: '$done/${live.length}');
  }

  /// 依 `order_index` 排序的 Objective（不含已取消的）。
  List<BoardObjective> get sortedObjectives {
    final out = objectives.values.where((o) => o.status != 'cancelled').toList()
      ..sort(
        (a, b) => a.orderIndex != b.orderIndex
            ? a.orderIndex.compareTo(b.orderIndex)
            : a.createdAt.compareTo(b.createdAt),
      );
    return out;
  }

  List<BoardChecklist> checklistsOf(String objectiveId) {
    final out =
        checklists.values
            .where(
              (c) => c.objectiveId == objectiveId && c.status != 'cancelled',
            )
            .toList()
          ..sort(
            (a, b) => a.orderIndex != b.orderIndex
                ? a.orderIndex.compareTo(b.orderIndex)
                : a.createdAt.compareTo(b.createdAt),
          );
    return out;
  }

  List<BoardTask> tasksOf(String checklistId) {
    final out = tasks.values.where((t) => t.checklistId == checklistId).toList()
      ..sort(
        (a, b) => a.orderIndex != b.orderIndex
            ? a.orderIndex.compareTo(b.orderIndex)
            : a.createdAt.compareTo(b.createdAt),
      );
    return out;
  }
}
