import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../api/runs_api.dart';
import '../../core/errors/api_exception.dart';
import '../../l10n/l10n.dart';
import '../../models/agent_run.dart';
import '../../state/app_providers.dart';
import '../../state/rooms_providers.dart';
import '../../state/runs_providers.dart';
import 'dispatch_dialog.dart';
import 'ops_dashboard_view.dart';

/// 派工與推送的共用動作。
///
/// 入口有三個（階段、卡、儀表板），**規則只能有一份**：位置怎麼算、哪個
/// 錯誤碼要講什麼話，散在三個畫面裡就是三份會各自漂移的真相。

final _log = Logger('ops_actions');

/// 對一個階段或一張卡派工。
///
/// 回傳是不是真的建了一筆——呼叫端要據此決定要不要重新整理面板。
Future<bool> dispatchRun(
  BuildContext context,
  WidgetRef ref, {
  required String roomId,
  required String targetRef,
  required String targetLabel,
  String boardId = '',
}) async {
  final api = ref.read(runsApiProvider);
  final l10n = AppLocalizations.of(context);
  final pid = ref.read(settingsRepoProvider).participantId(roomId);
  // 送出要用的東西**全部在開對話框之前就抓好**：API、房內身分，以及講話的
  // 出口。對話框關掉時入口自己可能已經被重建或移除（階段列整列重建、卡片
  // 抽屜關掉），那時 `context` 就失效了——而**送不送 API 不可以取決於畫面
  // 還在不在**（09/17 實機：第一次派工按下去只留下一行「畫面已經不在了」，
  // 第二次才真的建單）
  final messenger = ScaffoldMessenger.maybeOf(context);

  // 專案清單要現撈。**不能用上一次面板留下的那份**：執行器的白名單會變，
  // 而拿著舊清單選出來的專案會被 Hub 以 `project_not_served` 退回，畫面上
  // 看起來像是「這個功能壞了」
  //
  // 不 await 就開對話框：撈清單期間對話框自己顯示載入中（撈完才開的話，
  // 那段等待在畫面上什麼都沒有）。這個 Future **不會失敗**——失敗收進
  // [DispatchProjects.error]，讓對話框把它講出來
  Future<DispatchProjects> loadProjects() async {
    try {
      final projects =
          (await api.dashboard(roomId, participantId: pid)).servedProjects;
      return DispatchProjects(projects: projects);
    } on ApiException catch (e) {
      _log.warning('派工的專案清單撈不到（room=$roomId）：${e.code} ${e.message}');
      return DispatchProjects(error: e.message);
    }
  }

  // 房間綁定了工作區的話，專案就不是一個選擇：Hub 對別的 key 回 409
  // `workspace_project_mismatch`。這時連清單都不必撈——那一趟的唯一用途
  // 就是把下拉填起來
  final bound = ref.read(roomDetailProvider(roomId)).value?.room.workspaceKey;

  _log.info('開啟派工對話框（room=$roomId target=$targetRef「$targetLabel」'
      '${bound == null ? '' : ' workspace=$bound'}）');
  final request = await showDispatchDialog(context,
      targetLabel: targetLabel,
      workspaceKey: bound,
      projects: bound == null
          ? loadProjects()
          : Future.value(DispatchProjects(projects: [bound])));
  if (request == null) {
    _log.info('派工對話框取消或未送出（target=$targetRef）');
    return false;
  }
  try {
    _log.info('create_run 送出：room=$roomId kind=${request.kind} '
        'project=${request.project} ref=$targetRef board=$boardId '
        'priority=${request.priority} brief=${request.brief.length} 字');
    final run = await api.create(
      roomId,
      kind: request.kind,
      project: request.project,
      ref: targetRef,
      brief: request.brief,
      boardId: boardId,
      priority: request.priority,
      participantId: pid,
    );
    _log.info('create_run 已建立：run=${run.id} status=${run.status}');
    final position = await _queuePosition(api, roomId, run.id, pid);
    _notify(messenger,
        position == null ? l10n.opsQueued : l10n.opsQueuedAt(position));
    return true;
  } on ApiException catch (e) {
    _log.warning('create_run 被退回：${e.code} ${e.message}');
    _notify(messenger, _dispatchError(l10n, e));
    return false;
  }
}

/// 把工作房綁到一個工作區 key。**一次性，綁了不能改**——確認框在按鈕那端
/// （[OpsWorkspaceSection]），這裡只負責送出與善後。
///
/// 成功之後 [roomDetailProvider] 與 [roomRunnerBoardProvider] 都要重抓：
/// 前者是「綁到哪」的真相（派工入口的條件也看它），後者的 `runners` 在綁定
/// 之前是空的——只 invalidate 一個的話，畫面會停在一個已經不成立的狀態。
Future<bool> bindRoomWorkspace(
  BuildContext context,
  WidgetRef ref, {
  required String roomId,
  required String workspaceKey,
}) async {
  final api = ref.read(roomsApiProvider);
  final l10n = AppLocalizations.of(context);
  // 送出要用的東西在畫面還在的時候就抓好——綁定區塊自己會在成功後消失
  final messenger = ScaffoldMessenger.maybeOf(context);
  final pid = ref.read(settingsRepoProvider).participantId(roomId);
  final deviceKey = ref.read(appConfigProvider).deviceKey;
  try {
    _log.info('綁定工作區送出：room=$roomId key=$workspaceKey');
    final room = await api.bindWorkspace(roomId,
        workspaceKey: workspaceKey,
        sessionKey: deviceKey,
        participantId: pid);
    ref.invalidate(roomDetailProvider(roomId));
    ref.invalidate(roomRunnerBoardProvider(roomId));
    _notify(messenger,
        l10n.opsWorkspaceBindDone(room.workspaceKey ?? workspaceKey));
    return true;
  } on ApiException catch (e) {
    _log.warning('綁定工作區被退回：${e.code} ${e.message}');
    // Hub 那幾句話（不是房主／已經綁過／沒有執行器服務）已經夠清楚，
    // 原樣用——在這裡改寫只會多一份會漂移的真相。只有一條要自己講：
    // 私人工作區綁到公開房間，下一步是**先把房間改成私人**，而那件事
    // 在另一個畫面上，錯誤碼本身看不出來
    _notify(
        messenger,
        e.code == 'workspace_private_room_required'
            ? l10n.opsErrorWorkspacePrivateRoomRequired
            : e.message);
    return false;
  }
}

/// 儀表板上的「推送」。
///
/// brief 由 [buildPushBrief] 組——**把面板上當下那份 sha 原樣帶上**，
/// 執行器會拿它跟自己看到的比對，顆數或內容對不上就拒絕（§5.6）。
Future<bool> pushRepo(
  BuildContext context,
  WidgetRef ref, {
  required String roomId,
  required String project,
  required RepoView repo,
}) async {
  final api = ref.read(runsApiProvider);
  final l10n = AppLocalizations.of(context);
  final pid = ref.read(settingsRepoProvider).participantId(roomId);
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.opsPush),
      content: Text(l10n.opsPushConfirm(
          repo.key, repo.unpushedCount, repo.branch)),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel)),
        TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.opsPush)),
      ],
    ),
  );
  if (ok != true || !context.mounted) return false;
  try {
    await api.create(
      roomId,
      // `push` 不經模型，執行器跑固定腳本（§5.6）
      kind: 'push',
      project: project,
      // push 的 ref 是 repo 名，不是 `<project>/<repo>`
      ref: repo.repoName,
      brief: buildPushBrief(repo.branch, repo.unpushed.map((c) => c.sha)),
      participantId: pid,
    );
    if (context.mounted) _say(context, l10n.opsPushQueued(repo.repoName));
    return true;
  } on ApiException catch (e) {
    if (context.mounted) _say(context, _dispatchError(l10n, e));
    return false;
  }
}

/// 取消一筆派工。
Future<bool> cancelRun(
  BuildContext context,
  WidgetRef ref, {
  required AgentRun run,
}) async {
  final api = ref.read(runsApiProvider);
  final l10n = AppLocalizations.of(context);
  final pid = ref.read(settingsRepoProvider).participantId(run.roomId);
  try {
    final done = await api.cancel(run.id,
        participantId: pid,
        sessionKey: ref.read(appConfigProvider).deviceKey);
    if (context.mounted) {
      // 🔴 兩件事要講成不一樣的話：queued 是真的停了，其餘只是把旗標立
      // 起來——那個 agent 還在對方機器上寫檔
      _say(context,
          done ? l10n.opsCancelDone : l10n.opsCancelRequestedSnack);
    }
    return true;
  } on ApiException catch (e) {
    if (context.mounted) _say(context, e.message);
    return false;
  }
}

/// 請一筆派工收尾（軟停止）。
Future<bool> softStopRun(
  BuildContext context,
  WidgetRef ref, {
  required AgentRun run,
}) async {
  final api = ref.read(runsApiProvider);
  final l10n = AppLocalizations.of(context);
  final pid = ref.read(settingsRepoProvider).participantId(run.roomId);
  try {
    await api.softStop(run.id,
        participantId: pid,
        sessionKey: ref.read(appConfigProvider).deviceKey);
    if (context.mounted) {
      // 🔴 它還在跑：訊息要在下一次工具呼叫之前才到得了那個 agent，
      // 而「目前這一步」可能還要幾分鐘
      _say(context, l10n.opsSoftStopRequestedSnack);
    }
    return true;
  } on ApiException catch (e) {
    if (context.mounted) _say(context, e.message);
    return false;
  }
}

/// 對執行器下命令。
Future<bool> sendRunnerCommand(
  BuildContext context,
  WidgetRef ref, {
  required AgentRunner runner,
  required String command,
  required String roomId,
}) async {
  final api = ref.read(runsApiProvider);
  final l10n = AppLocalizations.of(context);
  final pid = ref.read(settingsRepoProvider).participantId(roomId);
  try {
    await api.command(runner.id,
        command: command,
        roomId: roomId,
        participantId: pid,
        sessionKey: ref.read(appConfigProvider).deviceKey);
    if (context.mounted) {
      // 命令**存下來等 heartbeat 取**，不是即時推送。說「已暫停」會讓人
      // 以為機器已經停了，然後在它還在跑時去做下一件事。
      // 這句話只負責「送到了」，「領到了沒、生效了沒」由面板上的命令進度
      // 那一行講——SnackBar 幾秒就消失，而那段等待有 30 秒到數分鐘
      _say(context,
          l10n.opsCommandSentSnack(runnerCommandLabel(command)));
    }
    return true;
  } on ApiException catch (e) {
    if (context.mounted) _say(context, e.message);
    return false;
  }
}

/// 這筆 run 排在第幾位。
///
/// **畫面自己數**：Hub 的 `position` 是建單流水號（`MAX(position)+1`），
/// 中間取消掉幾筆之後它就不再是「你排第幾」。數不到時回 null，呼叫端少講
/// 一句話，而不是講一個錯的數字。
Future<int?> _queuePosition(
    RunsApi api, String roomId, String runId, String? participantId) async {
  try {
    final queued = await api.list(roomId,
        statuses: const ['queued'], participantId: participantId);
    final i = queued.indexWhere((r) => r.id == runId);
    return i < 0 ? null : i + 1;
  } on ApiException {
    return null;
  }
}

/// Hub 的拒絕轉成一句能往下走的話。
///
/// code 是契約（Hub 的 `create_run` 明寫「client 可比對 code」）；Hub 自己
/// 那句話已經寫得夠清楚，所以這裡只在**它講不到的地方**補一句，其餘原樣用。
String _dispatchError(AppLocalizations l10n, ApiException e) =>
    switch (e.code) {
      'run_ref_already_active' => l10n.opsErrorRefActive,
      'project_not_served' => e.message,
      'run_daily_quota_exceeded' => e.message,
      'run_queue_cap_exceeded' => e.message,
      'room_not_ops' => l10n.opsErrorRoomNotOps,
      // 工作房一次性綁定工作區之後的兩種退法（契約 2026-09-21）。**處置
      // 不一樣**：沒綁是去找房主，綁錯邊是這張卡根本不該派到這間房——
      // 講成同一句「派工失敗」等於什麼都沒說
      'workspace_not_bound' => l10n.opsErrorWorkspaceNotBound,
      'workspace_project_mismatch' => l10n.opsErrorWorkspaceMismatch(
          '${e.detail['workspace_key'] ?? l10n.commonUnknown}'),
      // Supervisor 代派時的 kind 白名單（2026-09-19）。Hub 把被擋下的 kind
      // 放在 detail 裡，講出是哪一種才知道下一步該換誰來按
      'kind_not_allowed_for_supervisor' => l10n
          .opsErrorSupervisorKindNotAllowed(
              '${e.detail['kind'] ?? l10n.commonUnknown}'),
      _ => e.message,
    };

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

/// 對人講一句話，**但畫面不在了就只留一行 log**。
///
/// [messenger] 是開對話框之前抓的。顯示不了訊息是「這句話沒人看到」，不是
/// 「這件事沒做」——把它當成放棄送出的理由，就是 09/17 那個 bug 本身。
void _notify(ScaffoldMessengerState? messenger, String text) {
  if (messenger != null && messenger.mounted) {
    messenger.showSnackBar(SnackBar(content: Text(text)));
    return;
  }
  _log.info('畫面已經不在，這句話只留在 log：$text');
}
