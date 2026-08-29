import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_settings.dart';
import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../notifications/taskbar_badge.dart';
import '../../state/app_providers.dart';
import '../../state/notification_providers.dart';
import '../../state/rooms_providers.dart';
import '../../widgets/uep_button.dart';
import '../../widgets/version_banner.dart';
import '../../widgets/connection_pill.dart';
import '../rooms/room_list_screen.dart';

/// 設定不完整的診斷結果——`null` 表示設定齊全。
///
/// 判準刻意涵蓋「存過但沒存完」：router 的首次啟動導向只看「曾經存過
/// server URL」，token 是空的照樣放行進主畫面，接著每一支 API 都 401，
/// 而畫面上只有一片空房間列表——**看起來像沒有房間，不像沒有設定**。
String? settingsGapMessage({
  required bool hasServerConfig,
  required String serverUrl,
  required String token,
}) {
  if (!hasServerConfig || serverUrl.trim().isEmpty) {
    return '尚未儲存伺服器位址。目前用的是預設值，連不到任何 Hub。';
  }
  if (token.trim().isEmpty) {
    return 'API token 是空的。伺服器會拒絕每一次請求（401），'
        '房間列表因此永遠是空的。';
  }
  return null;
}

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

  /// 設定缺口警告在這個 shell 的生命週期內只彈一次——關掉之後不再打斷，
  /// 但下次啟動仍會再提醒（設定沒補齊，問題就還在）。
  bool _warnedSettingsGap = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _connectivity =
        Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (online) ref.read(realtimeServiceProvider).retryNow();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncForeground(WidgetsBinding.instance.lifecycleState);
      _warnIfSettingsIncomplete();
    });
  }

  /// 前景狀態餵給通知中心。**只有 `resumed` 算前景**——`inactive`（視窗
  /// 失焦）與 `hidden`（最小化／被切走）都要讓通知照發。
  ///
  /// 初始值刻意從 `lifecycleState` 取而不是預設 true：`didChangeAppLifecycleState`
  /// 只在**變化時**觸發，App 若不是在前景啟動的，那個猜來的 true 就一直錯著，
  /// 而錯的方向是「把通知吃掉」。
  ///
  /// ⚠️ 殘餘缺口：視窗**有焦點但被別的視窗完全蓋住**時，Flutter 眼中仍是
  /// `resumed`。那種情況要靠平台端的可見性查詢，目前沒有接。
  void _syncForeground(AppLifecycleState? state) {
    if (state == null) return;
    ref.read(notificationCenterProvider).foreground =
        state == AppLifecycleState.resumed;
  }

  Future<void> _clearPendingMentions(String roomId) async {
    final settings = ref.read(settingsRepoProvider);
    if (settings.pendingMentions(roomId) == 0) return;
    await settings.clearPendingMentions(roomId);
    await TaskbarBadge.instance.apply(unhandledCount(
      realtime: ref.read(realtimeServiceProvider),
      pendingInvites: ref.read(myPendingInvitesProvider).length,
      settings: settings,
    ));
  }

  /// 設定沒填完就進到主畫面時，把「為什麼什麼都看不到」講出來。
  ///
  /// 不靠 router 擋——擋不住的正是這一類：URL 存了、token 沒存，
  /// `hasServerConfig` 為真，人就進來了，然後對著空畫面猜。
  Future<void> _warnIfSettingsIncomplete() async {
    if (_warnedSettingsGap || !mounted) return;
    final config = ref.read(appConfigProvider);
    final gap = settingsGapMessage(
      hasServerConfig: ref.read(settingsRepoProvider).hasServerConfig,
      serverUrl: config.serverUrl,
      token: config.token,
    );
    if (gap == null) return;
    _warnedSettingsGap = true;
    final goSettings = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('初始設定還沒完成',
            style: UepText.display(size: 22, color: context.uep.inkTitle)),
        content: Text(
          '$gap\n\n到設定頁填好伺服器位址與 API token，'
          '按「測試連線」確認後再按「儲存設定」——只測試不儲存不會生效。',
          style: UepText.serif(size: 13.5, color: context.uep.inkSoft),
        ),
        actions: [
          UepButton(
            label: '稍後再說',
            variant: UepButtonVariant.outline,
            small: true,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          UepButton(
            label: '前往設定',
            small: true,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (goSettings == true && mounted) context.push('/settings');
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
      // 回到前景＝人來看了，正在看的那個房的待處理 mention 算處理過。
      // 清除原本只掛在「有新訊息進來」上，所以「開著房間但沒有新訊息」
      // 時那個數字會一直掛著——那正是回頭來看的人最常遇到的情況。
      final roomId = ref.read(notificationCenterProvider).activeRoomId;
      if (roomId != null) unawaited(_clearPendingMentions(roomId));
    }
    _syncForeground(state);
  }

  @override
  Widget build(BuildContext context) {
    // 啟動通知管線（跟隨已加入房間 → OS 通知 / 未讀刷新）
    ref.watch(notificationBootstrapProvider);
    final s = context.uep;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final themeMode =
        ref.watch(appConfigProvider.select((c) => c.themeMode));

    return Scaffold(
      backgroundColor: s.bg,
      body: Column(children: [
        // 版本對不上時的警示。放在最上方、所有畫面之上——這條訊息要回答的
        // 是「我看到的東西是不是最新的」，而那個疑問發生在你發現功能不見
        // 的當下，不是在你想起要去翻設定的時候
        const VersionBanner(),
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
