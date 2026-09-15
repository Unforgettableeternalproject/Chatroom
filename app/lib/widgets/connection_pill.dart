import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../state/app_providers.dart';
import '../ws/realtime_service.dart';

/// 標題列的連線狀態 pill（設計稿 top bar 三態 + syncing）。
class ConnectionPill extends ConsumerWidget {
  const ConnectionPill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(connectionStatusProvider).value ??
        const Disconnected();
    final host = Uri.tryParse(
            ref.watch(appConfigProvider.select((c) => c.serverUrl)))
        ?.authority;

    return switch (status) {
      Connected() => _pill(
          context,
          dot: UepColors.success,
          text: '已連線${host == null ? '' : ' · $host'}',
          border: context.uep.line,
        ),
      Syncing() || Connecting() => _pill(
          context,
          dot: UepColors.gold,
          text: status is Syncing ? '正在補齊訊息…' : '連線中…',
          border: UepColors.gold.withValues(alpha: .4),
          bg: UepColors.gold.withValues(alpha: .08),
          fg: UepColors.gold,
        ),
      Reconnecting(:final retryAt) => _RetryCountdown(retryAt: retryAt),
      Disconnected(:final tokenRejected) => _pill(
          context,
          dot: UepColors.error,
          text: tokenRejected ? 'TOKEN 無效' : '已離線',
          border: UepColors.error.withValues(alpha: .4),
          bg: UepColors.error.withValues(alpha: .08),
          fg: UepColors.error,
        ),
    };
  }
}

Widget _pill(
  BuildContext context, {
  required Color dot,
  required String text,
  required Color border,
  Color? bg,
  Color? fg,
}) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      border: Border.all(color: border),
      borderRadius: BorderRadius.circular(999),
      color: bg,
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(shape: BoxShape.circle, color: dot),
      ),
      const SizedBox(width: 7),
      Text(
        text.toUpperCase(),
        style: UepText.mono(
            size: 9, color: fg ?? context.uep.inkSoft, letterSpacing: 1.2),
      ),
    ]),
  );
}

/// 重連倒數 + 點擊立即重試。
class _RetryCountdown extends ConsumerStatefulWidget {
  const _RetryCountdown({required this.retryAt});

  final DateTime retryAt;

  @override
  ConsumerState<_RetryCountdown> createState() => _RetryCountdownState();
}

class _RetryCountdownState extends ConsumerState<_RetryCountdown> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
        const Duration(milliseconds: 500), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.retryAt.difference(DateTime.now());
    final secs = remaining.inSeconds.clamp(0, 999);
    return Tooltip(
      message: '點擊立即重試',
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => ref.read(realtimeServiceProvider).retryNow(),
        child: _pill(
          context,
          dot: UepColors.gold,
          text: '重連中 · $secs 秒後重試',
          border: UepColors.gold.withValues(alpha: .4),
          bg: UepColors.gold.withValues(alpha: .08),
          fg: UepColors.gold,
        ),
      ),
    );
  }
}
