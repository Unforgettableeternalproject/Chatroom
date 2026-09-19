import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/l10n.dart';
import '../../models/ops_exception.dart';
import '../../state/ops_exceptions_providers.dart';
import '../../widgets/empty_error_states.dart';
import '../../widgets/kind_badge.dart';

/// 監控器：跨房的派工例外。
///
/// **獨立於執行儀表板**：儀表板是單房視角（`room_id` 必填），而這裡要看的
/// 正是「我的哪一間房出事了」。把跨房資料塞進單房頁面，會讓上面每一個數字
/// 都要重新確認自己講的是哪一間房。
class OpsExceptionsScreen extends ConsumerStatefulWidget {
  const OpsExceptionsScreen({super.key});

  @override
  ConsumerState<OpsExceptionsScreen> createState() =>
      _OpsExceptionsScreenState();
}

class _OpsExceptionsScreenState extends ConsumerState<OpsExceptionsScreen> {
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    // 輪詢在畫面層（同執行儀表板）：畫面走了定時器跟著走
    _poll = Timer.periodic(const Duration(seconds: 15),
        (_) => ref.invalidate(opsExceptionsProvider));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// 返回：先回堆疊上的來源頁，沒有堆疊時靠 `?from=` 找回入口
  /// （通常是某間房的執行儀表板），兩者都沒有才退回房間列表。
  void _back() {
    if (context.canPop()) {
      context.pop();
      return;
    }
    final from = GoRouterState.of(context).uri.queryParameters['from'];
    // 只接受站內的絕對路徑，而且不能指回這個面板自己——否則返回鈕會原地打轉
    if (from != null &&
        from.startsWith('/') &&
        !from.startsWith('//') &&
        !from.startsWith('/ops/exceptions')) {
      context.go(from);
      return;
    }
    context.go('/rooms');
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final async = ref.watch(opsExceptionsProvider);
    final list = async.value ?? const <OpsException>[];
    // 看過了：水位記在本機，未讀計數（頂欄的入口）靠它算
    if (list.isNotEmpty) {
      final newest = list.first.createdAt;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(ref.read(opsExceptionSeenProvider.notifier).markSeen(newest));
      });
    }

    return Scaffold(
      backgroundColor: s.bg,
      body: Column(children: [
        Container(
          padding: const EdgeInsets.fromLTRB(24, 14, 18, 12),
          decoration:
              BoxDecoration(border: Border(bottom: BorderSide(color: s.line))),
          child: Row(children: [
            IconButton(
              tooltip: l10n.commonBack,
              icon: Icon(Icons.arrow_back, size: 18, color: s.inkSoft),
              onPressed: _back,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.opsExceptionsTitle,
                      style: UepText.pageTitle(color: s.inkTitle)),
                  // 範圍要講清楚：看起來像全量的清單，會讓人根據一份
                  // 不完整的資料判斷「今天沒出事」
                  Text(l10n.opsExceptionsScope,
                      style: UepText.mono(size: 10.5, color: s.inkMute)),
                ],
              ),
            ),
            MonoLabel(l10n.opsRefreshEvery15s, size: 9, letterSpacing: 1.2),
            const SizedBox(width: 10),
            IconButton(
              tooltip: l10n.commonRefresh,
              icon: Icon(Icons.refresh, size: 16, color: s.inkMute),
              onPressed: () => ref.invalidate(opsExceptionsProvider),
            ),
          ]),
        ),
        Expanded(
          child: async.when(
            loading: () => list.isEmpty
                ? const Center(
                    child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: UepColors.gold)))
                : _list(list),
            error: (e, _) => ErrorState(
                error: e,
                onRetry: () => ref.invalidate(opsExceptionsProvider)),
            data: _list,
          ),
        ),
      ]),
    );
  }

  Widget _list(List<OpsException> list) {
    if (list.isEmpty) {
      final l10n = AppLocalizations.of(context);
      return EmptyState(
        title: l10n.opsExceptionsEmptyTitle,
        subtitle: l10n.opsExceptionsEmptySubtitle,
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      itemCount: list.length,
      itemBuilder: (context, i) => _ExceptionTile(item: list[i]),
    );
  }
}

class _ExceptionTile extends StatelessWidget {
  const _ExceptionTile({required this.item});

  final OpsException item;

  Color _dot() {
    switch (item.severity) {
      case 'error':
        return UepColors.error;
      case 'info':
        return UepColors.info;
      default:
        return UepColors.gold;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return InkWell(
      // 點一筆跳到那間房。跳到房而不是儀表板：出事的那筆派工，後續的話
      // 都發生在訊息流裡
      onTap: () => context.go('/rooms/${item.roomId}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            margin: const EdgeInsets.only(top: 5),
            width: 8,
            height: 8,
            decoration:
                BoxDecoration(color: _dot(), shape: BoxShape.circle),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.title,
                    style: UepText.serif(size: 14, color: s.inkTitle)),
                const SizedBox(height: 3),
                Text(
                  '${item.roomName.isEmpty ? item.roomId : item.roomName}'
                  ' · ${item.reason}',
                  style: UepText.mono(size: 10.5, color: s.inkMute),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(item.createdAt,
              style: UepText.mono(size: 10, color: s.inkMute)),
        ]),
      ),
    );
  }
}

/// 頂欄的入口：一顆 icon + 未讀計數。
///
/// 計數是**比本機水位新的筆數**，不是總數：總數永遠不會歸零，然後就跟
/// 沒有一樣。
class OpsExceptionsEntry extends ConsumerWidget {
  const OpsExceptionsEntry({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final list = ref.watch(opsExceptionsProvider).value ?? const [];
    final unread =
        unreadExceptionCount(list, ref.watch(opsExceptionSeenProvider));
    return Stack(clipBehavior: Clip.none, children: [
      IconButton(
        tooltip: AppLocalizations.of(context).opsExceptionsTitle,
        icon: Icon(Icons.warning_amber_rounded, size: 17, color: s.inkMute),
        // 用 push 不用 go：go 會把導覽堆疊整個換掉，面板的返回鈕於是找不到
        // 來源頁，一路退回房間列表。`?from=` 是堆疊被清掉（或直接開網址）
        // 時的備援，讓返回至少回得到這個入口所在的畫面
        onPressed: () => context.push('/ops/exceptions?from='
            '${Uri.encodeComponent(GoRouterState.of(context).uri.toString())}'),
      ),
      if (unread > 0)
        Positioned(
          right: 4,
          top: 2,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: UepColors.error,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(unread > 99 ? '99+' : '$unread',
                style: UepText.mono(size: 9, color: Colors.white)),
          ),
        ),
    ]);
  }
}
