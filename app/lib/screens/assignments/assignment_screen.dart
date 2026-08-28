import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/api_exception.dart';
import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../core/util/relative_time.dart';
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
  final _note = TextEditingController();
  Timer? _poll;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    // agent 接受指派沒有 WS 事件，開著畫面時輪詢（10s）
    _poll = Timer.periodic(const Duration(seconds: 10), (_) {
      ref.invalidate(roomAssignmentsProvider(widget.roomId));
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _target.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final target = _target.text.trim();
    if (target.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('請輸入目標 session key')));
      return;
    }
    setState(() => _submitting = true);
    try {
      await ref.read(assignmentsApiProvider).create(widget.roomId,
          targetSessionKey: target, note: _note.text.trim());
      await ref.read(settingsRepoProvider).rememberSessionKeys([target]);
      _target.clear();
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

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final roomId = widget.roomId;
    final assignmentsAsync = ref.watch(roomAssignmentsProvider(roomId));
    final detail = ref.watch(roomDetailProvider(roomId)).value;
    final recent = ref.watch(settingsRepoProvider).seenSessionKeys;

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
                    MonoLabel('TARGET SESSION',
                        color: s.inkSoft, letterSpacing: 1.4),
                    const SizedBox(height: 6),
                    _inputBox(
                      TextField(
                        controller: _target,
                        style:
                            UepText.code(size: 12, color: s.ink, height: 1.4),
                        decoration: _decoration(
                            'agent 的 session_key（如 codex-worklog-02）'),
                      ),
                    ),
                    if (recent.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(spacing: 6, runSpacing: 6, children: [
                        for (final key in recent.take(8))
                          InkWell(
                            onTap: () => _target.text = key,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                border: Border.all(color: s.line),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(key,
                                  style: UepText.code(
                                      size: 10,
                                      color: s.inkSoft,
                                      height: 1.4)),
                            ),
                          ),
                      ]),
                    ],
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
                          _AssignmentRow(assignment: a),
                      ]),
              ),
            ],
          ),
        ),
      ),
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

class _AssignmentRow extends StatelessWidget {
  const _AssignmentRow({required this.assignment});

  final Assignment assignment;

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
    final expired = assignment.status == 'expired';
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
                Text(assignment.targetSessionKey,
                    style: UepText.code(size: 11.5, color: s.ink, height: 1.4)),
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
        ]),
      ),
    );
  }
}
