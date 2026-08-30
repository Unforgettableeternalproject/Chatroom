import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/api_exception.dart';
import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../core/util/local_host.dart';
import '../../core/util/relative_time.dart';
import '../../models/agent_session.dart';
import '../../models/assignment.dart';
import '../../state/app_providers.dart';
import '../../state/assignments_providers.dart';
import '../../state/rooms_providers.dart';
import '../../widgets/empty_error_states.dart';
import '../../widgets/kind_badge.dart';
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

  @override
  void initState() {
    super.initState();
    // agent 接受指派沒有 WS 事件，開著畫面時輪詢（10s）；
    // session 掃描清單（active/idle 狀態）一併刷新
    _poll = Timer.periodic(const Duration(seconds: 10), (_) {
      ref.invalidate(roomAssignmentsProvider(widget.roomId));
      ref.invalidate(agentSessionsProvider);
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
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('請從掃描清單選擇對象，或輸入 session key')));
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
        return AlertDialog(
          title: Text('收回這筆指派？',
              style: UepText.display(size: 22, color: s.inkTitle)),
          content: Text(
            '${a.targetSessionKey} 還沒回應。收回後對方就不會再收到這個邀請。',
            style: UepText.serif(size: 13.5, color: s.inkSoft),
          ),
          actions: [
            UepButton(
              label: '不要',
              variant: UepButtonVariant.outline,
              small: true,
              onPressed: () => Navigator.of(context).pop(false),
            ),
            UepButton(
              label: '收回',
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
      await ref.read(assignmentsApiProvider).cancel(a.id);
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
        title: Text('指派 agent',
            style: UepText.display(size: 22, color: s.inkTitle)),
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
                    MonoLabel('NEW ASSIGNMENT', letterSpacing: 2.2),
                    const SizedBox(height: 14),
                    Row(children: [
                      MonoLabel('掃描到的 SESSION',
                          color: s.inkSoft, letterSpacing: 1.4),
                      const Spacer(),
                      InkWell(
                        onTap: () => setState(() => _showIdle = !_showIdle),
                        child: MonoLabel(_showIdle ? '顯示全部' : '僅 ACTIVE',
                            size: 8.5,
                            color: _showIdle ? s.inkMute : UepColors.gold,
                            letterSpacing: 1.4),
                      ),
                      const SizedBox(width: 10),
                      InkWell(
                        onTap: () => ref.invalidate(agentSessionsProvider),
                        child: Icon(Icons.refresh, size: 14, color: s.inkMute),
                      ),
                    ]),
                    const SizedBox(height: 6),
                    _buildSessionScan(),
                    const SizedBox(height: 14),
                    MonoLabel('TARGET SESSION',
                        color: s.inkSoft, letterSpacing: 1.4),
                    const SizedBox(height: 6),
                    _inputBox(
                      TextField(
                        controller: _target,
                        onChanged: (_) => setState(() {}),
                        style:
                            UepText.code(size: 12, color: s.ink, height: 1.4),
                        decoration: _decoration(
                            '點上方清單自動填入，或手動輸入 session_key'),
                      ),
                    ),
                    const SizedBox(height: 14),
                    MonoLabel('命名（選填）', color: s.inkSoft, letterSpacing: 1.4),
                    const SizedBox(height: 6),
                    _inputBox(
                      TextField(
                        controller: _name,
                        maxLength: 32,
                        style:
                            UepText.code(size: 12, color: s.ink, height: 1.4),
                        decoration: _decoration(
                                '幫這個 agent 取房內名稱；留空則由 agent 自取或自動生成')
                            .copyWith(counterText: ''),
                      ),
                    ),
                    const SizedBox(height: 14),
                    MonoLabel('NOTE', color: s.inkSoft, letterSpacing: 1.4),
                    const SizedBox(height: 6),
                    _inputBox(
                      TextField(
                        controller: _note,
                        maxLines: 3,
                        style: UepText.serif(
                            size: 13, color: s.ink, height: 1.8),
                        decoration:
                            _decoration('要 agent 做什麼？加入後會看到這段說明'),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(children: [
                      UepButton(
                        label: '送出指派',
                        small: true,
                        onPressed: _submitting ? null : _submit,
                      ),
                      const SizedBox(width: 12),
                      MonoLabel('24 小時未回應自動過期',
                          size: 9, letterSpacing: 1.2),
                    ]),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              MonoLabel('本房間的指派', letterSpacing: 2.2),
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
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 30),
                        child: EmptyState(title: '這個房間還沒有任何指派'),
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
    final sessionsAsync = ref.watch(agentSessionsProvider);
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
          MonoLabel('掃描中…', size: 9, color: s.inkMute),
        ]),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: MonoLabel('掃描失敗，可手動輸入 session key',
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
                    ? '沒有 active 的 session（$hiddenIdle 個閒置中，可切換顯示全部）'
                    : '目前沒有掃描到任何 agent session',
                size: 9,
                color: s.inkMute),
          );
        }
        // 本機／其他裝置分開。未知主機名（舊版 bridge）歸到「其他」——
        // 空值不能當成本機，那會讓每一台報不出主機名的機器都混進來
        final mine = sessions.where((x) => x.isOnHost(localHostName)).toList();
        final others = sessions.where((x) => !x.isOnHost(localHostName)).toList();
        return Column(children: [
          if (mine.isEmpty && others.isNotEmpty && localHostName.isEmpty)
            // 讀不到自己的主機名時無從分組，照列全部並說清楚為什麼
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: MonoLabel('讀不到本機主機名，無法分辨裝置',
                    size: 8.5, color: s.inkMute),
              ),
            ),
          for (final session in (localHostName.isEmpty ? sessions : mine))
            _SessionRow(
              session: session,
              selected: _target.text.trim() == session.sessionKey,
              onTap: () => setState(() => _target.text = session.sessionKey),
            ),
          if (localHostName.isNotEmpty && mine.isEmpty && others.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: MonoLabel('這台機器上沒有掃描到 agent',
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
                  MonoLabel('其他裝置（${others.length}）',
                      size: 9, color: s.inkMute),
                ]),
              ),
            ),
            if (_showOtherHosts)
              for (final session in others)
                _SessionRow(
                  session: session,
                  selected: _target.text.trim() == session.sessionKey,
                  onTap: () =>
                      setState(() => _target.text = session.sessionKey),
                ),
          ],
          if (hiddenIdle > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: MonoLabel('另有 $hiddenIdle 個閒置的 session 未顯示',
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
        hintStyle: UepText.serif(size: 12.5, color: context.uep.inkMute),
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
                            size: 12, color: s.ink, height: 1.3)),
                  ),
                  const SizedBox(width: 8),
                  KindBadge(kind: session.kind, compact: true),
                ]),
                const SizedBox(height: 2),
                Text(
                  session.rooms.isNotEmpty
                      ? '在「${session.rooms.first.roomName}」'
                          '為 ${session.rooms.first.displayName}'
                          '${session.rooms.length > 1 ? '（+${session.rooms.length - 1} 房）' : ''}'
                      : keyTail,
                  overflow: TextOverflow.ellipsis,
                  style: UepText.mono(size: 9, color: s.inkMute),
                ),
                // 非本機的一定要標出來源，展開之後才不會又變回一片分不出
                // 誰是誰的清單。未知主機名同樣要講——它不是「本機」
                if (!session.isOnHost(localHostName))
                  Text(
                    session.host.isEmpty ? '未知裝置' : '在 ${session.host}',
                    overflow: TextOverflow.ellipsis,
                    style: UepText.mono(size: 9, color: UepColors.gold),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          MonoLabel(active ? 'ACTIVE' : 'IDLE',
              size: 8.5, color: statusColor, letterSpacing: 1.4),
          const SizedBox(width: 10),
          Text(relativeTime(session.lastSeenAt),
              style: UepText.mono(size: 9, color: s.inkMute)),
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

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
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
                            size: 11.5, color: s.ink, height: 1.4)),
                  ),
                  if (assignment.assignedName.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Text('→ ${assignment.assignedName}',
                        style: UepText.code(
                            size: 11, color: UepColors.gold, height: 1.4)),
                  ],
                ]),
                if (assignment.note.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(assignment.note,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: UepText.serif(
                          size: 11.5, color: s.inkMute, height: 1.5)),
                ],
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(border: Border.all(color: border)),
            child: MonoLabel(assignment.status,
                size: 8.5, color: color, letterSpacing: 1.4),
          ),
          SizedBox(
            width: 70,
            child: Text(
              relativeTime(assignment.createdAt),
              textAlign: TextAlign.right,
              style: UepText.mono(size: 9, color: s.inkMute),
            ),
          ),
          if (onCancel != null)
            IconButton(
              tooltip: '收回這筆指派',
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
