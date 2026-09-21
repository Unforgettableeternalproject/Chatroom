import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/api_exception.dart';
import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../core/util/local_host.dart';
import '../../core/util/relative_time.dart';
import '../../l10n/l10n.dart';
import '../../models/agent_session.dart';
import '../../models/assignment.dart';
import '../../state/app_providers.dart';
import '../../state/assignments_providers.dart';
import '../../state/rooms_providers.dart';
import '../../widgets/empty_error_states.dart';
import '../../widgets/kind_badge.dart';
import '../../widgets/reveal.dart';
import '../../widgets/uep_button.dart';

class AssignmentScreen extends ConsumerStatefulWidget {
  const AssignmentScreen({super.key, required this.roomId});

  final String roomId;

  @override
  ConsumerState<AssignmentScreen> createState() => _AssignmentScreenState();
}

class _AssignmentScreenState extends ConsumerState<AssignmentScreen> {
  final _target = TextEditingController();
  final _name = TextEditingController();
  final _note = TextEditingController();
  Timer? _poll;
  bool _submitting = false;

  /// 掃描清單是否連 idle 的 session 一起列出。
  ///
  /// 預設只列 active——idle 的 key 派出去會石沉大海，外觀與派錯人一模一樣。
  /// 但**不能直接把 idle 砍掉**：`/clear` 換過 session id 之後，正在用的那台
  /// 有時要一段時間才回到 active，一律不顯示會讓人以為自己的 session 消失了。
  bool _showIdle = false;
  // 其他裝置預設收起：誤把別人機器上的 agent 指派進私人房，等於把房裡的
  // 內容送出去。要展開才點得到，手滑一次不夠
  bool _showOtherHosts = false;

  /// 沒自報過名字的（沒接過聊天室的）預設收起。
  ///
  /// 本機的 writer lock 目錄是**所有 Codex 安裝共用**的：CLI、VS Code 擴充
  /// 套件、桌面 App、還有 Codex 自己開的 subagent thread 全在裡面。實測
  /// 一台機器上「一個 CLI」對應到七個 lock，而其中只有一個是你想指派的
  /// 那個。分界不是「哪一種安裝」——那要去讀別人家的 sqlite——而是
  /// **有沒有接過聊天室**：只有載入了 chatroom MCP 的那些會自報名字。
  bool _showUnlinked = false;

  @override
  void initState() {
    super.initState();
    // agent 接受指派沒有 WS 事件，開著畫面時輪詢（10s）；
    // session 掃描清單（active/idle 狀態）一併刷新
    _poll = Timer.periodic(const Duration(seconds: 10), (_) {
      ref.invalidate(roomAssignmentsProvider(widget.roomId));
      ref.invalidate(agentSessionsProvider(widget.roomId));
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _target.dispose();
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final target = _target.text.trim();
    if (target.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context).assignNeedTarget)));
      return;
    }
    setState(() => _submitting = true);
    try {
      await ref.read(assignmentsApiProvider).create(widget.roomId,
          targetSessionKey: target,
          note: _note.text.trim(),
          assignedName: _name.text.trim());
      _target.clear();
      _name.clear();
      _note.clear();
      ref.invalidate(roomAssignmentsProvider(widget.roomId));
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _cancel(Assignment a) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final s = context.uep;
        final l10n = AppLocalizations.of(context);
        return AlertDialog(
          title: Text(l10n.assignCancelTitle,
              style: UepText.pageTitle(color: s.inkTitle)),
          content: Text(
            l10n.assignCancelBody(a.targetSessionKey),
            style: UepText.serif(size: 14.5, color: s.inkSoft),
          ),
          actions: [
            UepButton(
              label: l10n.assignCancelNo,
              variant: UepButtonVariant.outline,
              small: true,
              onPressed: () => Navigator.of(context).pop(false),
            ),
            UepButton(
              label: l10n.assignCancelConfirm,
              variant: UepButtonVariant.danger,
              small: true,
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        );
      },
    );
    if (!(confirmed ?? false)) return;
    try {
      await ref.read(assignmentsApiProvider).cancel(
            a.id,
            sessionKey: ref.read(appConfigProvider).deviceKey,
            participantId: ref.read(settingsRepoProvider).participantId(widget.roomId),
          );
    } on ApiException catch (e) {
      // 常見情境：對方剛好在這幾秒內接受了。訊息照 Hub 的講法，不要自己編
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      ref.invalidate(roomAssignmentsProvider(widget.roomId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final roomId = widget.roomId;
    final assignmentsAsync = ref.watch(roomAssignmentsProvider(roomId));
    final detail = ref.watch(roomDetailProvider(roomId)).value;

    return Scaffold(
      backgroundColor: s.bg,
      appBar: AppBar(
        backgroundColor: s.bgSoft,
        surfaceTintColor: Colors.transparent,
        shape: Border(bottom: BorderSide(color: s.line)),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, size: 18, color: s.inkSoft),
          onPressed: () => context.go('/rooms/$roomId'),
        ),
        title: Text(l10n.assignTitle,
            style: UepText.pageTitle(color: s.inkTitle)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 20),
            child: Center(child: MonoLabel(detail?.room.name ?? '', size: 9)),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              // 新增指派卡
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: s.bgCard,
                  border: Border.all(color: s.lineStrong),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MonoLabel(l10n.assignNewLabel, letterSpacing: 2.2),
                    const SizedBox(height: 14),
                    Row(children: [
                      Text(l10n.assignScannedSessions,
                          style: UepText.fieldLabel(color: s.inkSoft)),
                      const Spacer(),
                      InkWell(
                        onTap: () => setState(() => _showIdle = !_showIdle),
                        child: MonoLabel(
                            _showIdle
                                ? l10n.assignShowAll
                                : l10n.assignShowActiveOnly,
                            size: 8.5,
                            color: _showIdle ? s.inkMute : UepColors.gold,
                            letterSpacing: 1.4),
                      ),
                      const SizedBox(width: 10),
                      InkWell(
                        onTap: () =>
                            ref.invalidate(agentSessionsProvider(roomId)),
                        child: Icon(Icons.refresh, size: 14, color: s.inkMute),
                      ),
                    ]),
                    const SizedBox(height: 6),
                    // 換過濾條件是整批清單換掉，高度直接跳的話底下的欄位
                    // 會整個位移
                    UepResize(child: _buildSessionScan()),
                    const SizedBox(height: 14),
                    Text(l10n.assignFieldTarget,
                        style: UepText.fieldLabel(color: s.inkSoft)),
                    const SizedBox(height: 6),
                    _inputBox(
                      TextField(
                        controller: _target,
                        onChanged: (_) => setState(() {}),
                        style:
                            UepText.code(size: 12.5, color: s.ink, height: 1.4),
                        decoration: _decoration('session_key'),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(l10n.assignFieldName,
                        style: UepText.fieldLabel(color: s.inkSoft)),
                    const SizedBox(height: 6),
                    _inputBox(
                      TextField(
                        controller: _name,
                        maxLength: 32,
                        style:
                            UepText.code(size: 12.5, color: s.ink, height: 1.4),
                        decoration: _decoration(l10n.assignFieldNameHint)
                            .copyWith(counterText: ''),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(l10n.assignFieldNote,
                        style: UepText.fieldLabel(color: s.inkSoft)),
                    const SizedBox(height: 6),
                    _inputBox(
                      TextField(
                        controller: _note,
                        maxLines: 3,
                        style: UepText.serif(
                            size: 14, color: s.ink, height: 1.8),
                        decoration: _decoration(l10n.assignFieldNoteHint),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(children: [
                      UepButton(
                        label: l10n.assignSubmit,
                        small: true,
                        onPressed: _submitting ? null : _submit,
                      ),
                      const SizedBox(width: 12),
                      // 時限是 server 的 CHATROOM_ASSIGNMENT_TTL（預設 24 小時），
                      // 沒有端點吐給 client，所以不寫死數字。Expanded 讓它在
                      // 窄畫面換行而不是溢位。
                      Expanded(
                        child: MonoLabel(l10n.assignExpiryNote,
                            size: 9, letterSpacing: 1.2),
                      ),
                    ]),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              MonoLabel(l10n.assignRoomListLabel, letterSpacing: 2.2),
              const SizedBox(height: 10),
              assignmentsAsync.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                      child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: UepColors.gold))),
                ),
                error: (e, _) => ErrorState(
                    error: e,
                    onRetry: () =>
                        ref.invalidate(roomAssignmentsProvider(roomId))),
                data: (assignments) => assignments.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 30),
                        child: EmptyState(title: l10n.assignEmpty),
                      )
                    : Column(children: [
                        for (final a in assignments)
                          _AssignmentRow(
                            assignment: a,
                            onCancel: a.isPending ? () => _cancel(a) : null,
                          ),
                      ]),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 掃描到的 agent session 清單：點選即填入 TARGET SESSION。
  Widget _buildSessionScan() {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final sessionsAsync = ref.watch(agentSessionsProvider(widget.roomId));
    return sessionsAsync.when(
      loading: () => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(children: [
          const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                  strokeWidth: 1.5, color: UepColors.gold)),
          const SizedBox(width: 8),
          MonoLabel(l10n.assignScanning, size: 9, color: s.inkMute),
        ]),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: MonoLabel(l10n.assignScanFailed,
            size: 9, color: UepColors.errorText),
      ),
      data: (all) {
        final sessions = _showIdle
            ? all
            : all.where((x) => x.status == 'active').toList();
        final hiddenIdle = all.length - sessions.length;
        if (sessions.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: MonoLabel(
                hiddenIdle > 0
                    // 有東西卻不顯示時一定要說原因，否則看起來就是掃描壞了
                    ? l10n.assignNoActiveSessions(hiddenIdle)
                    : l10n.assignNoSessions,
                size: 9,
                color: s.inkMute),
          );
        }
        // 本機／其他裝置分開。未知主機名（舊版 bridge）歸到「其他」——
        // 空值不能當成本機，那會讓每一台報不出主機名的機器都混進來
        final mine = sessions.where((x) => x.isOnHost(localHostName)).toList();
        final others = sessions.where((x) => !x.isOnHost(localHostName)).toList();
        // 再分一層：自報過名字的（接過聊天室）排前面，只是被掃描到的收起來。
        // **不是過濾**——第一次指派一個全新的 agent 時，它本來就還沒自報過，
        // 藏掉就指派不到了
        final primary = localHostName.isEmpty ? sessions : mine;
        final primaryKnown =
            primary.where((x) => x.linkedToChatroom).toList();
        final primaryUnlinked =
            primary.where((x) => !x.linkedToChatroom).toList();
        return Column(children: [
          if (mine.isEmpty && others.isNotEmpty && localHostName.isEmpty)
            // 讀不到自己的主機名時無從分組，照列全部並說清楚為什麼
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: MonoLabel(l10n.assignNoHostName,
                    size: 8.5, color: s.inkMute),
              ),
            ),
          for (final session in primaryKnown)
            _SessionRow(
              session: session,
              selected: _target.text.trim() == session.sessionKey,
              onTap: () => setState(() => _target.text = session.sessionKey),
            ),
          if (primaryUnlinked.isNotEmpty) ...[
            InkWell(
              onTap: () => setState(() => _showUnlinked = !_showUnlinked),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(children: [
                  Icon(
                    _showUnlinked
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 14,
                    color: s.inkMute,
                  ),
                  const SizedBox(width: 4),
                  MonoLabel(l10n.assignUnlinkedGroup(primaryUnlinked.length),
                      size: 9, color: s.inkMute),
                ]),
              ),
            ),
            UepExpand(
              expanded: _showUnlinked,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: MonoLabel(l10n.assignUnlinkedNote,
                          size: 8.5, color: s.inkMute),
                    ),
                  ),
                  for (final session in primaryUnlinked)
                    _SessionRow(
                      session: session,
                      selected: _target.text.trim() == session.sessionKey,
                      onTap: () =>
                          setState(() => _target.text = session.sessionKey),
                    ),
                ],
              ),
            ),
          ],
          if (localHostName.isNotEmpty && mine.isEmpty && others.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: MonoLabel(l10n.assignNoLocalSessions,
                    size: 9, color: s.inkMute),
              ),
            ),
          if (localHostName.isNotEmpty && others.isNotEmpty) ...[
            InkWell(
              onTap: () => setState(() => _showOtherHosts = !_showOtherHosts),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(children: [
                  Icon(
                    _showOtherHosts
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 14,
                    color: s.inkMute,
                  ),
                  const SizedBox(width: 4),
                  MonoLabel(l10n.assignOtherHostsGroup(others.length),
                      size: 9, color: s.inkMute),
                ]),
              ),
            ),
            UepExpand(
              expanded: _showOtherHosts,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final session in others)
                    _SessionRow(
                      session: session,
                      selected: _target.text.trim() == session.sessionKey,
                      onTap: () =>
                          setState(() => _target.text = session.sessionKey),
                    ),
                ],
              ),
            ),
          ],
          if (hiddenIdle > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: MonoLabel(l10n.assignHiddenIdle(hiddenIdle),
                    size: 8.5, color: s.inkMute),
              ),
            ),
        ]);
      },
    );
  }

  Widget _inputBox(Widget child) {
    final s = context.uep;
    return Container(
      decoration: BoxDecoration(
        color: s.bgSunken,
        border: Border.all(color: s.lineStrong),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: child,
    );
  }

  InputDecoration _decoration(String hint) => InputDecoration(
        isDense: true,
        border: InputBorder.none,
        hintText: hint,
        hintStyle: UepText.serif(size: 13.5, color: context.uep.inkMute),
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
      );
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.session,
    required this.selected,
    required this.onTap,
  });

  final AgentSession session;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final active = session.status == 'active';
    final statusColor = active ? UepColors.success : s.inkMute;
    final keyTail = session.sessionKey.length > 12
        ? '…${session.sessionKey.substring(session.sessionKey.length - 12)}'
        : session.sessionKey;
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? s.bgSunken : null,
          border: Border.all(
              color: selected ? UepColors.gold : s.line,
              width: selected ? 1.2 : 1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(children: [
          // 狀態燈：active 實心、idle 空心
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? statusColor : null,
              border: Border.all(color: statusColor),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(session.displayTitle,
                        overflow: TextOverflow.ellipsis,
                        style: UepText.code(
                            size: 12.5, color: s.ink, height: 1.3)),
                  ),
                  const SizedBox(width: 8),
                  KindBadge(kind: session.kind, compact: true),
                ]),
                const SizedBox(height: 2),
                Text(
                  session.rooms.isNotEmpty
                      ? l10n.assignSessionInRoom(
                              session.rooms.first.roomName,
                              session.rooms.first.displayName) +
                          (session.rooms.length > 1
                              ? l10n.assignSessionMoreRooms(
                                  session.rooms.length - 1)
                              : '')
                      : keyTail,
                  overflow: TextOverflow.ellipsis,
                  style: UepText.mono(size: 10, color: s.inkMute),
                ),
                // 非本機的一定要標出來源，展開之後才不會又變回一片分不出
                // 誰是誰的清單。未知主機名同樣要講——它不是「本機」
                if (!session.isOnHost(localHostName))
                  Text(
                    session.host.isEmpty
                        ? l10n.assignSessionUnknownHost
                        : l10n.assignSessionOnHost(session.host),
                    overflow: TextOverflow.ellipsis,
                    style: UepText.mono(size: 10, color: UepColors.gold),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          MonoLabel(active ? l10n.commonActive : l10n.commonIdle,
              size: 8.5, color: statusColor, letterSpacing: 1.4),
          const SizedBox(width: 10),
          Text(relativeTime(session.lastSeenAt),
              style: UepText.mono(size: 10, color: s.inkMute)),
        ]),
      ),
    );
  }
}

class _AssignmentRow extends StatelessWidget {
  const _AssignmentRow({required this.assignment, this.onCancel});

  final Assignment assignment;

  /// 收回這筆指派；null 表示不可收回（已被處理過）。
  final VoidCallback? onCancel;

  /// 指派狀態 → 徽章文字。未知狀態原樣顯示，免得新狀態被吃成空白。
  static String _statusLabel(AppLocalizations l10n, String status) =>
      switch (status) {
        'pending' => l10n.assignStatusPending,
        'accepted' => l10n.assignStatusAccepted,
        'declined' => l10n.assignStatusDeclined,
        'cancelled' => l10n.assignStatusCancelled,
        'expired' => l10n.assignStatusExpired,
        _ => status,
      };

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final (color, border) = switch (assignment.status) {
      'accepted' => (
          UepColors.success,
          UepColors.success.withValues(alpha: .4)
        ),
      'pending' => (UepColors.gold, UepColors.gold.withValues(alpha: .4)),
      'declined' => (
          UepColors.errorText,
          UepColors.errorText.withValues(alpha: .4)
        ),
      _ => (s.inkMute, s.lineStrong),
    };
    // cancelled 與 expired 都是「這筆不算數了」，畫得淡一點
    final expired =
        assignment.status == 'expired' || assignment.status == 'cancelled';
    return Opacity(
      opacity: expired ? .55 : 1,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 11),
        decoration:
            BoxDecoration(border: Border(top: BorderSide(color: s.line))),
        child: Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(assignment.targetSessionKey,
                        overflow: TextOverflow.ellipsis,
                        style: UepText.code(
                            size: 12, color: s.ink, height: 1.4)),
                  ),
                  if (assignment.assignedName.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Text('→ ${assignment.assignedName}',
                        style: UepText.code(
                            size: 12, color: UepColors.gold, height: 1.4)),
                  ],
                ]),
                if (assignment.note.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(assignment.note,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: UepText.serif(
                          size: 12.5, color: s.inkMute, height: 1.5)),
                ],
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(border: Border.all(color: border)),
            child: MonoLabel(_statusLabel(l10n, assignment.status),
                size: 8.5, color: color, letterSpacing: 1.4),
          ),
          SizedBox(
            width: 70,
            child: Text(
              relativeTime(assignment.createdAt),
              textAlign: TextAlign.right,
              style: UepText.mono(size: 10, color: s.inkMute),
            ),
          ),
          if (onCancel != null)
            IconButton(
              tooltip: l10n.assignCancelTooltip,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(),
              padding: const EdgeInsets.only(left: 6),
              onPressed: onCancel,
              icon: Icon(Icons.undo, size: 14, color: s.inkMute),
            ),
        ]),
      ),
    );
  }
}
