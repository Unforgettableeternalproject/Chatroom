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

  /// 這個週期還收不收新的階段。
  ///
  /// 🔴 **不是「非 done 就收」**——`review` 與 `verified` 也不收。送審之後才
  /// 加進來的階段是 `open` 的，而閘只在送審那一刻驗過一次：週期會一路走到
  /// `done`，底下卻掛著一段從沒做完的東西。那正是這一輪在修的形狀，只是換
  /// 成上面一層。
  ///
  /// 要加就先把週期打回 `active`（「打回」那顆按鈕就在旁邊）。
  bool get acceptsNewChecklists => status == 'active';
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

  /// 還收不收新的卡。
  ///
  /// 🔴 收尾之後就不收了。送審閘驗的是 Checklist 的狀態，不是底下 Task 的
  /// 狀態 ⇒ 一份 `done` 的清單底下躺著一張 `todo` 的卡時，週期照樣送得出
  /// 去、確認得了、完成得掉：**板上寫著全部做完，實際上有一件沒做，而且
  /// 沒有任何地方會報錯。**
  ///
  /// 要往裡面加東西就先重新開啟它——讓人明確做一次那個動作，比幫他默默把
  /// 週期拖回未完成好。
  bool get acceptsNewTasks => status == 'open';

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
    this.claimActorKey = '',
    this.watcherCount = 0,
    this.watching = false,
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
  ///
  /// ⚠️ 這是**快照**。v2 之後名字的權威在 [BoardSnapshot.members]（依
  /// [claimActorKey] 查），因為同一個人在不同房可能叫不同名字，板上要
  /// 統一成最早進入的那個。查不到時才退回這份快照——它永遠都在。
  final String claimName;

  /// 持有者的持久身分（v2）。名字與別名一律拿它去 [BoardSnapshot.members]
  /// 查；**比對「是不是同一個人」只能用它**，用名字比會在改名或跨房時
  /// 靜默判錯。
  final String claimActorKey;

  /// 有幾個人在等這張卡。**認領者該知道自己卡住了誰**——這個數字不放在
  /// 卡上的話，那件事就只有追蹤者自己知道。
  final int watcherCount;

  /// 我自己在不在追蹤。按鈕的狀態靠它，不靠本機記憶——本機記的那份在
  /// 換裝置、重開 App 之後就不對了，而按鈕會顯示成錯的那一邊。
  final bool watching;

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
    claimActorKey: (json['claim_actor_key'] as String?) ?? '',
    watcherCount: (json['watcher_count'] as int?) ?? 0,
    watching: (json['watching'] as bool?) ?? false,
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
    this.boardId = '',
    this.name = '',
    this.description = '',
    this.status = 'active',
    this.myRole = '',
    this.members = const [],
    this.objectives = const [],
    this.checklists = const [],
    this.tasks = const [],
    this.reclaimable = const [],
    this.attachedRooms = const [],
    this.directives = const [],
    this.directivesHasMore = false,
    this.supervisor,
  });

  /// 這次的水位。下次帶著它當 `after_board_seq`。
  final int boardSeq;

  /// 這是全量（`after_board_seq=0` 的回應），不是增量。
  final bool full;

  /// v2 起 Board 是獨立實體，這是它的身分。舊 Hub 不送，回空字串。
  final String boardId;

  final String name;
  final String description;

  /// **板自己的封存狀態，與房間的封存無關。** 封存的房裡照樣可以寫它掛著
  /// 的板，反過來也一樣（§10 要求兩者分開呈現）。
  final String status;

  /// owner / editor / viewer。空字串＝Hub 沒說，當唯讀處理。
  final String myRole;

  /// 板上的人。
  ///
  /// **別名掛在這裡而不是每張卡上**：同一個人出現在十張卡上時，卡上那份
  /// 會重複十次，而它們還可能不一致。卡片只帶 `actor_key`，名字與別名
  /// 一律回這裡查（[BoardSnapshot.memberOf]）。
  final List<BoardActorRef> members;

  final List<BoardObjective> objectives;
  final List<BoardChecklist> checklists;
  final List<BoardTask> tasks;
  final List<ReclaimableTask> reclaimable;

  /// 掛在這塊 Board 上的房間。`detached: true` 的是 tombstone。
  final List<AttachedRoom> attachedRooms;

  final List<BoardDirective> directives;

  /// 全量回應只帶最近 50 筆——長跑的 Board 會把回應撐爆。
  /// 為 true 時畫面上要留得出「還有更早的」，不能假裝這就是全部。
  final bool directivesHasMore;

  final BoardActorRef? supervisor;

  factory BoardDelta.fromJson(Map<String, dynamic> json) => BoardDelta(
    boardSeq: (json['board_seq'] as int?) ?? 0,
    full: (json['full'] as bool?) ?? false,
    boardId: (json['board_id'] as String?) ?? '',
    name: (json['name'] as String?) ?? '',
    description: (json['description'] as String?) ?? '',
    status: (json['status'] as String?) ?? 'active',
    myRole: (json['my_role'] as String?) ?? '',
    members: ((json['members'] as List?) ?? const [])
        .map((e) => BoardActorRef.fromJson(e as Map<String, dynamic>))
        .toList(),
    attachedRooms: ((json['attached_rooms'] as List?) ?? const [])
        .map((e) => AttachedRoom.fromJson(e as Map<String, dynamic>))
        .toList(),
    directives: ((json['directives'] as List?) ?? const [])
        .map((e) => BoardDirective.fromJson(e as Map<String, dynamic>))
        .toList(),
    directivesHasMore: (json['directives_has_more'] as bool?) ?? false,
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
    // v1 的 supervisor 是一個名字字串，v2 升成物件。兩種都吃——遷移期間
    // 新舊 Hub 會同時存在，只認一種等於在其中一邊靜默掉一個角色。
    supervisor: switch (json['supervisor']) {
      final Map<String, dynamic> m => BoardActorRef.fromJson(m),
      final String s when s.isNotEmpty => BoardActorRef(
        actorKey: '',
        displayName: s,
      ),
      _ => null,
    },
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
    this.boardId = '',
    this.name = '',
    this.status = 'active',
    this.myRole = '',
    this.members = const {},
    this.objectives = const {},
    this.checklists = const {},
    this.tasks = const {},
    this.reclaimable = const [],
    this.attachedRooms = const {},
    this.directives = const {},
    this.directivesHasMore = false,
    this.supervisor,
  });

  /// 已經套用到哪個水位。**下次請求帶這個值**。
  final int boardSeq;

  /// 這份快取是誰的。v2 起這才是身分，roomId 只是進來的其中一道門。
  final String boardId;

  final String name;

  /// 板自己的封存狀態。**不是房間的**。
  final String status;

  /// owner / editor / viewer。
  final String myRole;

  /// actor_key → 這個人在板上的身分（含別名）。
  final Map<String, BoardActorRef> members;

  final Map<String, BoardObjective> objectives;
  final Map<String, BoardChecklist> checklists;
  final Map<String, BoardTask> tasks;
  final List<ReclaimableTask> reclaimable;
  final Map<String, AttachedRoom> attachedRooms;
  /// board_seq → directive。**沒有 id 可用**，見 [BoardDirective.boardSeq]。
  final Map<int, BoardDirective> directives;
  final bool directivesHasMore;
  final BoardActorRef? supervisor;

  /// 還掛著的房間，解除的不算。給 Board 頁「切回來源對話」用。
  Iterable<AttachedRoom> get liveRooms =>
      attachedRooms.values.where((r) => !r.detached);

  bool get isArchived => status == 'archived';
  bool get canEdit => myRole == 'owner' || myRole == 'editor';

  /// 查一個人。卡片只帶 actor_key，名字與別名都在這裡。
  BoardActorRef? memberOf(String? actorKey) =>
      actorKey == null ? null : members[actorKey];

  /// 稽核串由新到舊。
  List<BoardDirective> get sortedDirectives =>
      directives.values.toList()..sort((a, b) => b.boardSeq.compareTo(a.boardSeq));

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
    final rooms = delta.full
        ? <String, AttachedRoom>{}
        : Map<String, AttachedRoom>.from(attachedRooms);
    final dirs = delta.full
        ? <int, BoardDirective>{}
        : Map<int, BoardDirective>.from(directives);

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
    // detached 與 deleted 同語意：收到就移除。留著會殘留一間早已解除的房，
    // 而使用者點下去才會發現——那時已經沒有任何線索指出是快取的問題。
    for (final r in delta.attachedRooms) {
      if (r.detached) {
        rooms.remove(r.id);
      } else {
        rooms[r.id] = r;
      }
    }
    for (final d in delta.directives) {
      dirs[d.boardSeq] = d;
    }

    return BoardSnapshot(
      // 水位只進不退：增量回應可能因為這一輪沒有任何變更而回一個較小的值，
      // 倒退會讓下一次請求重拉已經套用過的東西
      boardSeq: delta.boardSeq > boardSeq ? delta.boardSeq : boardSeq,
      // 舊 Hub 不送 board_id，這時保留手上那份而不是覆蓋成空字串
      boardId: delta.boardId.isNotEmpty ? delta.boardId : boardId,
      // 中繼資料只在有送時覆蓋。增量回應不重送這些欄位，跟著覆蓋成空字串
      // 的話頁首會在第二次拉取後突然變成無名的板
      name: delta.name.isNotEmpty ? delta.name : name,
      status: delta.status.isNotEmpty ? delta.status : status,
      myRole: delta.myRole.isNotEmpty ? delta.myRole : myRole,
      members: delta.members.isEmpty
          ? members
          : {for (final m in delta.members) m.actorKey: m},
      objectives: objs,
      checklists: lists,
      tasks: tsks,
      reclaimable: delta.reclaimable,
      attachedRooms: rooms,
      directives: dirs,
      // 只在全量回應時重設：增量沒有「還有更早的」這個概念，
      // 讓它跟著增量歸零會把已知的截斷事實抹掉
      directivesHasMore: delta.full ? delta.directivesHasMore : directivesHasMore,
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

  /// 進度的母體：**看得見、而且還算數的卡**。
  ///
  /// 與 [visibleTasks] 差在取消的那些——它們畫面上還在（取消是一個結論，
  /// 不是刪除，看得到才知道那件事被放棄了），但**不進任何分母**。
  ///
  /// 留在分母裡的後果不只是數字難看：活著的卡全部做完之後進度永遠差一截，
  /// 而畫面不會解釋為什麼，看起來像卡住了，實際上已經收工
  /// （艾斯維爾 2026-09-02）。
  ///
  /// ⚠️ 四個地方共用這一個母體（兩個入口 badge、階段標題、週期進度條）。
  /// 各算各的話，總有一天只有其中一個被修好——`_statsOf` 的 `remaining`
  /// 早就扣掉了取消，而同一個函式裡的 `total` 沒有，就是這麼來的。
  Iterable<BoardTask> get countableTasks =>
      visibleTasks.where((t) => t.status != 'cancelled');

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
    final live = countableTasks;
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

  /// 封存房的入口：**板是歷史，只報進度，不喊人**。
  ///
  /// [entryHint] 的「等你確認」在這裡是一句做不到的話——封存房的板整塊唯讀，
  /// 那顆按鈕根本不存在。點亮一個永遠按不動的入口，比不點亮更糟：它會讓人
  /// 一直進去找那件要做的事。
  BoardEntryHint get archivedEntryHint {
    final live = countableTasks;
    if (live.isEmpty) return const BoardEntryHint();
    return BoardEntryHint(
        label: '${live.where((t) => t.isDone).length}/${live.length}');
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

  /// 手上一張卡都沒有。
  ///
  /// ⚠️ 與「水位是 0」**不是同一件事**，而那個差別正是空白畫面的來源：
  /// 水位大於 0 表示「我已經讀到那裡了」，於是下一次只要增量——但如果
  /// 內容是空的，那個增量會**什麼都不回**，畫面就永遠停在空的。
  ///
  /// 這種狀態怎麼來的不只一條路（換軸、快取被清、水位跨軸沿用⋯⋯），
  /// 所以這裡不去分辨成因，只認那個**不變式**：
  /// **水位往前走了、手上卻一張卡都沒有，是一個不該存在的狀態。**
  bool get hasNoItems =>
      objectives.isEmpty && checklists.isEmpty && tasks.isEmpty;

  /// 下一次該從哪裡要增量。
  ///
  /// 手上沒有任何卡就從 0 要（＝全量）。真的空板重拉一次全量是免費的
  /// （回來還是空的）；而拿著一個高水位空等，畫面會**永遠**是空的，
  /// 且不報錯——那正是 2026-09-03 艾斯維爾看到的那個畫面。
  int get resumeFrom => hasNoItems ? 0 : boardSeq;

  /// 排序要送的那一份：**這塊板上每一個沒被刪掉的週期**，照目前順序。
  ///
  /// ⚠️ 與 [sortedObjectives] 差在**含被取消的**。顯示側不該看到它們，但
  /// 排序的母體是「同層 siblings」，而 Hub 眼中被取消的週期仍然是一個
  /// sibling（它只排除 deleted）。少送的話：Hub `510d6ed` 起回 409
  /// `reorder_incomplete`；在那之前更糟——那些卡保留舊的 order_index，
  /// 與新的 0、1、2 直接重疊，**沒有任何一列是錯的，錯的是它們之間的關係**。
  List<String> get allObjectiveIdsInOrder {
    final out = objectives.values.toList()
      ..sort(
        (a, b) => a.orderIndex != b.orderIndex
            ? a.orderIndex.compareTo(b.orderIndex)
            : a.createdAt.compareTo(b.createdAt),
      );
    return [for (final o in out) o.id];
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

// ─────────────────────────────────────────────────────────────────
// v2：Board 獨立於 Chatroom 之後才有的東西
// 契約定於房內 #41／#43（Hub 確認同構 + 四點微調）。
// 這些欄位舊 Hub 不會送，所有 fromJson 都必須能吃到 null。
// ─────────────────────────────────────────────────────────────────

/// 同一個 actor 在別的房間用過的名字。
///
/// 只存名字的話，hover 講得出「它還叫過這個」，卻講不出「那是哪來的」——
/// 而後者才是使用者真正在問的問題（同一個 agent 在需求房叫 A、在實作房叫 B）。
@immutable
class BoardAlias {
  const BoardAlias({
    required this.name,
    this.roomId = '',
    this.roomName = '',
    this.firstSeenAt,
  });

  final String name;
  final String roomId;

  /// 房名快照。**存的是當下的名字，不是即時查來的**——房可以被永久刪除，
  /// 而 hover 那時還是要講得出「他在哪裡叫這個名字」。同 `source_room_name`
  /// 的理由。
  final String roomName;

  final String? firstSeenAt;

  factory BoardAlias.fromJson(Map<String, dynamic> json) => BoardAlias(
    name: (json['name'] as String?) ?? '',
    roomId: (json['room_id'] as String?) ?? '',
    roomName: (json['room_name'] as String?) ?? '',
    firstSeenAt: json['first_seen_at'] as String?,
  );
}

/// Board 上的一個持久身分。
///
/// ⚠️ **身分是 `actorKey`，不是 `displayName`。** 同一個 actor 掛在多間房時
/// 名字可能不同，[displayName] 依約定取**最早進入 Board** 的那個；其餘進
/// [aliases]。要比對「是不是同一個人」只能用 actorKey，用名字比會在改名或
/// 跨房時靜默判錯。
@immutable
class BoardActorRef {
  const BoardActorRef({
    required this.actorKey,
    this.displayName = '',
    this.actorKind = 'other',
    this.role = '',
    this.aliases = const [],
  });

  final String actorKey;
  final String displayName;

  /// owner / editor / viewer。從掛接房走進來的人自動是 editor——
  /// 給 viewer 的話，房裡的人會發現自己動不了眼前這塊板，而他明明就在
  /// 這間房裡。
  final String role;

  /// human / claude / codex / other。徽章顯示種類用；
  /// 「是不是人類」從這裡推得出來，反過來推不出來。
  final String actorKind;

  final List<BoardAlias> aliases;

  bool get isHuman => actorKind == 'human';

  factory BoardActorRef.fromJson(Map<String, dynamic> json) => BoardActorRef(
    actorKey: (json['actor_key'] as String?) ?? '',
    displayName: (json['display_name'] as String?) ?? '',
    actorKind: (json['actor_kind'] as String?) ?? 'other',
    role: (json['role'] as String?) ?? '',
    aliases: ((json['aliases'] as List?) ?? const [])
        .map((e) => BoardAlias.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}

/// 掛在這塊 Board 上的一間聊天室。
///
/// ⚠️ **已解除的房照樣會回傳**（[detached] 為 true），語意同 tombstone：
/// 收到就從快取移除。Hub 若只回還掛著的那些，client 手上會殘留一間早已
/// 解除的房，而且無從發現——那是靜默失效，不是顯示瑕疵。
@immutable
class AttachedRoom {
  const AttachedRoom({
    required this.id,
    this.name = '',
    this.status = 'active',
    this.detached = false,
    this.supervisor,
    this.supervisorDeparted = false,
  });

  final String id;
  final String name;

  /// 房間自己的狀態（active / archived）。**與 Board 的封存無關**，
  /// 兩者要分開呈現：封存房裡的 Board 照樣可寫。
  final String status;

  final bool detached;

  /// **這間房**的 supervisor。每間掛接房各綁各的（艾斯維爾 2026-09-03：
  /// 「他不再是 per board 而是 per room」），所以它長在這裡而不是板上。
  final BoardActorRef? supervisor;

  /// 那個人已經離開這間房了。
  ///
  /// **退場是標記不是清空**——少了這個旗標，畫面只能二選一地畫成「有人在看」
  /// 或「沒有人」，而真相是第三種：本來是誰在看，但他已經走了。
  final bool supervisorDeparted;

  factory AttachedRoom.fromJson(Map<String, dynamic> json) {
    final sup = json['supervisor'] as Map<String, dynamic>?;
    return AttachedRoom(
      id: json['id'] as String,
      name: (json['name'] as String?) ?? '',
      status: (json['status'] as String?) ?? 'active',
      detached: (json['detached'] as bool?) ?? false,
      supervisor: sup == null ? null : BoardActorRef.fromJson(sup),
      supervisorDeparted: (sup?['departed'] as bool?) ?? false,
    );
  }
}

/// 掛接的結果。
///
/// `alreadyAttached` 為真時**不是失敗**——App 建新板走的是「先 `POST
/// /api/boards` 帶 `origin_room_id`（那時就掛好了），再回頭要求匯入成員」，
/// 所以第二次呼叫必然踩到這個狀態，而它仍然做了匯入的工作。
@immutable
class AttachOutcome {
  const AttachOutcome({
    this.alreadyAttached = false,
    this.importedMembers = const [],
  });

  final bool alreadyAttached;

  /// 這次真正被加進板的 actor_key。**已經是成員的人不在裡面**——
  /// 所以它是「新增了幾個」，不是「房裡有幾個人」。
  final List<String> importedMembers;

  factory AttachOutcome.fromJson(Map<String, dynamic> json) => AttachOutcome(
    alreadyAttached: (json['already_attached'] as bool?) ?? false,
    importedMembers: (json['imported_members'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .where((e) => e.isNotEmpty)
        .toList(growable: false),
  );
}

/// Supervisor 對正在工作的 actor 送出的判斷或建議。
///
/// 走 board_event（房內 #36 裁決的 B 案），不是聊天室訊息——所以 Supervisor
/// 不必在該 agent 的房裡，在房裡也照樣能用。
@immutable
class BoardDirective {
  const BoardDirective({
    required this.boardSeq,
    this.fromActorKey = '',
    this.fromName = '',
    this.toActorKey = '',
    this.originRoomId = '',
    this.itemKind = '',
    this.itemId = '',
    this.text = '',
    this.createdAt,
  });

  /// ⚠️ **directive 沒有自己的 id**（實測 Hub `c3773cd`）。`board_seq` 是它
  /// 唯一的識別，而那個序號在板內遞增且唯一，所以拿來當 key 是安全的——
  /// 但別在別處假設它有 uuid。
  final int boardSeq;

  /// 送的人。**平鋪兩欄，不是巢狀物件**：`from_name` 是當下的名字快照，
  /// Supervisor 可能不是板成員，查不到 `members[]` 裡去。
  final String fromActorKey;
  final String fromName;

  /// 收件者。空字串＝對整塊板講的。
  final String toActorKey;

  /// 投影到哪間房（喚醒的落點）。空字串＝沒投影出去，也就是沒人被叫醒。
  final String originRoomId;

  /// 針對哪張卡。`item_kind` 是 objective／checklist／task，兩欄都空＝
  /// 對整塊板講的。
  final String itemKind;
  final String itemId;

  final String text;
  final String? createdAt;

  factory BoardDirective.fromJson(Map<String, dynamic> json) => BoardDirective(
    boardSeq: (json['board_seq'] as int?) ?? 0,
    fromActorKey: (json['from_actor_key'] as String?) ?? '',
    fromName: (json['from_name'] as String?) ?? '',
    toActorKey: (json['to_actor_key'] as String?) ?? '',
    originRoomId: (json['origin_room_id'] as String?) ?? '',
    itemKind: (json['item_kind'] as String?) ?? '',
    itemId: (json['item_id'] as String?) ?? '',
    text: (json['text'] as String?) ?? '',
    createdAt: json['created_at'] as String?,
  );
}

/// Board Library（Boards 分頁）一張卡要的東西。
///
/// 這是 `GET /api/boards` 的列表項，**不是** [BoardSnapshot] 的精簡版——
/// Library 不載入 items，只看得到彙總數字。
@immutable
class BoardSummary {
  const BoardSummary({
    required this.id,
    this.name = '',
    this.status = 'active',
    this.attachedRoomCount = 0,
    this.liveRoomCount = 0,
    this.deliveryMode = '',
    this.taskTotal = 0,
    this.taskDone = 0,
    this.taskClaimed = 0,
    this.updatedAt,
    this.myRole = '',
    this.visibility = 'public',
  });

  final String id;
  final String name;

  /// active / archived。**Board 的封存與 room 的封存是兩件事。**
  final String status;

  final int attachedRoomCount;

  /// **還活著**的掛接房。與 [attachedRoomCount] 不同：封存的房仍然掛著，
  /// 但通知送不進去。兩個數字一樣時畫面沒差，不一樣的時候差的正是
  /// 「有沒有人會被叫醒」。
  final int liveRoomCount;

  /// `room_and_inbox` / `inbox_only`。Hub 算好的**現值**，不是事件。
  ///
  /// ⚠️ 不要自己用 `liveRoomCount == 0` 推——那是在猜 Hub 的規則，而
  /// 規則漂移的那一半沒有人在看。舊 Hub 不回這欄時是空字串，那時才退回
  /// 用房數判斷（見 [inboxOnly]）。
  final String deliveryMode;

  final int taskTotal;
  final int taskDone;
  final int taskClaimed;
  final String? updatedAt;

  /// owner / editor / viewer。空字串＝Hub 沒說，當唯讀處理。
  final String myRole;

  /// `public` / `private`。**預設 public**：舊 Hub 不回這欄時，把板當成
  /// 私人會在畫面上憑空長出一個使用者從未設定過的限制。
  final String visibility;

  bool get isPrivate => visibility == 'private';

  bool get isArchived => status == 'archived';

  /// 追蹤通知只能自己回來看，不會有人被叫醒。
  ///
  /// Hub 說了就聽 Hub 的；舊 Hub 沒說時才退回用「有沒有活著的房」推——
  /// **而且要求 `attachedRoomCount > 0`**，否則一塊全新的空板也會被標成
  /// 降級，那不是降級，是還沒開始。
  bool get inboxOnly => deliveryMode.isEmpty
      ? (attachedRoomCount > 0 && liveRoomCount == 0)
      : deliveryMode == 'inbox_only';
  bool get canEdit => myRole == 'owner' || myRole == 'editor';

  factory BoardSummary.fromJson(Map<String, dynamic> json) {
    final counts = (json['task_counts'] as Map<String, dynamic>?) ?? const {};
    return BoardSummary(
      id: json['id'] as String,
      name: (json['name'] as String?) ?? '',
      status: (json['status'] as String?) ?? 'active',
      attachedRoomCount: (json['attached_room_count'] as int?) ?? 0,
      liveRoomCount: (json['live_room_count'] as int?) ?? 0,
      deliveryMode: (json['delivery_mode'] as String?) ?? '',
      taskTotal: (counts['total'] as int?) ?? 0,
      taskDone: (counts['done'] as int?) ?? 0,
      taskClaimed: (counts['claimed'] as int?) ?? 0,
      updatedAt: json['updated_at'] as String?,
      myRole: (json['my_role'] as String?) ?? '',
      visibility: (json['visibility'] as String?) ?? 'public',
    );
  }
}

/// 這塊板現在為什麼不能改（或可以改）。
///
/// - [editable]：正常
/// - [archived]：這段歷史結束了，誰都改不了
/// - [viewer]：這塊板上你只能看
///
/// ⚠️ 曾經有第四種 `noRoom`——「從 Board Library 進來」，而它會讓整塊板
/// 唯讀。判準是**你從哪條網址進來**（`widget.roomId == null`），跟板有沒有
/// 掛房、跟你是不是 owner 都無關；於是從 BOARDS 分頁開的板進去一張卡都建
/// 不了，包括自己剛開的那塊。
///
/// 那正是艾斯維爾說的「我不認為 Board 沒有綁房間就必定是唯讀」
/// （2026-09-03）——**server 從來沒有這條規則，它長在這裡。**
/// 卡片端點認 `X-Session-Key` 之後這個狀態就沒有存在的理由了。
enum BoardEditability { editable, archived, viewer }

/// [archived] 優先於其餘：封存的板從哪裡進來、你是誰都改不了，
/// 而「從聊天室進來就能寫」這句話在封存的板上是假的。
///
/// [role] 空字串代表 **Hub 沒說**（舊 Hub 不回 `my_role`）。那時當作可以寫
/// ——舊 Hub 上本來就沒有 Board 權限這回事，判成 viewer 會讓整塊板無故
/// 唯讀，而使用者找不到任何可以改的地方。真的沒權限時 Hub 會回 403，
/// 那是誠實的失敗；預設鎖住則是無聲的。
BoardEditability boardEditability({
  required bool archived,
  String role = '',
}) {
  if (archived) return BoardEditability.archived;
  if (role == 'viewer') return BoardEditability.viewer;
  // 從哪條網址進來**不再是判準**——擋不擋得住由 Hub 的權限說了算，
  // 而那會以 role 的形式回到這裡
  return BoardEditability.editable;
}

/// 這間房到底有沒有掛板。
///
/// ⚠️ 判準是**載入完成而且沒有 board_id**，不是「快照是空的」。
/// 載入中的空快照與真的沒有板長得一模一樣，用後者判會讓聊天室的 Board
/// 入口在每次進房時先閃一下「掛接任務板」再變回來——而那一閃看起來像
/// 板被弄丟了。
///
/// [hasObjectives] 是給舊 Hub 的退路：它不回 `board_id`，但有卡就表示
/// 板是存在的。遷移期間兩種 Hub 並存，只看 board_id 會把舊 Hub 上每一間
/// 有板的房都判成未掛接。
bool boardUnattached({
  required bool loaded,
  required String boardId,
  required bool hasObjectives,
}) =>
    loaded && boardId.isEmpty && !hasObjectives;

/// 把 [ids] 依 Flutter `ReorderableListView.onReorder` 的語意搬一格。
///
/// ⚠️ **`newIndex` 是「移除之前」的插入位置**，所以往後拖時要先減一。
/// 少了那一行，往後拖永遠會多跳一格——而且只在往後拖時錯，往前拖是對的，
/// 所以隨手試一下很容易以為它好了。
///
/// 新的 `onReorderItem` 已經替我們減過了，那條走 [reorderedIdsAt]。
/// **兩個索引語意不同，是這裡分成兩個函式的唯一理由**——合成一個再靠參數
/// 決定要不要減，遲早會有人在某個呼叫點傳錯，而錯的方向只在往後拖時看得見。
List<String> reorderedIds(List<String> ids, int oldIndex, int newIndex) =>
    reorderedIdsAt(ids, oldIndex, newIndex > oldIndex ? newIndex - 1 : newIndex);

/// 把「只排得動一部分」的結果攤回**完整**的順序。
///
/// [all] 是這個範疇裡的每一個 id（含拖不動的那些），[movable] 是畫面上
/// 真的排得動的那幾個、且已經是拖曳後的順序。回傳的長度與 [all] 相同，
/// 每個 id 恰好一次。
///
/// ⚠️ **為什麼不能只送排得動的那幾個**：Hub 依收到的順序寫 `order_index`，
/// 只送子集合時，沒送的那些保留舊值 ⇒ 兩批號碼交錯，而**沒有任何一列是
/// 錯的，錯的是它們之間的關係**（@開發 Novia (Hub) 2026-09-02）。結果是
/// 一個未定義的順序，下次讀回來長什麼樣沒有人說得準。
///
/// 拖不動的那些**留在原本的位置上**，不會被擠到最後——「已完成的週期」
/// 該待在哪，不是這次拖曳要回答的問題。
List<String> spliceOrder(List<String> all, List<String> movable) {
  final slots = <int>[
    for (var i = 0; i < all.length; i++)
      if (movable.contains(all[i])) i,
  ];
  final out = [...all];
  for (var i = 0; i < slots.length && i < movable.length; i++) {
    out[slots[i]] = movable[i];
  }
  return out;
}

/// 同上，但 [newIndex] 是**移除之後**的最終位置（`onReorderItem` 的語意）。
List<String> reorderedIdsAt(List<String> ids, int oldIndex, int newIndex) {
  final out = [...ids];
  out.insert(newIndex, out.removeAt(oldIndex));
  return out;
}
