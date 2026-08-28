import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_settings.dart';
import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../state/app_providers.dart';
import '../../widgets/connection_pill.dart';
import '../rooms/room_list_screen.dart';

/// 桌機雙欄 / 手機堆疊的分流（go_router ShellRoute 的 shell）。
/// 也負責生命週期與網路恢復時叫醒重連（UI-DESIGN §4.2 的三個觸發點之二）。
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.child, this.selectedRoomId});

  final Widget child;
  final String? selectedRoomId;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell>
    with WidgetsBindingObserver {
  StreamSubscription<List<ConnectivityResult>>? _connectivity;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _connectivity =
        Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (online) ref.read(realtimeServiceProvider).retryNow();
    });
  }

  @override
  void dispose() {
    _connectivity?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(realtimeServiceProvider).retryNow();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final themeMode =
        ref.watch(appConfigProvider.select((c) => c.themeMode));

    return Scaffold(
      backgroundColor: s.bg,
      body: Column(children: [
        // top bar
        Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(
            color: s.bgSoft,
            border: Border(bottom: BorderSide(color: s.line)),
          ),
          child: Row(children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration:
                  BoxDecoration(border: Border.all(color: UepColors.gold)),
              child: Text('U',
                  style: UepText.display(
                      size: 13,
                      weight: FontWeight.w600,
                      color: UepColors.gold)),
            ),
            const SizedBox(width: 9),
            Text('CHATROOM',
                style: UepText.mono(
                    size: 11, color: s.inkSoft, letterSpacing: 2.0)),
            const Spacer(),
            const ConnectionPill(),
            const SizedBox(width: 12),
            _TopIconButton(
              tooltip: themeMode == ThemeModePref.dark ? '切換亮色' : '切換暗色',
              glyph: themeMode == ThemeModePref.dark ? '☾' : '☀',
              onTap: () =>
                  ref.read(appConfigProvider.notifier).toggleTheme(),
            ),
            const SizedBox(width: 8),
            _TopIconButton(
              tooltip: '設定',
              glyph: '◎',
              onTap: () => context.push('/settings'),
            ),
          ]),
        ),
        Expanded(
          child: wide
              ? Row(children: [
                  SizedBox(
                    width: 272,
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border(right: BorderSide(color: s.line)),
                      ),
                      child: RoomListPane(
                          selectedRoomId: widget.selectedRoomId),
                    ),
                  ),
                  Expanded(child: widget.child),
                ])
              : widget.child,
        ),
      ]),
    );
  }
}

class _TopIconButton extends StatelessWidget {
  const _TopIconButton({
    required this.glyph,
    required this.onTap,
    required this.tooltip,
  });

  final String glyph;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(border: Border.all(color: s.line)),
          child: Text(glyph,
              style: TextStyle(fontSize: 12, color: s.inkSoft)),
        ),
      ),
    );
  }
}

/// 桌機模式下 /rooms 的右欄占位。
class NoRoomSelected extends StatelessWidget {
  const NoRoomSelected({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              border: Border.all(color: UepColors.gold.withValues(alpha: .5))),
          child: Text('U',
              style: UepText.display(
                  size: 24, weight: FontWeight.w600, color: UepColors.gold)),
        ),
        const SizedBox(height: 18),
        Text('選擇一個聊天室開始',
            style: UepText.serif(size: 14, color: s.inkSoft)),
        const SizedBox(height: 6),
        Text('或按左下角「建立房間」，再指派 agent 加入',
            style: UepText.serif(size: 12.5, color: s.inkMute)),
      ]),
    );
  }
}
