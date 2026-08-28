import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/api_exception.dart';
import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../core/util/relative_time.dart';
import '../../models/message.dart';
import '../../models/participant.dart';
import '../../state/app_providers.dart';
import '../../state/messages_providers.dart';
import '../../state/rooms_providers.dart';
import '../../widgets/empty_error_states.dart';
import '../../widgets/kind_badge.dart';
import '../../widgets/mention_field.dart';
import '../../widgets/message_bubble.dart';
import '../../widgets/system_message_tile.dart';
import '../../widgets/uep_button.dart';
import '../../ws/realtime_service.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.roomId, this.focusSeq});

  final String roomId;
  final int? focusSeq;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _scroll = ScrollController();
  Timer? _heartbeat;
  Message? _replyTarget;
  int _newWhileAway = 0;
  int _lastSeenCount = 0;
  int? _lastSystemCount;
  int? _highlightSeq;
  Timer? _highlightTimer;
  bool _loadingOlder = false;

  bool get _atBottom =>
      !_scroll.hasClients || _scroll.position.pixels < 60;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _startHeartbeat();
    if (widget.focusSeq != null) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _focusOn(widget.focusSeq!));
    }
  }

  @override
  void didUpdateWidget(covariant ChatScreen old) {
    super.didUpdateWidget(old);
    if (old.roomId != widget.roomId) {
      _replyTarget = null;
      _newWhileAway = 0;
      _lastSeenCount = 0;
      _lastSystemCount = null;
      _startHeartbeat();
    }
    if (widget.focusSeq != null && widget.focusSeq != old.focusSeq) {
      _focusOn(widget.focusSeq!);
    }
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    _highlightTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  // ---------- heartbeat（讓其他 agent 看到人類在線；60s 一次即可） ----------

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 60), (_) async {
      final identity =
          ref.read(identityProvider(widget.roomId)).value;
      if (identity == null) return;
      try {
        await ref.read(roomsApiProvider).heartbeat(widget.roomId,
            participantId: identity.participantId);
      } on ParticipantInvalidException {
        // 身分失效（離房 / DB 重置）→ 重新 join（§6.4）
        ref.invalidate(identityProvider(widget.roomId));
      } on ApiException {
        // 網路層問題由 realtime 狀態機處理，這裡靜默
      }
    });
  }

  // ---------- 捲動 ----------

  void _onScroll() {
    if (_atBottom && _newWhileAway != 0) {
      setState(() => _newWhileAway = 0);
    }
    // reverse list：接近 maxScrollExtent = 視窗頂端 → 載入更舊的歷史
    if (!_loadingOlder &&
        _scroll.hasClients &&
        _scroll.position.pixels >
            _scroll.position.maxScrollExtent - 400) {
      _loadOlder();
    }
  }

  Future<void> _loadOlder() async {
    final feed = ref.read(roomFeedProvider(widget.roomId));
    if (!feed.hasMoreHistory) return;
    _loadingOlder = true;
    try {
      await ref
          .read(realtimeServiceProvider)
          .loadOlder(widget.roomId);
    } finally {
      _loadingOlder = false;
    }
  }

  void _scrollToBottom() {
    _scroll.animateTo(0,
        duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
    setState(() => _newWhileAway = 0);
  }

  Future<void> _focusOn(int seq) async {
    // 目標不在視窗內就持續往回載，直到載到或沒有更多歷史
    var feed = ref.read(roomFeedProvider(widget.roomId));
    var guard = 0;
    while (feed.bySeq(seq) == null && feed.hasMoreHistory && guard < 30) {
      await ref.read(realtimeServiceProvider).loadOlder(widget.roomId);
      feed = ref.read(roomFeedProvider(widget.roomId));
      guard++;
    }
    if (!mounted || feed.bySeq(seq) == null) return;
    final list = feed.messages.toList();
    final index = list.indexWhere((m) => m.seq == seq);
    if (index < 0) return;
    // reverse list 的索引從底部起算；以估計高度先跳到附近再高亮
    final fromBottom = list.length - 1 - index;
    const estimatedExtent = 96.0;
    final target = (fromBottom * estimatedExtent)
        .clamp(0.0, _scroll.hasClients ? _scroll.position.maxScrollExtent : 0.0);
    if (_scroll.hasClients) {
      await _scroll.animateTo(target,
          duration: const Duration(milliseconds: 320), curve: Curves.easeOut);
    }
    setState(() => _highlightSeq = seq);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _highlightSeq = null);
    });
  }

  // ---------- 動作 ----------

  Future<void> _send(String content, List<String> mentions) async {
    final identity =
        await ref.read(identityProvider(widget.roomId).future);
    try {
      await ref.read(messagesApiProvider).post(
            widget.roomId,
            participantId: identity.participantId,
            content: content,
            mentions: mentions,
            replyTo: _replyTarget?.id,
          );
      if (mounted) setState(() => _replyTarget = null);
    } on ParticipantInvalidException {
      // 身分失效：重新 join 後重試一次（僅一次，避免無限迴圈）
      ref.invalidate(identityProvider(widget.roomId));
      final fresh = await ref.read(identityProvider(widget.roomId).future);
      await ref.read(messagesApiProvider).post(
            widget.roomId,
            participantId: fresh.participantId,
            content: content,
            mentions: mentions,
            replyTo: _replyTarget?.id,
          );
      if (mounted) setState(() => _replyTarget = null);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
      rethrow;
    }
  }

  Future<void> _togglePin(Message m) async {
    try {
      final identity =
          await ref.read(identityProvider(widget.roomId).future);
      final api = ref.read(messagesApiProvider);
      if (m.pinned) {
        await api.unpin(m.id, participantId: identity.participantId);
      } else {
        await api.pin(m.id, participantId: identity.participantId);
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _delete(Message m) async {
    final s = context.uep;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('刪除這則訊息？',
            style: UepText.display(size: 24, color: s.inkTitle)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            decoration: BoxDecoration(
              border:
                  Border(left: BorderSide(color: s.hairlineStrong, width: 2)),
            ),
            padding: const EdgeInsets.only(left: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${m.senderName ?? '（未知）'} · ${clockTime(m.createdAt)}　'
                '${m.content.length > 60 ? '${m.content.substring(0, 60)}…' : m.content}',
                style:
                    UepText.serif(size: 13, color: s.inkMute, height: 1.8),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text('訊息會留下「訊息已刪除」的占位，不會從時間軸消失。此操作無法復原。',
              style: UepText.serif(size: 13.5, color: s.inkSoft)),
        ]),
        actions: [
          UepButton(
            label: '取消',
            variant: UepButtonVariant.outline,
            small: true,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          UepButton(
            label: '刪除',
            variant: UepButtonVariant.danger,
            small: true,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      try {
        await ref.read(messagesApiProvider).delete(m.id);
      } on ApiException catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(e.message)));
        }
      }
    }
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final roomId = widget.roomId;
    final detailAsync = ref.watch(roomDetailProvider(roomId));
    final messagesAsync = ref.watch(messagesProvider(roomId));
    final feed = ref.watch(roomFeedProvider(roomId));
    // 讓 join 在進房時就發生（不等第一次發言）
    final identityAsync = ref.watch(identityProvider(roomId));

    // 重連補訊完成後刷新成員與房間狀態（§4.4 步驟 [4]）
    ref.listen(connectionStatusProvider, (prev, next) {
      if (next.value is Connected && prev?.value is! Connected) {
        ref.invalidate(roomDetailProvider(roomId));
      }
    });

    // 自己的 join 完成後刷新成員：新房間常在 join 完成前就抓了 detail，
    // 成員清單會缺自己（kind 徽章全落 other、@ 選單空白）
    ref.listen(identityProvider(roomId), (prev, next) {
      if (next.hasValue && prev?.hasValue != true) {
        ref.invalidate(roomDetailProvider(roomId));
      }
    });

    // 解封後重建人類身分：封存期間進房的 join 會收到 409，
    // 這個錯誤被 keepAlive 快取住，不清掉會讓之後所有發言都撞「已封存」
    ref.listen(roomDetailProvider(roomId), (prev, next) {
      final wasArchived = prev?.value?.room.isArchived ?? false;
      final detail = next.value;
      if (wasArchived && detail != null && !detail.room.isArchived) {
        ref.invalidate(identityProvider(roomId));
      }
    });

    // 新訊息計數（使用者不在底部時不強制捲動，顯示提示 pill）
    ref.listen(messagesProvider(roomId), (prev, next) {
      final list = next.value;
      if (list == null) return;
      final chatCount = list.where((m) => !m.isSystem).length;
      if (_lastSeenCount != 0 && chatCount > _lastSeenCount && !_atBottom) {
        setState(() => _newWhileAway += chatCount - _lastSeenCount);
      }
      _lastSeenCount = chatCount;
      // 系統訊息（加入/離開/封存/解封）到達 → 成員與房間狀態已變，刷新 detail
      final systemCount = list.where((m) => m.isSystem).length;
      if (_lastSystemCount != null && systemCount != _lastSystemCount) {
        ref.invalidate(roomDetailProvider(roomId));
      }
      _lastSystemCount = systemCount;
      // 已讀 cursor：視窗開著就推進（未讀點的資料源）
      ref.read(settingsRepoProvider).setLastReadSeq(roomId, feed.cursor);
    });

    final archived = feed.roomStatus == 'archived' ||
        (detailAsync.value?.room.isArchived ?? false);
    final members = detailAsync.value?.participants ?? const [];
    final activeMembers =
        members.where((p) => p.isActive).toList(growable: false);
    final myId = identityAsync.value?.participantId;
    final room = detailAsync.value?.room;
    final zone = zoneForRoomId(roomId);
    final palette = uepZonePalettes[zone]!;

    final pinnedMessages = feed.messages
        .where((m) => m.pinned && !m.deleted)
        .toList(growable: false);

    final actions = MessageActions(
      onReply: (m) => setState(() => _replyTarget = m),
      onTogglePin: _togglePin,
      onDelete: _delete,
      enabled: !archived,
    );

    final kindById = {
      for (final p in members) ...{
        p.id: p.kind,
        // 同 session 的舊身分（換名重進前）沿用同一 kind
        for (final alias in p.aliasIds) alias: p.kind,
      },
    };

    final wide = MediaQuery.sizeOf(context).width >= 1200;

    final chatColumn = Column(children: [
      _RoomHeader(
        roomId: roomId,
        roomName: room?.name ?? '…',
        topic: room?.topic ?? '',
        archived: archived,
        zoneLabel: zone.name.toUpperCase(),
        zoneColor: palette.soft,
        zoneStroke: palette.stroke(Theme.of(context).brightness),
        pinnedCount: pinnedMessages.length,
        memberCount: activeMembers.length,
        showMembersButton: !wide,
      ),
      if (pinnedMessages.isNotEmpty && !archived)
        _PinnedStrip(roomId: roomId, latest: pinnedMessages.last),
      Expanded(
        child: Stack(children: [
          messagesAsync.when(
            loading: () => const Center(
                child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: UepColors.gold))),
            error: (e, _) => ErrorState(
                error: e,
                onRetry: () => ref.invalidate(messagesProvider(roomId))),
            data: (messages) {
              if (messages.isEmpty) {
                return const EmptyState(
                    title: '還沒有任何訊息',
                    subtitle: '發一則訊息，或指派 agent 加入這個房間');
              }
              final list = _desaturateIfArchived(
                archived,
                ListView.builder(
                  controller: _scroll,
                  reverse: true,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
                  itemCount: messages.length + (feed.hasMoreHistory ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i >= messages.length) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Center(
                          child: MonoLabel('載入更早的訊息…', size: 9),
                        ),
                      );
                    }
                    final m = messages[messages.length - 1 - i];
                    if (m.isSystem) return SystemMessageTile(message: m);
                    final kind = m.senderId != null
                        ? (kindById[m.senderId] ?? 'other')
                        : 'other';
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      child: MessageBubble(
                        message: m,
                        isSelf: myId != null && m.senderId == myId,
                        senderKind: kind,
                        actions: actions,
                        highlighted: _highlightSeq == m.seq,
                      ),
                    );
                  },
                ),
              );
              return list;
            },
          ),
          if (_newWhileAway > 0)
            Positioned(
              bottom: 16,
              left: 0,
              right: 0,
              child: Center(
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: _scrollToBottom,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: s.bgCard,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                          color: UepColors.gold.withValues(alpha: .35)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: .45),
                          blurRadius: 30,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text('有 $_newWhileAway 則新訊息',
                          style: UepText.mono(
                              size: 9.5,
                              color: UepColors.gold,
                              letterSpacing: 1.2)),
                      const SizedBox(width: 8),
                      const Text('↓',
                          style:
                              TextStyle(fontSize: 11, color: UepColors.gold)),
                    ]),
                  ),
                ),
              ),
            ),
        ]),
      ),
      MessageComposer(
        members: activeMembers,
        enabled: !archived,
        replyTarget: _replyTarget,
        onCancelReply: () => setState(() => _replyTarget = null),
        onSend: _send,
      ),
    ]);

    if (!wide) {
      return Scaffold(
        backgroundColor: s.bg,
        endDrawer: Drawer(
          backgroundColor: s.bgSoft,
          child: SafeArea(
            child: _MembersPanel(
                roomId: roomId,
                members: members,
                myId: myId,
                archived: archived,
                youAreAdmin: detailAsync.value?.youAreAdmin ?? false),
          ),
        ),
        body: chatColumn,
      );
    }
    return Scaffold(
      backgroundColor: s.bg,
      body: Row(children: [
        Expanded(child: chatColumn),
        Container(
          width: 288,
          decoration: BoxDecoration(
            color: s.bgSoft,
            border: Border(left: BorderSide(color: s.line)),
          ),
          child: _MembersPanel(
              roomId: roomId,
              members: members,
              myId: myId,
              archived: archived,
              youAreAdmin: detailAsync.value?.youAreAdmin ?? false),
        ),
      ]),
    );
  }

  Widget _desaturateIfArchived(bool archived, Widget child) {
    if (!archived) return child;
    // 設計稿：封存房內容 saturate(.35)
    const sat = 0.35;
    const r = 0.2126, g = 0.7152, b = 0.0722;
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix([
        r + (1 - r) * sat, g * (1 - sat), b * (1 - sat), 0, 0,
        r * (1 - sat), g + (1 - g) * sat, b * (1 - sat), 0, 0,
        r * (1 - sat), g * (1 - sat), b + (1 - b) * sat, 0, 0,
        0, 0, 0, 1, 0,
      ]),
      child: child,
    );
  }
}

// ---------- header ----------

class _RoomHeader extends ConsumerWidget {
  const _RoomHeader({
    required this.roomId,
    required this.roomName,
    required this.topic,
    required this.archived,
    required this.zoneLabel,
    required this.zoneColor,
    required this.zoneStroke,
    required this.pinnedCount,
    required this.memberCount,
    required this.showMembersButton,
  });

  final String roomId;
  final String roomName;
  final String topic;
  final bool archived;
  final String zoneLabel;
  final Color zoneColor;
  final Color zoneStroke;
  final int pinnedCount;
  final int memberCount;
  final bool showMembersButton;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 14, 18, 12),
      decoration: BoxDecoration(
        color: archived ? s.bgSoft : null,
        border: Border(bottom: BorderSide(color: s.line)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            Row(children: [
              Flexible(
                child: Text(
                  roomName,
                  overflow: TextOverflow.ellipsis,
                  style: UepText.display(
                      size: 26,
                      color: archived ? s.inkSoft : s.inkTitle),
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  border: Border.all(
                      color: archived ? s.lineStrong : zoneStroke),
                ),
                child: MonoLabel(
                  archived ? 'ARCHIVED' : zoneLabel,
                  size: 9,
                  color: archived ? s.inkMute : zoneColor,
                  letterSpacing: 1.4,
                ),
              ),
            ]),
            if (topic.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '主題：$topic',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: UepText.serif(
                    size: 12.5,
                    color: archived ? s.inkMute : s.inkSoft,
                    height: 1.5),
              ),
            ],
          ]),
        ),
        const SizedBox(width: 16),
        if (archived)
          _HeaderAction(
            label: '解除封存',
            onTap: () async {
              await ref.read(roomsApiProvider).unarchive(roomId);
              ref.invalidate(roomDetailProvider(roomId));
              ref.invalidate(roomListProvider);
              // 封存期間 join 的 409 錯誤會被快取，解封後重新取得身分
              ref.invalidate(identityProvider(roomId));
              // feed 的房間狀態要等 WS 事件才會翻新；斷線時會卡在 archived
              ref.read(roomFeedProvider(roomId)).setRoomStatus('active');
            },
          )
        else ...[
          _HeaderAction(
            label: '❖ 釘選 $pinnedCount',
            onTap: () => context.go('/rooms/$roomId/pinned'),
          ),
          const SizedBox(width: 8),
          _HeaderAction(
            label: '指派',
            onTap: () => context.go('/rooms/$roomId/assign'),
          ),
          const SizedBox(width: 8),
          _OverflowMenu(roomId: roomId),
        ],
        if (showMembersButton) ...[
          const SizedBox(width: 8),
          Builder(
            builder: (context) => _HeaderAction(
              label: '成員 $memberCount',
              onTap: () => Scaffold.of(context).openEndDrawer(),
            ),
          ),
        ],
      ]),
    );
  }
}

class _HeaderAction extends StatelessWidget {
  const _HeaderAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(border: Border.all(color: s.line)),
        child: Text(label.toUpperCase(),
            style: UepText.mono(
                size: 10, color: s.inkSoft, letterSpacing: 1.4)),
      ),
    );
  }
}

class _OverflowMenu extends ConsumerWidget {
  const _OverflowMenu({required this.roomId});

  final String roomId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    return PopupMenuButton<String>(
      color: s.bgCard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: s.lineStrong),
      ),
      onSelected: (v) async {
        switch (v) {
          case 'archive':
            try {
              await ref.read(roomsApiProvider).archive(roomId);
              ref.invalidate(roomDetailProvider(roomId));
              ref.invalidate(roomListProvider);
            } on ApiException catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(e.message)));
              }
            }
          case 'leave':
            final identity =
                ref.read(identityProvider(roomId)).value;
            if (identity == null) return;
            try {
              await ref.read(roomsApiProvider).leave(roomId,
                  participantId: identity.participantId);
              await ref
                  .read(settingsRepoProvider)
                  .setParticipantId(roomId, null);
              ref.invalidate(identityProvider(roomId));
              ref.invalidate(roomDetailProvider(roomId));
              if (context.mounted) context.go('/rooms');
            } on ApiException catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(e.message)));
              }
            }
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'archive',
          height: 36,
          child: Text('封存房間', style: UepText.sans(size: 12.5, color: s.ink)),
        ),
        PopupMenuItem(
          value: 'leave',
          height: 36,
          child: Text('離開房間',
              style: UepText.sans(size: 12.5, color: UepColors.errorText)),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(border: Border.all(color: s.line)),
        child: Text('⋯',
            style: TextStyle(fontSize: 11, color: s.inkSoft)),
      ),
    );
  }
}

// ---------- pinned strip ----------

class _PinnedStrip extends StatelessWidget {
  const _PinnedStrip({required this.roomId, required this.latest});

  final String roomId;
  final Message latest;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return InkWell(
      onTap: () => context.go('/rooms/$roomId/pinned'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 9),
        decoration: BoxDecoration(
          color: UepColors.gold.withValues(alpha: .06),
          border: Border(
            bottom: BorderSide(color: UepColors.gold.withValues(alpha: .18)),
          ),
        ),
        child: Row(children: [
          const Text('❖',
              style: TextStyle(fontSize: 11, color: UepColors.gold)),
          const SizedBox(width: 10),
          Text('PINNED',
              style: UepText.mono(
                  size: 9, color: UepColors.gold, letterSpacing: 1.6)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${latest.senderName ?? ''}：${latest.content}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: UepText.serif(size: 12.5, color: s.inkSoft, height: 1.4),
            ),
          ),
          MonoLabel('查看全部 →', size: 9, letterSpacing: 1.2),
        ]),
      ),
    );
  }
}

// ---------- members panel ----------

class _MembersPanel extends ConsumerWidget {
  const _MembersPanel({
    required this.roomId,
    required this.members,
    required this.myId,
    required this.archived,
    required this.youAreAdmin,
  });

  final String roomId;
  final List<Participant> members;
  final String? myId;
  final bool archived;
  final bool youAreAdmin;

  Future<void> _kick(
      BuildContext context, WidgetRef ref, Participant p) async {
    final s = context.uep;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('將 ${p.displayName} 移出聊天室？',
            style: UepText.display(size: 22, color: s.inkTitle)),
        content: Text(
          '被移出後，這個 session 將無法重新加入此聊天室。此操作無法復原。',
          style: UepText.serif(size: 13.5, color: s.inkSoft),
        ),
        actions: [
          UepButton(
            label: '取消',
            variant: UepButtonVariant.outline,
            small: true,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          UepButton(
            label: '移出',
            variant: UepButtonVariant.danger,
            small: true,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false) || myId == null) return;
    try {
      await ref
          .read(roomsApiProvider)
          .kick(roomId, targetId: p.id, participantId: myId!);
      ref.invalidate(roomDetailProvider(roomId));
    } on ApiException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final active = members.where((p) => p.isActive).toList();
    final gone = members.where((p) => !p.isActive).toList();

    return Column(children: [
      Container(
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration:
            BoxDecoration(border: Border(bottom: BorderSide(color: s.line))),
        width: double.infinity,
        child: Center(
          child: MonoLabel('成員 ${active.length}',
              size: 9, color: UepColors.gold, letterSpacing: 1.6),
        ),
      ),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
          children: [
            MonoLabel('ACTIVE', size: 8.5, letterSpacing: 2.2),
            const SizedBox(height: 8),
            for (final p in active)
              _MemberTile(
                p: p,
                isSelf: p.id == myId,
                onKick: youAreAdmin && p.id != myId && !archived
                    ? () => _kick(context, ref, p)
                    : null,
              ),
            if (gone.isNotEmpty) ...[
              const SizedBox(height: 16),
              MonoLabel('已離開', size: 8.5, letterSpacing: 2.2),
              const SizedBox(height: 8),
              for (final p in gone)
                Opacity(
                    opacity: .45,
                    child: _MemberTile(p: p, isSelf: false, inactive: true)),
            ],
          ],
        ),
      ),
      // 封存房唯讀，指派入口一併收起
      if (!archived)
        Container(
          padding: const EdgeInsets.all(14),
          decoration:
              BoxDecoration(border: Border(top: BorderSide(color: s.line))),
          child: UepButton(
            label: '指派 AGENT 加入',
            variant: UepButtonVariant.outline,
            small: true,
            expand: true,
            onPressed: () => context.go('/rooms/$roomId/assign'),
          ),
        ),
    ]);
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile(
      {required this.p,
      required this.isSelf,
      this.inactive = false,
      this.onKick});

  final Participant p;
  final bool isSelf;
  final bool inactive;

  /// 管理員視角的移出動作；null 表示不顯示。
  final VoidCallback? onKick;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final color = kindColor(p.kind, context: context);
    final lastSeen = parseIso(p.lastSeenAt);
    final idleMinutes = lastSeen == null
        ? null
        : DateTime.now().difference(lastSeen).inMinutes;
    final isIdle = !inactive && !p.isHuman && (idleMinutes ?? 0) >= 2;

    String subtitle;
    if (inactive) {
      subtitle = switch (p.status) {
        'removed' => '因閒置移出',
        'kicked' => '被管理員移出',
        _ => '已離開',
      };
    } else if (isSelf) {
      subtitle = '你 · 管控權';
    } else if (isIdle) {
      final remain = 10 - idleMinutes!;
      subtitle = remain > 0 ? '閒置 $idleMinutes 分 · $remain 分後移出' : '閒置 $idleMinutes 分';
    } else {
      subtitle = '活躍 · ${relativeTime(p.lastSeenAt)}';
    }

    return Opacity(
      opacity: isIdle ? .6 : 1,
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.fromLTRB(10, 9, 8, 9),
        decoration: BoxDecoration(
          color: isSelf ? UepColors.gold.withValues(alpha: .06) : null,
          border: Border(
            left: BorderSide(
                color: inactive ? s.hairline : color, width: 2),
          ),
          borderRadius:
              const BorderRadius.horizontal(right: Radius.circular(4)),
        ),
        child: Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(p.displayName,
                        overflow: TextOverflow.ellipsis,
                        style: UepText.sans(
                            size: 13,
                            weight: FontWeight.w600,
                            color: inactive ? s.ink : s.inkTitle)),
                  ),
                  const SizedBox(width: 7),
                  KindBadge(kind: p.kind, compact: true),
                  if (p.previousName != null) ...[
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text('（原：${p.previousName}）',
                          overflow: TextOverflow.ellipsis,
                          style: UepText.serif(size: 11, color: s.inkMute)),
                    ),
                  ],
                  if (p.distinctHint != null) ...[
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text('（${p.distinctHint}）',
                          overflow: TextOverflow.ellipsis,
                          style: UepText.mono(size: 9, color: s.inkMute)),
                    ),
                  ],
                ]),
                const SizedBox(height: 3),
                Text(subtitle,
                    style: UepText.mono(
                        size: 9,
                        color: isSelf ? UepColors.gold : s.inkMute,
                        letterSpacing: 1.0)),
              ],
            ),
          ),
          if (!inactive)
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.only(top: 2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isSelf
                    ? UepColors.gold
                    : isIdle
                        ? Colors.transparent
                        : UepColors.success,
                border: isIdle ? Border.all(color: s.inkMute) : null,
              ),
            ),
          if (onKick != null)
            IconButton(
              tooltip: '移出聊天室',
              visualDensity: VisualDensity.compact,
              onPressed: onKick,
              icon: Icon(Icons.person_remove_outlined,
                  size: 14, color: s.inkMute),
            ),
        ]),
      ),
    );
  }
}
