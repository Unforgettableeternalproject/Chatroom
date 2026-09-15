import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../models/board.dart';
import '../../models/participant.dart';
import '../../state/board_providers.dart';
import '../../state/rooms_providers.dart';
import '../../widgets/empty_error_states.dart';
import '../../widgets/kind_badge.dart';

/// Supervisor 的追蹤介面：**這間房裡誰在做什麼、做到哪**。
///
/// ## 為什麼是獨立畫面而不是板上的一個篩選器
///
/// 板是**依工作編排**的（週期 → 階段 → 卡），這裡是**依人編排**的。同一批
/// 卡，兩種切法回答的是不同問題：板回答「這件事做完了嗎」，這裡回答
/// 「這個人手上有什麼、卡住了沒」。把後者塞進板上當篩選器，等於要 supervisor
/// 每次心裡先把卡重新分組一次——而那正是他要看這個畫面的理由。
///
/// ## 為什麼用 participant_id 對人，不用 actor_key
///
/// Hub **刻意不外流成員的 session_key**，所以 UI 手上沒有房內成員的
/// `actor_key`。但卡上的 `claim_participant_id` / `assignee_participant_id`
/// / `created_by` 全是房內 participant id——拿它比對，剛好就是「**這個房
/// 現在的成員**」這個語意。
///
/// 副作用是對的：agent 換一個 session 就是新的 participant，他上一世領的卡
/// 不會算在他頭上——那與「同名不同 session＝獨立個體」（艾斯維爾 2026-09-03）
/// 一致。那些卡會落在最底下「已經不在房裡的人留下的」那一區。
class SupervisorTrackScreen extends ConsumerWidget {
  const SupervisorTrackScreen({super.key, required this.roomId});

  final String roomId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final board = ref.watch(boardProvider(roomId));
    final detail = ref.watch(roomDetailProvider(roomId));

    return Scaffold(
      backgroundColor: s.bg,
      appBar: AppBar(
        backgroundColor: s.bg,
        title: Text('誰在做什麼',
            style: UepText.display(size: 20, color: s.inkTitle)),
        actions: [
          IconButton(
            tooltip: '重新整理',
            onPressed: () {
              ref.invalidate(boardProvider(roomId));
              ref.invalidate(roomDetailProvider(roomId));
            },
            icon: Icon(Icons.refresh, size: 16, color: s.inkMute),
          ),
        ],
      ),
      body: board.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorState(
          error: e,
          onRetry: () => ref.invalidate(boardProvider(roomId)),
        ),
        data: (snap) => _Body(
          roomId: roomId,
          snap: snap,
          members: detail.value?.participants ?? const [],
        ),
      ),
    );
  }
}

/// 一個人手上的卡，依「要不要現在關心」分三堆。
@immutable
class MemberWorkload {
  const MemberWorkload({
    required this.name,
    required this.kind,
    this.active = const [],
    this.blocked = const [],
    this.done = const [],
    this.suggested = const [],
  });

  final String name;
  final String kind;

  /// 認領了而且還在跑（`todo` / `in_progress`）。
  final List<BoardTask> active;

  /// 認領了但卡住。**單獨一堆**：它與「在做」在數量上會被混在一起，
  /// 而 supervisor 要看的正好是這一堆。
  final List<BoardTask> blocked;

  final List<BoardTask> done;

  /// 被指派但**還沒認領**。指派是建議不是鎖（Hub 的語意），所以這一堆
  /// 表示「有人請他做，他還沒站上去」——那與「他在做」是兩件事。
  final List<BoardTask> suggested;

  bool get isEmpty =>
      active.isEmpty && blocked.isEmpty && done.isEmpty && suggested.isEmpty;

  int get openCount => active.length + blocked.length;
}

/// 把板上的卡依房內成員分堆。
///
/// **只看 `visibleTasks`**：被取消的週期底下那些卡在畫面上不存在，算進來的話
/// supervisor 會看到一個人「手上有五張」而板上一張都找不到。
Map<String, MemberWorkload> workloadsByMember(
  BoardSnapshot snap,
  List<Participant> members,
) {
  final byId = {for (final p in members) p.id: p};
  final result = <String, MemberWorkload>{};
  for (final p in members) {
    final active = <BoardTask>[];
    final blocked = <BoardTask>[];
    final done = <BoardTask>[];
    final suggested = <BoardTask>[];
    for (final t in snap.visibleTasks) {
      final held = t.claimParticipantId == p.id && t.claimState == 'held';
      if (held) {
        switch (t.status) {
          case 'blocked':
            blocked.add(t);
          case 'done':
            done.add(t);
          case 'cancelled':
            break;
          default:
            active.add(t);
        }
        continue;
      }
      // 指派但沒認領。**已經有別人領走的不算**——那時指派已經沒有意義了
      if (t.assigneeParticipantId == p.id && t.claimState != 'held') {
        if (t.status != 'done' && t.status != 'cancelled') suggested.add(t);
      }
    }
    result[p.id] = MemberWorkload(
      name: p.displayName,
      kind: p.kind,
      active: active,
      blocked: blocked,
      done: done,
      suggested: suggested,
    );
  }
  // 已經不在房裡的人留下的：孤兒卡。**這一堆不屬於任何現任成員**，
  // 但它是 supervisor 最該先看的——那些卡看起來有人在做，實際上沒有
  final orphans = [
    for (final t in snap.visibleTasks)
      if (t.claimState == 'orphaned' && !byId.containsKey(t.claimParticipantId))
        t,
  ];
  if (orphans.isNotEmpty) {
    result[_kOrphanKey] = MemberWorkload(
      name: '已經不在房裡的人',
      kind: 'other',
      active: orphans,
    );
  }
  return result;
}

const _kOrphanKey = '__orphaned__';

class _Body extends StatelessWidget {
  const _Body({
    required this.roomId,
    required this.snap,
    required this.members,
  });

  final String roomId;
  final BoardSnapshot snap;
  final List<Participant> members;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final active = [for (final p in members) if (p.status == 'active') p];
    final loads = workloadsByMember(snap, active);
    // 手上有東西的排前面；孤兒那一堆永遠第一
    final keys = loads.keys.toList()
      ..sort((a, b) {
        if (a == _kOrphanKey) return -1;
        if (b == _kOrphanKey) return 1;
        return loads[b]!.openCount.compareTo(loads[a]!.openCount);
      });

    if (snap.visibleTasks.isEmpty) {
      return const Center(
        child: EmptyState(
          title: '這塊板上還沒有卡',
          subtitle: '有人開始做事之後，這裡會列出誰手上有什麼',
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 40),
      children: [
        Text(
          '依人分組，不是依工作分組。板回答「這件事做完了嗎」，'
          '這裡回答「這個人手上有什麼、卡住了沒」。',
          style: UepText.serif(size: 12, color: s.inkMute, height: 1.5),
        ),
        const SizedBox(height: 16),
        for (final k in keys)
          if (!loads[k]!.isEmpty)
            _MemberCard(
              roomId: roomId,
              load: loads[k]!,
              isOrphanBucket: k == _kOrphanKey,
            ),
        // 一個人都沒事做也要講，否則畫面空白會被當成「還沒載入」
        if (keys.every((k) => loads[k]!.isEmpty))
          Padding(
            padding: const EdgeInsets.only(top: 40),
            child: Text('房裡沒有人手上有卡。',
                textAlign: TextAlign.center,
                style: UepText.serif(size: 13, color: s.inkMute)),
          ),
      ],
    );
  }
}

class _MemberCard extends StatelessWidget {
  const _MemberCard({
    required this.roomId,
    required this.load,
    required this.isOrphanBucket,
  });

  final String roomId;
  final MemberWorkload load;
  final bool isOrphanBucket;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        border: Border.all(
            color: isOrphanBucket ? UepColors.gold : s.line),
        color: s.bgCard,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 11, 14, 9),
            child: Row(children: [
              if (!isOrphanBucket) ...[
                KindBadge(kind: load.kind, compact: true),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(load.name,
                    style: UepText.sans(
                        size: 13.5,
                        color:
                            isOrphanBucket ? UepColors.gold : s.inkTitle)),
              ),
              if (load.openCount > 0)
                MonoLabel('${load.openCount} 在手上',
                    size: 9, letterSpacing: 1.2),
            ]),
          ),
          if (isOrphanBucket)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Text(
                '這些卡看起來有人在做，實際上沒有。要有人接手，或由管理者指派。',
                style: UepText.serif(size: 11.5, color: s.inkMute),
              ),
            ),
          _group(context, '卡住', load.blocked, danger: true),
          _group(context, isOrphanBucket ? '無人接手' : '進行中', load.active),
          _group(context, '被指派但還沒認領', load.suggested),
          _group(context, '完成', load.done, dim: true),
        ],
      ),
    );
  }

  Widget _group(
    BuildContext context,
    String label,
    List<BoardTask> tasks, {
    bool danger = false,
    bool dim = false,
  }) {
    if (tasks.isEmpty) return const SizedBox.shrink();
    final s = context.uep;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
          child: MonoLabel(
            '$label · ${tasks.length}',
            size: 8.5,
            letterSpacing: 1.4,
            color: danger ? UepColors.gold : s.inkMute,
          ),
        ),
        for (final t in tasks)
          InkWell(
            // 點進去看那張卡。**跳回板上**而不是在這裡開抽屜：改一張卡的
            // 狀態要看得到它在哪個階段底下，那個脈絡只有板上有
            onTap: () => context.go('/rooms/$roomId/board'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 5, 14, 6),
              child: Row(children: [
                Text('·',
                    style: UepText.mono(size: 11, color: s.inkMute)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: UepText.serif(
                        size: 12.5, color: dim ? s.inkMute : s.ink),
                  ),
                ),
                if (t.watcherCount > 0) ...[
                  const SizedBox(width: 6),
                  MonoLabel('${t.watcherCount} 人在等',
                      size: 8, letterSpacing: 1.0),
                ],
              ]),
            ),
          ),
      ],
    );
  }
}
