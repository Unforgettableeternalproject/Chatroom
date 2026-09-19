import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../l10n/l10n.dart';
import '../state/app_providers.dart';
import '../ws/realtime_service.dart';

/// 標題列的連線狀態 pill（設計稿 top bar 三態 + syncing）。
class ConnectionPill extends ConsumerWidget {
  const ConnectionPill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final status = ref.watch(connectionStatusProvider).value ??
        const Disconnected();
    final host = Uri.tryParse(
            ref.watch(appConfigProvider.select((c) => c.serverUrl)))
        ?.authority;

    return switch (status) {
      Connected() => _pill(
          context,
          dot: UepColors.success,
          text: host == null
              ? l10n.commonConnected
              : l10n.commonConnectedHost(host),
          border: context.uep.line,
        ),
      Syncing() || Connecting() => _pill(
          context,
          dot: UepColors.gold,
          text: status is Syncing ? l10n.commonSyncing : l10n.commonConnecting,
          border: UepColors.gold.withValues(alpha: .4),
          bg: UepColors.gold.withValues(alpha: .08),
          fg: UepColors.gold,
        ),
      Reconnecting(:final retryAt) => _RetryCountdown(retryAt: retryAt),
      Disconnected(:final tokenRejected) => _pill(
          context,
          dot: UepColors.error,
          text: tokenRejected ? l10n.commonTokenInvalid : l10n.commonOffline,
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
            size: 10, color: fg ?? context.uep.inkSoft, letterSpacing: 1.2),
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
    final secs = remaining.inSeconds.clamp(0, 999).toInt();
    return Tooltip(
      message: AppLocalizations.of(context).commonRetryNowTooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => ref.read(realtimeServiceProvider).retryNow(),
        child: _pill(
          context,
          dot: UepColors.gold,
          text: AppLocalizations.of(context).commonReconnectingIn(secs),
          border: UepColors.gold.withValues(alpha: .4),
          bg: UepColors.gold.withValues(alpha: .08),
          fg: UepColors.gold,
        ),
      ),
    );
  }
}
