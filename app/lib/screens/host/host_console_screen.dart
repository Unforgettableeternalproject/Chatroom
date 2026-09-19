import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/api_exception.dart';
import '../../core/util/env_file.dart';
import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/l10n.dart';
import '../../models/host_kit.dart';
import '../../state/app_providers.dart';
import '../../state/host_actions.dart';
import '../../state/host_kit_providers.dart';
import '../../state/host_probe.dart';
import '../../state/kit_installer.dart';
import '../../state/mcp_kit_providers.dart';
import '../../state/runner_kit_providers.dart';
import '../../state/runs_providers.dart';
import '../../widgets/uep_button.dart';
import '../../widgets/uep_tab_bar.dart';
import 'kit_install_section.dart';

/// 主機控制台——**這台機器上的 Hub**。
///
/// ## 它與這個 App 其餘部分是兩種東西
///
/// App 的其餘部分是**客戶端**：連到某台 Hub，在哪台機器上跑都可以。
/// 這一頁是**遙控器**：它管理本機的 Hub 進程與檔案，只在裝了 host-kit 的
/// 那台機器上有意義（見 kit UI 設計簡報 §6.0）。
///
/// 所以沒有 host-kit 時，通往這裡的入口**整個不存在**——不是變灰。
/// 一個永遠按不動的入口比沒有這個功能更糟。
class HostConsoleScreen extends ConsumerWidget {
  const HostConsoleScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final kit = ref.watch(hostKitProvider).value;
    final mcp = ref.watch(mcpKitProvider).value;
    final runner = ref.watch(runnerKitProvider).value;

    return Scaffold(
      backgroundColor: s.bg,
      appBar: AppBar(
        backgroundColor: s.bgSoft,
        // 與設定頁同一套：display 標題 + 底線。這頁原本用 mono 12 的小字
        // 標題，在其他頁之間看起來像另一個 App 的畫面
        surfaceTintColor: Colors.transparent,
        shape: Border(bottom: BorderSide(color: s.line)),
        title: Text(l10n.hostConsoleTitle,
            style: UepText.pageTitle(color: s.inkTitle)),
        actions: [
          IconButton(
            tooltip: l10n.helpTooltip,
            icon: Icon(Icons.help_outline, size: 18, color: s.inkMute),
            onPressed: () => context.push('/help/host'),
          ),
          IconButton(
            tooltip: l10n.hostRecheckTooltip,
            icon: Icon(Icons.refresh, size: 18, color: s.inkMute),
            onPressed: () {
              ref.invalidate(hostEnvProvider);
              ref.invalidate(hostHealthProvider);
              ref.invalidate(tunnelStatusProvider);
              ref.invalidate(serviceStatusProvider);
              ref.invalidate(mcpKitProvider);
              ref.invalidate(mcpEnvProvider);
              ref.invalidate(mcpBridgeVersionProvider);
              ref.invalidate(mcpStatusProvider);
              ref.invalidate(runnerKitProvider);
              ref.invalidate(runnerConfigProvider);
              ref.invalidate(runnerVersionProvider);
              ref.invalidate(runnerIdProvider);
              ref.invalidate(kitReleaseProvider);
              ref.invalidate(kitPythonProvider);
              ref.invalidate(runnerBusyProvider);
            },
          ),
        ],
      ),
      // 🔴 一包都沒有時這頁**仍然有用**：它是唯一能把三包裝起來的地方。
      // 「沒有 kit 就什麼都別畫」是這個功能存在之前的規則——那時這頁確實
      // 什麼都做不了；現在做得了一件事，而且是第一件事。
      body: (kit == null &&
              mcp == null &&
              runner == null &&
              !ref.watch(kitInstallSupportedProvider))
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  l10n.hostNoKits,
                  style: UepText.serif(size: 15, color: s.inkMute),
                ),
              ),
            )
          // 與設定頁同寬同內距（kPageMaxWidth／32）。原本滿寬 24 內距，在寬視窗上
          // 每一行都拉到螢幕兩端——與其他頁擺在一起時最突兀的就是這件事
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: kPageMaxWidth),
                child: _HostConsoleBody(
                  kit: kit,
                  mcp: mcp,
                  runner: runner,
                  canInstall: ref.watch(kitInstallSupportedProvider),
                ),
              ),
            ),
    );
  }
}

/// 頁內分頁：主持人的事與 agent 接入的事分開放。
///
/// 一個人可以同時是主持人與成員（多半就是），但那兩件事要回答的問題完全
/// 不同——原本一條 ListView 排下來，找「我的 agent 連上了嗎」要先捲過
/// 六個主持人專用的區塊。
///
/// 🔴 **只有一種 kit 時不畫分頁列。** 一個只有一個分頁的分頁列是純粹的
/// 雜訊，還會讓人以為另一邊有東西可看。那時直接顯示那一頁（大標照舊）。
class _HostConsoleBody extends StatefulWidget {
  const _HostConsoleBody({
    required this.kit,
    required this.mcp,
    required this.runner,
    required this.canInstall,
  });

  final HostKit? kit;
  final McpKit? mcp;
  final RunnerKit? runner;

  /// 這台機器裝得了 kit 嗎（Windows）。裝得了的話**三個分頁都在**——
  /// 沒裝的那一頁就是它的安裝入口，而不是一個不存在的分頁。
  final bool canInstall;

  @override
  State<_HostConsoleBody> createState() => _HostConsoleBodyState();
}

class _HostConsoleBodyState extends State<_HostConsoleBody>
    with TickerProviderStateMixin {
  TabController? _tabController;
  int _tabCount = 0;

  /// 這台機器上裝了幾種 kit。
  int get _count => widget.canInstall
      ? 3
      : (widget.kit != null ? 1 : 0) +
          (widget.mcp != null ? 1 : 0) +
          (widget.runner != null ? 1 : 0);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncController();
  }

  @override
  void didUpdateWidget(covariant _HostConsoleBody old) {
    super.didUpdateWidget(old);
    _syncController();
  }

  /// kit 偵測是非同步的，而且三種是**各自**到齊的：`TabController` 的
  /// length 建了就不能改，所以數量變了就換一顆新的。第三種 kit 晚一步
  /// 偵測到時不換的話，分頁列會永遠停在兩個。
  void _syncController() {
    final count = _count;
    if (count < 2) {
      if (_tabController != null) {
        _tabController!.dispose();
        _tabController = null;
        _tabCount = 0;
      }
      return;
    }
    if (_tabController != null && _tabCount == count) return;
    _tabController?.dispose();
    _tabController = TabController(length: count, vsync: this);
    _tabCount = count;
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final kit = widget.kit;
    final mcp = widget.mcp;
    final runner = widget.runner;
    final controller = _tabController;
    final l10n = AppLocalizations.of(context);

    // 索引 0 是 Hub——進來的人多半是為了主持那一半
    final labels = <String>[];
    final pages = <Widget>[];
    if (kit != null || widget.canInstall) {
      labels.add(l10n.hostTabHub);
      pages.add(_hubTab(s, kit));
    }
    if (mcp != null || widget.canInstall) {
      labels.add(l10n.hostTabAgent);
      pages.add(_agentTab(s, mcp));
    }
    if (runner != null || widget.canInstall) {
      labels.add(l10n.hostTabRunner);
      pages.add(_runnerTab(s, runner));
    }

    // 🔴 只有一種 kit 時不畫分頁列（見上面的說明）
    if (pages.length == 1) return pages.first;
    if (controller == null || controller.length != pages.length) {
      return pages.first;
    }
    return Column(
      children: [
        UepTabBar(controller: controller, labels: labels),
        Expanded(
          child: TabBarView(controller: controller, children: pages),
        ),
      ],
    );
  }

  /// 主持人這一半：這台機器上的 Hub 活著嗎、要發什麼給成員、怎麼起停。
  Widget _hubTab(UepSurface s, HostKit? kit) => ListView(
        padding: const EdgeInsets.all(32),
        children: [
          Text(AppLocalizations.of(context).hostTabHub,
              style: UepText.pageTitle(color: s.inkTitle)),
          const SizedBox(height: 22),
          if (kit != null) ...[
            _HealthSection(),
            _sep(s),
            _ShareSection(kit: kit),
            _sep(s),
            const _TunnelSection(),
            _sep(s),
            const _ControlSection(),
            _sep(s),
            _HubEnvSection(kit: kit),
            _sep(s),
            const _DataSection(),
            _sep(s),
            _KitSection(kit: kit),
          ],
          // 裝不了 kit 的機器（手機）上連這一塊都不畫——一顆按不動的
          // 「安裝」比沒有那顆按鈕更糟
          if (widget.canInstall) ...[
            if (kit != null) _sep(s),
            KitInstallSection(kit: KitId.hub, installed: kit != null),
          ],
        ],
      );

  /// 成員這一半：這台機器的 agent 連得上 Hub 嗎。
  Widget _agentTab(UepSurface s, McpKit? mcp) => ListView(
        padding: const EdgeInsets.all(32),
        children: [
          Text(AppLocalizations.of(context).hostTabAgent,
              style: UepText.pageTitle(color: s.inkTitle)),
          const SizedBox(height: 22),
          if (mcp != null) ...[
            _McpSection(kit: mcp),
            _sep(s),
            _McpEnvSection(kit: mcp),
          ],
          if (widget.canInstall) ...[
            if (mcp != null) _sep(s),
            _McpInstallSection(installed: mcp != null),
          ],
        ],
      );

  /// 執行器這一半：這台機器接派工的專案設定。
  Widget _runnerTab(UepSurface s, RunnerKit? runner) => ListView(
        padding: const EdgeInsets.all(32),
        children: [
          Text(AppLocalizations.of(context).hostTabRunner,
              style: UepText.pageTitle(color: s.inkTitle)),
          const SizedBox(height: 22),
          if (runner != null) ...[
            _RunnerWorkspacesSection(kit: runner),
            _sep(s),
            _Panel(
              title: AppLocalizations.of(context).hostInstallPath,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    runner.kitDir.isEmpty ? runner.configPath : runner.kitDir,
                    style: UepText.code(size: 12, color: s.inkSoft),
                  ),
                  const SizedBox(height: 8),
                  _SourceLine(source: runner.source),
                  const _RunnerVersionLine(),
                ],
              ),
            ),
          ],
          if (widget.canInstall) ...[
            if (runner != null) _sep(s),
            _RunnerInstallSection(installed: runner != null),
          ],
        ],
      );
}

/// MCP 那一包的安裝區塊。已裝版本現讀 `mcpBridgeVersionProvider`——
/// 「已經是 Release 那一版了嗎」要拿真的版本去比，不能拿安裝時間猜。
class _McpInstallSection extends ConsumerWidget {
  const _McpInstallSection({required this.installed});

  final bool installed;

  @override
  Widget build(BuildContext context, WidgetRef ref) => KitInstallSection(
        kit: KitId.mcp,
        installed: installed,
        installedVersion: ref.watch(mcpBridgeVersionProvider).value ?? '',
      );
}

/// 執行器那一包的安裝區塊。
class _RunnerInstallSection extends ConsumerWidget {
  const _RunnerInstallSection({required this.installed});

  final bool installed;

  @override
  Widget build(BuildContext context, WidgetRef ref) => KitInstallSection(
        kit: KitId.runner,
        installed: installed,
        installedVersion: ref.watch(runnerVersionProvider).value ?? '',
      );
}

/// 區塊之間的分隔——與設定頁同一組間距（26／線／22）。
///
/// 用分隔線而不是把每塊包成有邊框的卡片：卡片在這頁會疊出七個框，
/// 而設定頁是一條線分段。兩頁擺在一起時，框與線的差別比字級更顯眼。
Widget _sep(UepSurface s) => Column(
      children: [
        const SizedBox(height: 26),
        Divider(color: s.line, height: 1),
        const SizedBox(height: 22),
      ],
    );

/// 三盞燈。
class _HealthSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final health = ref.watch(hostHealthProvider);
    final l10n = AppLocalizations.of(context);

    return _Panel(
      title: l10n.hostPanelStatus,
      // 主持人多半只是想確認一切正常，所以三盞燈要能一眼掃過去——
      // 「掃視」比「操作」重要（設計稿 §5）
      child: health.when(
        loading: () => _LightRow(
          label: l10n.hostLabelChecking,
          probe: Probe.checking(),
        ),
        error: (e, _) => _LightRow(
          label: l10n.hostLabelCheckFailed,
          probe: Probe(ProbeState.unknown, '$e'),
        ),
        data: (h) {
          if (h == null) {
            return _LightRow(
              label: l10n.settingsTitle,
              probe: Probe(ProbeState.unknown, l10n.hostEnvMissing),
            );
          }
          return Column(children: [
            _LightRow(label: l10n.hostLabelProcess, probe: h.process),
            const SizedBox(height: 14),
            _LightRow(label: l10n.hostLabelBinding, probe: h.reachable),
            const SizedBox(height: 14),
            _LightRow(label: l10n.hostLabelAuth, probe: h.auth),
          ]);
        },
      ),
    );
  }
}

/// 一盞燈。
///
/// 🔴 **形狀與顏色一起帶語意**：`unknown` 是**空心**的灰圈，不是一個偏白的
/// 綠或紅。它的意思是「沒有資訊」，而不是「有問題但還好」——
/// 用實心的暖色（橙／黃）會讓它讀起來像警告，主持人於是跑去修一個沒有壞的
/// 東西。空心也讓色盲的人分得出來。
///
/// 沿用既有色票，**不新增顏色**：好＝`success`、壞＝`error`、
/// 不確定＝`inkMute`（這個系統裡「沒有資訊」本來就是這個灰）。
class _LightRow extends StatelessWidget {
  const _LightRow({required this.label, required this.probe});

  final String label;
  final Probe probe;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final (color, filled) = switch (probe.state) {
      ProbeState.ok => (UepColors.success, true),
      ProbeState.bad => (UepColors.error, true),
      ProbeState.unknown => (s.inkMute, false),
      ProbeState.checking => (s.inkMute, false),
    };

    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Container(
          width: 11,
          height: 11,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled ? color : Colors.transparent,
            border: Border.all(color: color, width: 1.4),
          ),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text(label, style: UepText.fieldLabel(color: s.inkMute)),
              const SizedBox(width: 10),
              Flexible(
                child: Text(probe.detail,
                    style: UepText.serif(size: 14.5, color: s.ink)),
              ),
            ]),
            // ⚠️ **綠燈也可能有 caveat。** 「本機打得到」不等於「別台機器
            // 連得到」，而那個落差是主持人最常撞、也最難自己想到的一關
            if (probe.caveat.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(probe.caveat,
                  style: UepText.serif(
                      size: 12.5, color: s.inkMute, height: 1.5)),
            ],
          ],
        ),
      ),
    ]);
  }
}

/// 要發給成員的東西。
///
/// **常駐，不是 install.py 結尾印一次。** 隧道網址每次重開都會變、每次都要
/// 重發給所有人——那件事該是一個「複製」動作，而不是從一堆輸出裡把它找出來。
class _ShareSection extends ConsumerWidget {
  const _ShareSection({required this.kit});

  final HostKit kit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final env = ref.watch(hostEnvProvider).value;

    if (env == null || !env.isComplete) {
      return _Panel(
        title: l10n.hostPanelConnectionInfo,
        child: Text(l10n.hostEnvUnreadable,
            style: UepText.serif(size: 14, color: s.inkMute)),
      );
    }

    // 綁 0.0.0.0 時字面上的位址沒有意義——**沒有人連得到 0.0.0.0**。
    // 這裡不猜一個 IP 填進去（猜錯比留白更糟），而是講明要填什麼
    final address = env.bindsAllInterfaces
        ? l10n.hostAddressAnyInterface(env.port)
        : 'http://${env.host}:${env.port}';

    return _Panel(
      title: l10n.hostPanelConnectionInfo,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CopyRow(label: l10n.fieldHubUrl, value: address),
          const SizedBox(height: 10),
          // 🔴 **憑證分離之後這裡不能只有一把。**
          //
          // `CHATROOM_TOKEN` 從分離那一刻起是 **agent 專用**——拿它的人類
          // 開不了主持人模式、發不了邀請，而錯誤訊息是 `root_token_required`，
          // 看起來像「這台 Hub 不是你主持的」。主持人照著複製給人類成員，
          // 對方會拿到一把宣稱不了自己是人的鑰匙。
          //
          // 分離前（legacy）只有一把而且是萬用的，那時多畫一個欄位只會
          // 讓人以為自己少了什麼東西——所以兩種狀態畫的不一樣。
          if (env.credentialsSplit) ...[
            _CopyRow(
                label: l10n.hostFieldHumanToken,
                value: env.humanToken,
                secret: true),
            const SizedBox(height: 10),
            _CopyRow(
                label: l10n.hostFieldAgentToken,
                value: env.token,
                secret: true),
            const SizedBox(height: 12),
            Text(
              l10n.hostAgentTokenNote,
              style: UepText.serif(size: 13, color: s.inkMute, height: 1.6),
            ),
          ] else ...[
            _CopyRow(
                label: l10n.hostFieldToken, value: env.token, secret: true),
            const SizedBox(height: 12),
            Text(
              l10n.hostSharedTokenNote,
              style: UepText.serif(size: 13, color: s.inkMute, height: 1.6),
            ),
          ],
          if (env.bindsAllInterfaces) ...[
            const SizedBox(height: 6),
            Text(
              l10n.hostBindAllNote,
              style: UepText.serif(size: 13, color: s.inkMute, height: 1.6),
            ),
          ],
        ],
      ),
    );
  }
}

/// Agent 接入（MCP）——**這台機器的 agent 連得上 Hub 嗎**。
///
/// 成員端要回答的三題：連得上嗎、我是誰、agent 認得那些工具了嗎。
/// 前兩題這裡答得了；**第三題答不了**，見底下的安裝時間那段。
class _McpSection extends ConsumerWidget {
  const _McpSection({required this.kit});

  final McpKit kit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(mcpStatusProvider);
    final env = ref.watch(mcpEnvProvider).value;
    final l10n = AppLocalizations.of(context);

    return _Panel(
      title: l10n.hostPanelBridgeStatus,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          status.when(
            loading: () => _LightRow(
                label: l10n.settingsTabConnection, probe: Probe.checking()),
            error: (e, _) => _LightRow(
                label: l10n.settingsTabConnection,
                probe: Probe(ProbeState.unknown, '$e')),
            data: (m) {
              if (m == null) {
                return _LightRow(
                  label: l10n.settingsTitle,
                  probe: Probe(ProbeState.unknown, l10n.hostMcpEnvMissing),
                );
              }
              return Column(children: [
                _LightRow(label: l10n.settingsTabConnection, probe: m.reach),
                const SizedBox(height: 14),
                _LightRow(label: l10n.hostLabelAuth, probe: m.auth),
              ]);
            },
          ),
          if (env != null && env.url.isNotEmpty) ...[
            const SizedBox(height: 14),
            _CopyRow(label: l10n.hostFieldConnectedHub, value: env.url),
          ],
          const SizedBox(height: 16),
          _VersionCheck(kit: kit),
        ],
      ),
    );
  }
}

/// 版本對照：**已安裝的** bridge，與 agent **實際跑著的**那份。
///
/// 🔴 App 看不到 agent 的進程，所以「agent 認得那些工具了嗎」這一題它答不了
/// ——不畫燈是對的（畫綠燈會騙人：設定檔是新的、跑著的不是）。
///
/// ⚠️ 但第一版的提醒犯了今天反覆出現的那個錯：它寫「你的 agent 如果在安裝
/// 之前就開著」——**而使用者不知道自己的 agent 是什麼時候開的**
/// （Claude Code 與 Codex 都沒有顯示啟動時間）。那是要求他做一件他做不到的
/// 比較，與「叫 agent 從 # 候選重選一次」是同一個形狀。
///
/// 一度改成「讓 agent 自己說」（測試Novia 09/09 房 seq 170）——每個 chatroom
/// 工具的說明結尾都帶著 `〔bridge x.y.z+commit〕`。**但那條也不成立**，她隨即
/// 自己推翻（seq 190 實測）：**宿主端會快取工具描述**，同一個 bridge 進程、
/// 同一刻，三個工具報出三個不同的版本——舊的那些是升級前載過的殘留。
///
/// 照著它做的人，碰巧問到快取的工具就會去重啟一個不必重啟的 agent；
/// 反過來也可能讓真的該重啟的人以為自己是新的。
///
/// ✅ **現在有一條驗證過的查法了**：Hub 讓 `chatroom_join` 的回傳帶
/// `bridge.commit`（`9a394e4`），而**回傳是跑著的進程當場產生的，沒有快取層**。
/// 測試Novia 在真機實測（seq 208）——同一次重連裡，三支工具的說明結尾報出
/// 三個過期版本、沒有一支說對，而 `join` 的回傳當場給了正確答案。
///
/// 所以指示指向 `chatroom_join` 的回傳，並**明講不要看工具說明結尾**——
/// 那個數字報的是「這支工具的描述何時載入」，與 bridge 跑什麼無關。
///
/// ⚠️ 這一段的字句改過三次（比對安裝時間 → 看工具說明 → 重啟就對了 →
/// 現在這版），每一次都是因為前一版要求使用者做一件他做不到或會被誤導的事。
/// **要改它之前，先確認新的判準有人在真機上驗過。**
class _VersionCheck extends ConsumerWidget {
  const _VersionCheck({required this.kit});

  final McpKit kit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final version = ref.watch(mcpBridgeVersionProvider).value ?? '';
    final when = kit.installedAt.isEmpty
        ? ''
        : kit.installedAt.replaceFirst('T', ' ').replaceFirst('+00:00', ' UTC');

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: s.bgSunken,
        border: Border.all(color: s.line),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.hostBridgeVersion,
              style: UepText.fieldLabel(color: s.inkMute)),
          const SizedBox(height: 5),
          SelectableText(
            version.isEmpty ? l10n.hostBridgeVersionUnknown : version,
            style: UepText.code(
                size: 13,
                color: version.isEmpty ? s.inkMute : UepColors.gold),
          ),
          if (version.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              l10n.hostBridgeVerifyHint,
              style: UepText.serif(size: 12.5, color: s.inkMute, height: 1.6),
            ),
          ],
          const SizedBox(height: 10),
          // 次要資訊：對照不上時拿來判斷「這包是什麼時候、裝給誰的」
          Wrap(spacing: 18, runSpacing: 4, children: [
            _SourceLine(source: kit.source),
            if (when.isNotEmpty)
              Text(l10n.hostInstalledAt(when),
                  style: UepText.code(size: 11.5, color: s.inkMute)),
            if (kit.targets.isNotEmpty)
              Text(l10n.hostInstalledFor(kit.targets.join('、')),
                  style: UepText.code(size: 11.5, color: s.inkMute)),
          ]),
        ],
      ),
    );
  }
}

/// 對外協作（隧道）。
class _TunnelSection extends ConsumerWidget {
  const _TunnelSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(tunnelStatusProvider);
    final actions = ref.watch(hostActionsProvider);
    final op = _opOf(ref, _tunnelKinds);
    final tunnelOpening = _isPending(ref, 'tunnel_start');
    final l10n = AppLocalizations.of(context);

    return _Panel(
      title: l10n.hostPanelTunnel,
      child: status.when(
        loading: () =>
            _LightRow(label: l10n.hostPanelStatus, probe: Probe.checking()),
        error: (e, _) => _LightRow(
            label: l10n.hostPanelStatus,
            probe: Probe(ProbeState.unknown, '$e')),
        data: (t) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _LightRow(
              label: l10n.hostPanelStatus,
              probe: Probe(t.state, t.detail, caveat: t.caveat),
            ),
            if (t.hasUrl) ...[
              const SizedBox(height: 12),
              _CopyRow(label: l10n.hostFieldTunnelUrl, value: t.url),
            ],
            if (actions != null && Platform.isWindows) ...[
              const SizedBox(height: 14),
              Row(children: [
                // 開隧道比啟動 Hub 更需要「進行中」：cloudflared 要先跟
                // Cloudflare 要一個網址，那是**好幾秒**的往返。沒有進行中
                // 狀態的話使用者會在網址出現之前再按一次，而每按一次就是
                // 多一條隧道——下面那段註解說的「隧道越積越多」就是這樣來的
                //
                // 🚨 **已經有一條在跑時整個封掉，這是安全問題不是體驗問題。**
                // 隧道的狀態只有一組檔案（`.tunnel-url` / `.tunnel-pid`）⇒
                // 開第二條會把第一條的紀錄蓋掉 ⇒ **第一條仍然對外開著，但
                // UI 與 `stop-tunnel.py` 都已經指不到它**（後者會比對 PID，
                // 對不上就拒絕動手，那是它該做的事）。結果是一條沒有人管得到
                // 的公開入口，而主持人不會知道它還在
                // （審核用Codex 09/14，既有行為，本次重審才發現）。
                //
                // 要換一條就先關現在這條——那條路是有的，就在旁邊。
                UepButton(
                  small: true,
                  variant: UepButtonVariant.outline,
                  // 🔴 **`hasUrl` 只代表那個檔案非空，不代表隧道活著。**
                  // `.tunnel-url` 會殘留（見 `tunnelStatusProvider` 的註解），
                  // 所以打不通時（`unknown`）按鈕不能斷言「已經有一條」——
                  // 那句話在一條早就死掉的隧道上是假的，而它同時是唯一的
                  // 開啟入口。禁用照舊（殘留與「活著只是繞不回來」在這台
                  // 機器上分不出來，而後者開第二條就是那個安全問題），
                  // 但字要講它真正知道的事：偵測到一個舊網址。
                  label: tunnelOpening
                      ? l10n.hostTunnelOpening
                      : !t.hasUrl
                          ? l10n.hostTunnelOpenButton
                          : (t.state == ProbeState.unknown
                              ? l10n.hostTunnelStaleUrl
                              : l10n.hostTunnelAlreadyOne),
                  onPressed: (tunnelOpening || t.hasUrl)
                      ? null
                      : () => _confirmTunnel(context, ref, actions),
                ),
                if (t.hasUrl) ...[
                  const SizedBox(width: 10),
                  // 🔴 這顆按鈕原本刻意不做，理由是「做一顆按鈕去殺別人的
                  // 進程，會在殺錯的時候完全看不出來」。顧慮成立，但代價是
                  // 使用者只剩「去把那個黑視窗關掉」一條路——而那條路沒有人
                  // 告訴過他，於是他能做的只有「再開一條」，隧道越積越多。
                  //
                  // 解法不是不做，是讓它認得出殺的是誰：`stop-tunnel.py`
                  // 比對 `.tunnel-pid` 記下的 PID 與它現在的命令列，對不上
                  // 就拒絕動手。
                  UepButton(
                    small: true,
                    variant: UepButtonVariant.outline,
                    label: l10n.hostTunnelCloseButton,
                    onPressed: () => _confirmStopTunnel(context, ref),
                  ),
                ],
              ]),
            ],
            // 隧道自己的操作結果，放在它的按鈕底下
            if (op != null) ...[
              const SizedBox(height: 14),
              _OpResult(result: op),
            ],
          ],
        ),
      ),
    );
  }

  /// 🔴 **警告要出現在它有意義的那一刻。**
  ///
  /// `host-kit/README.md` 有一整段把 token 的信任邊界寫得很清楚，但它在
  /// 第 60 行——而**不讀 README 正是這個介面要服務的族群**
  /// （設計稿 §5 第一條）。這段話真正需要被讀到的時刻就是現在。
  ///
  /// 為了不變成一個被反射性關掉的對話框：**講後果，不講規則**，而且確認鈕
  /// 上寫的是它實際會做的事（「開隧道」），不是「確定」。
  Future<void> _confirmTunnel(
    BuildContext context, WidgetRef ref, HostActions actions) async {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: s.bgCard,
        title: Text(l10n.hostTunnelConfirmTitle,
            style: UepText.serif(
                size: 15, weight: FontWeight.w600, color: s.inkTitle)),
        content: Text(
          l10n.hostTunnelConfirmBody,
          style: UepText.serif(size: 14, color: s.ink, height: 1.7),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel,
                style: UepText.serif(size: 14, color: s.inkMute)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.commonOpen,
                style: UepText.serif(size: 14, color: UepColors.gold)),
          ),
        ],
      ),
    );
    if (go != true) return;
    // 隧道要幾秒才拿得到網址（cloudflared 要先跟 Cloudflare 要一個）。
    // 原本這裡是固定等 4 秒再 invalidate 一次——**等夠了就看得到、不夠就
    // 看不到**，而「還在要網址」與「要失敗了」在畫面上長一樣。改成盯著
    // 狀態等，並在等的期間把按鈕標成「開通中…」。
    //
    // 判準用網址而不是隧道燈號：那盞燈在本機打不通自己的公網網址時會是
    // unknown（hairpin，見 tunnelStatusProvider 的註解），拿它當成功條件的
    // 話，一條開好的隧道會被判成沒開。
    //
    // 🔴 **但「有網址」也不是成功的證據——要「換了一條網址」。**
    // `.tunnel-url` 會殘留（provider 自己的註解就寫了：視窗被強制關掉、
    // 當機、斷電時 finally 不執行，檔案留在原地）。拿 `hasUrl` 當條件的話，
    // 一個殘留的死網址會讓畫面立刻說「隧道開了」，而那條隧道早就沒了
    // ——然後主持人把那個網址發給所有人（審核用Codex 09/14 終審）。
    //
    // 記下按之前是哪一條，要求它**變成別的**。重開必定是新網址，所以
    // 「一樣」只可能是還沒換掉。
    // ⚠️ **快照要先 invalidate 才是「現在的」。** 直接 read 拿到的是畫面
    // 上那份可能早就過期的快取：畫面記得「沒有網址」，而磁碟上其實躺著一條
    // 殘留的舊網址 ⇒ 快照記成空字串 ⇒ 之後輪詢讀到那條舊的，`!= ''` 成立
    // ⇒ **假綠燈，而且指向一條死掉的隧道**（審核用Codex 09/14）。
    //
    // ⚠️ 快照**交給 `runOp` 去取**，不要在這裡先 await 一次再傳進去：那次
    // 現讀要打外網、可能好幾秒，而 pending 是 `_launchAndWatch` 進去之後才
    // 掛的 ⇒ 中間那段按鈕還能按 ⇒ 第二條隧道（審核用Codex 09/14）。
    await _launchAndWatch(
      ref,
      kind: 'tunnel_start',
      baseline: () async {
        ref.invalidate(tunnelStatusProvider);
        return (await ref.read(tunnelStatusProvider.future)).url;
      },
      baselineFailText: l10n.hostTunnelBaselineFail,
      launch: actions.startTunnel,
      ready: (beforeUrl) async {
        ref.invalidate(tunnelStatusProvider);
        final t = await ref.read(tunnelStatusProvider.future);
        return t.hasUrl && t.url != beforeUrl;
      },
      okText: l10n.hostTunnelOpened,
      timeoutText: l10n.hostTunnelOpenTimeout,
    );
  }

  /// 關閉隧道。
  ///
  /// 要確認，但講的後果與開隧道那個不同：關掉之後**網址永久失效**，
  /// 而外面的人手上拿的就是那個網址。重開會是新的一條，要重發給所有人。
  Future<void> _confirmStopTunnel(BuildContext context, WidgetRef ref) async {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: s.bgCard,
        title: Text(l10n.hostTunnelCloseButton,
            style: UepText.serif(
                size: 15, weight: FontWeight.w600, color: s.inkTitle)),
        content: Text(
          l10n.hostStopTunnelBody,
          style: UepText.serif(size: 14, color: s.ink, height: 1.7),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel,
                style: UepText.serif(size: 14, color: s.inkMute)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.hostTunnelCloseButton,
                style: UepText.serif(size: 14, color: UepColors.gold)),
          ),
        ],
      ),
    );
    if (go != true) return;

    final actions = ref.read(hostActionsProvider);
    if (actions == null) return;
    final result = parseScriptResult(await actions.stopTunnel());
    ref.invalidate(tunnelStatusProvider);
    // 腳本拒絕動手時（PID 被重用、權限不足）要把理由講出來——
    // 靜靜地什麼都沒發生，與成功關閉在畫面上長得一樣
    ref.read(lastDataOpProvider.notifier).set({
      'kind': 'tunnel_stop',
      ...result,
    });
  }
}

/// 起停與自啟。
class _ControlSection extends ConsumerWidget {
  const _ControlSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ref.watch(hostActionsProvider);
    if (actions == null) return const SizedBox.shrink();

    // 服務註冊是排程任務，只有 Windows 有。**藏起來而不是顯示為失敗**——
    // 那不是壞掉，是這台機器沒有那個東西（設計稿 §6.3）
    final windows = Platform.isWindows;
    final service = ref.watch(serviceStatusProvider).value;
    final health = ref.watch(hostHealthProvider).value;
    // 進行中與結果都從 provider 讀，不放 State——這個區塊是 ConsumerWidget，
    // 而且任何一次狀態刷新都會重建它（理由同 `lastDataOpProvider` 那段註解）
    final op = _opOf(ref, _controlKinds);
    // 按鈕看自己那一格，顯示看這一區最新的——見 `_isPending` 上方
    final hubStarting = _isPending(ref, 'hub_start');
    final l10n = AppLocalizations.of(context);

    return _Panel(
      title: 'Hub',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (windows) ...[
            _StatusLine(
              label: l10n.hostPanelStatus,
              value: switch (health?.process.state) {
                ProbeState.ok => l10n.hostProbeRunning,
                ProbeState.bad => l10n.hostProbeStopped,
                _ => '—',
              },
            ),
            const SizedBox(height: 10),
            Row(children: [
              // 🔴 **啟動也要講結果，理由與旁邊那顆停止一樣**（停止那半的
              // 註解已經寫過一次）。原本這裡是 `await startHub()` ＋ 等 3 秒
              // ＋ invalidate，**期間畫面完全不動**：按下去沒有任何變化，
              // 三秒後燈可能亮也可能不亮，而「還在啟動」與「根本沒起來」
              // 在畫面上長一樣（艾斯維爾 09/14：按了不知道有沒有成功）。
              //
              // ⚠️ **停止那半的模式在這裡抄不動**：`startHub` 走
              // `Process.start(detached)`，沒有 exit code 也沒有輸出可以解析
              // ——腳本的結果拿不到。所以啟動的「結果」只能是**去問狀態**：
              // 起來了沒。這是兩種操作的本質差別，不是少做一步。
              UepButton(
                small: true,
                label: hubStarting
                    ? l10n.hostHubStarting
                    : l10n.hostHubStartButton,
                onPressed:
                    hubStarting ? null : () => _startHub(ref, actions, l10n),
              ),
              const SizedBox(width: 10),
              // 🔴 停止要放在啟動旁邊，不是放在「自啟」那一區。
              //
              // 它包的 `hub-service.ps1 stop` 殺的是**所有** chatroom_server
              // 進程——前景視窗裡那個也算。擺在自啟區底下時它讀起來是
              // 「停掉排程」，於是前景起 Hub 的人只剩「去關那個黑視窗」
              // 這條路，而那條路從來沒有人告訴過他。
              UepButton(
                small: true,
                variant: UepButtonVariant.outline,
                label: l10n.hostHubStopButton,
                onPressed: () => _confirmStop(context, ref),
              ),
            ]),
            const SizedBox(height: 18),
            _StatusLine(
              label: l10n.hostAutoStartLabel,
              value: service?.registered == true
                  ? l10n.hostServiceRegistered
                  : l10n.hostServiceUnregistered,
            ),
            const SizedBox(height: 10),
            Wrap(spacing: 10, runSpacing: 10, children: [
              UepButton(
                small: true,
                variant: UepButtonVariant.outline,
                label: service?.registered == true
                    ? l10n.hostServiceReregister
                    : l10n.hostServiceRegister,
                onPressed: () => _runService(ref, 'install'),
              ),
              UepButton(
                small: true,
                variant: UepButtonVariant.outline,
                label: l10n.hostServiceStart,
                onPressed: () => _runService(ref, 'start'),
              ),
              // 停止不在這裡——它是全域的（連前景起的都殺），放在上面
              // 「啟動 Hub」旁邊。同一件事出現兩個入口只會讓人以為
              // 這顆停的是排程、那顆停的是前景
              if (service?.registered == true)
                UepButton(
                  small: true,
                  variant: UepButtonVariant.outline,
                  label: l10n.hostServiceUninstall,
                  onPressed: () => _runService(ref, 'uninstall'),
                ),
            ]),
            const SizedBox(height: 18),
          ],
          Wrap(spacing: 10, runSpacing: 10, children: [
            UepButton(
                small: true,
                variant: UepButtonVariant.outline,
                label: l10n.hostOpenLogs,
                onPressed: actions.openLogs),
            UepButton(
                small: true,
                variant: UepButtonVariant.outline,
                label: l10n.hostOpenBackups,
                onPressed: actions.openBackups),
          ]),
          // 這一區自己的操作結果。**放在按鈕底下**，不是放到頁尾那個
          // 「資料與安全」框裡——見 `_controlKinds` 上方那段
          if (op != null) ...[
            const SizedBox(height: 14),
            _OpResult(result: op),
          ],
        ],
      ),
    );
  }

  /// 這台機器上的 Hub 現在在不在跑。
  ///
  /// 判準用 `process.state == ok`——那是「這台機器上有 Hub 在跑」，不是
  /// 「網路連得到」。啟動這件事要回答的正是前者。
  static Future<bool> _hubRunning(WidgetRef ref) async {
    ref.invalidate(hostHealthProvider);
    final h = await ref.read(hostHealthProvider.future);
    return h?.process.state == ProbeState.ok;
  }

  /// 啟動 Hub。
  ///
  /// 🔴 **先問「它本來就在跑嗎」，因為「現在是 ok」不等於「這次啟動成功」。**
  /// Hub 已經在跑的時候按這顆，第一次輪詢立刻看到 ok ⇒ 畫面說「Hub 起來
  /// 了」——即使底下那個腳本根本失敗了。**那是一句沒有根據的成功宣告**，
  /// 比沒有回饋更糟，因為它會讓人停止追查（審核用Codex 09/14 終審）。
  ///
  /// 已經在跑就**不送出啟動**：那條路只會多出一個進程，而使用者按這顆多半
  /// 是想確認它活著，不是想要第二個。想重啟的人有旁邊那顆「停止 Hub」。
  Future<void> _startHub(
          WidgetRef ref, HostActions actions, AppLocalizations l10n) =>
      _launchAndWatch(
        ref,
        kind: 'hub_start',
        alreadyDone: () => _hubRunning(ref),
        alreadyText: l10n.hostHubAlreadyRunning,
        launch: actions.startHub,
        ready: (_) => _hubRunning(ref),
        okText: l10n.hostHubStarted,
        timeoutText: l10n.hostHubStartTimeout,
      );

  Future<void> _runService(WidgetRef ref, String action) async {
    final actions = ref.read(hostActionsProvider);
    if (actions == null) return;
    await actions.service(action);
    ref.invalidate(serviceStatusProvider);
    ref.invalidate(hostHealthProvider);
  }

  /// 停止要確認——**它會把所有人踢下線**，而按的人往往只是想重啟一下。
  ///
  /// 講後果不講規則，確認鈕上寫實際會做的事（設計稿 §5，與開隧道那個
  /// 對話框同一套判準）。
  Future<void> _confirmStop(BuildContext context, WidgetRef ref) async {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: s.bgCard,
        title: Text(l10n.hostHubStopButton,
            style: UepText.serif(
                size: 15, weight: FontWeight.w600, color: s.inkTitle)),
        content: Text(
          l10n.hostStopHubBody,
          style: UepText.serif(size: 14, color: s.ink, height: 1.7),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel,
                style: UepText.serif(size: 14, color: s.inkMute)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.hostHubStopButton,
                style: UepText.serif(size: 14, color: UepColors.gold)),
          ),
        ],
      ),
    );
    if (go != true) return;
    final actions = ref.read(hostActionsProvider);
    if (actions == null) return;

    // 🔴 **結果一定要講出來。**
    //
    // 這裡原本是 `await actions.stopHub();`——呼叫完就把結果丟掉。於是
    // 腳本那句「埠 xxxx 仍有監聽」永遠到不了使用者：他按了停止、畫面什麼
    // 都沒說，而 Hub 還活著、連著的人一個都沒斷。2026-09-12 實際發生。
    //
    // 同一天寫的「關閉隧道」有解析結果並顯示，這一顆沒有——**兩顆按鈕、
    // 同一個人、一顆講一顆不講**，那個不一致本身就是缺陷。
    final raw = await actions.stopHub();
    ref.invalidate(serviceStatusProvider);
    ref.invalidate(hostHealthProvider);

    // 這支腳本輸出的是人話不是 JSON（它講得夠清楚，重寫一遍只會讓兩邊
    // 不一致）。判準：stderr 有東西＝Write-Warning 被觸發＝沒有完全停掉
    final out = '${raw.stdout}'.trim();
    final err = '${raw.stderr}'.trim();
    ref.read(lastDataOpProvider.notifier).set({
      'kind': 'hub_stop',
      'ok': err.isEmpty,
      'detail': err.isNotEmpty
          ? err
          : (out.isNotEmpty ? out : l10n.hostHubStopped),
    });
  }
}

/// 最近一次備份／換 token 的結果。
///
/// 🔴 **不放在 widget 的 State 裡。** 這一頁的 provider 一 invalidate
/// （按了「重新檢查」、或任何一個狀態刷新）整個子樹就重建，那時剛換出來的
/// token 會跟著消失——而它是隨機字串，畫面上那一次是使用者唯一看得到它的
/// 機會。同樣的形狀在這個 repo 已經咬過四次（草稿存在 State 裡）。
/// 每種操作**各自一格**，key 是 `kind`。
///
/// 🔴 **單格會把還在跑的操作蓋掉。** 原本這裡只存一筆：Hub 啟動輪詢中
/// （`pending`）時去按備份或開隧道，那一筆就被換掉 ⇒ 啟動區的 `_opOf`
/// 得到 null ⇒ **按鈕從「啟動中…」變回「啟動 Hub」，再按一次就啟第二個
/// Hub 進程**。之後兩條輪詢還會各自寫結果，順序由誰先起來決定。
///
/// 比「沒有回饋」更糟——沒有回饋時使用者至少不會以為可以再按
/// （審核用Codex 09/14 終審）。
///
/// `_seq` 是寫入序號：同一區可能有好幾種 kind（起、停、服務），要挑
/// **最近那一筆**顯示，而 Dart 的 Map 更新既有 key 不會把它移到最後，
/// 光靠插入順序判不出來。
class LastDataOp extends Notifier<Map<String, Map<String, dynamic>>> {
  @override
  Map<String, Map<String, dynamic>> build() => const {};

  int _seq = 0;

  void set(Map<String, dynamic> result) {
    final kind = '${result['kind']}';
    state = {
      ...state,
      kind: {...result, '_seq': ++_seq},
    };
  }
}

final lastDataOpProvider =
    NotifierProvider<LastDataOp, Map<String, Map<String, dynamic>>>(
        LastDataOp.new);

/// 哪些 `kind` 屬於「啟動與自啟」那一區、哪些屬於「對外協作」。
///
/// 🔴 **結果要出現在按鈕旁邊。** 在這之前所有操作的結果都只畫在
/// 「資料與安全」區塊裡（整頁的最後第二塊），於是按「停止 Hub」的人得往下
/// 捲過兩個區塊、在一個標題寫著「資料與安全」的框裡找他剛才那個動作的
/// 回應——多數人不會找到，而畫面看起來就是「按了沒反應」。
///
/// 記錄結果與**讓人看得到結果**是兩件事，前者 09/12 就做了，後者沒有。
const _controlKinds = {'hub_start', 'hub_stop', 'service'};
const _tunnelKinds = {'tunnel_start', 'tunnel_stop'};

/// 取出屬於這一區的那筆結果；不是這一區的就當作沒有。
Map<String, dynamic>? _opOf(WidgetRef ref, Set<String> kinds) =>
    _latest(ref.watch(lastDataOpProvider), (k) => kinds.contains(k));

/// 直接讀**某一種操作**那一格。
///
/// 🔴 **按鈕的「進行中」只能看自己那一格。** 用「這一區最新一筆」判的話：
/// Hub 啟動輪詢中去按停止，`hub_stop` 比較新 ⇒ 啟動鈕看到的不是自己的
/// pending ⇒ 從「啟動中…」變回「啟動 Hub」⇒ 再按一次就啟第二個進程。
/// 分格存對了，但讀的時候又合回去，等於沒分（審核用Codex 09/14）。
///
/// 顯示結果仍然用 `_opOf`（最近那一筆）——那是「這一區剛剛發生什麼」，
/// 與「這顆按鈕現在能不能按」是兩個問題。
bool _isPending(WidgetRef ref, String kind) =>
    ref.watch(lastDataOpProvider)[kind]?['pending'] == true;

/// 挑出符合條件的那些 kind 裡**最近寫入**的一筆。
Map<String, dynamic>? _latest(
  Map<String, Map<String, dynamic>> all,
  bool Function(String kind) keep,
) {
  Map<String, dynamic>? best;
  for (final entry in all.entries) {
    if (!keep(entry.key)) continue;
    final seq = entry.value['_seq'] as int? ?? 0;
    if (best == null || seq > (best['_seq'] as int? ?? 0)) best = entry.value;
  }
  return best;
}

/// 送出一個 detached 啟動，然後**去問狀態**直到它起來或逾時。
///
/// ⚠️ 這是啟動類操作唯一能給的「結果」：`Process.start(detached)` 不等結束、
/// 沒有 exit code 也沒有輸出。所以成功的證據不是腳本說什麼，是**狀態變了**。
///
/// 逾時不等於失敗，訊息要講成「還沒起來」並指向 log——講「失敗」會讓人去
/// 重按，而那時第一個進程可能正要起來。
/// 「送出一個 detached 動作，然後盯著狀態」的**決策部分**，不碰 UI。
///
/// 🔴 **抽出來是為了能被測。** 這裡面有四個行為，每一個都是為了修一個
/// 實際發生過的缺陷，而它們原本全部只活在 widget 樹裡、只能靠註解宣稱：
///
/// 1. `ready()` 拋不能中止輪詢——否則永遠停在 pending（按鈕卡住）
/// 2. `alreadyDone()` 為真時**不送出** launch——「現在是 ok」不等於
///    「這次動作成功」，而重複送出會多一個進程
/// 3. `launch()` 拋要回錯誤，不是繼續輪詢一個不存在的東西
/// 4. 逾時回的是 `ok: true` 加一句「還沒好」——**逾時不是失敗**，
///    進程可能正要起來，講成失敗會讓人重按
///
/// 回傳最終要寫進 `lastDataOp` 的那一筆（不含 `pending`）。
/// `gap` 可注入，測試用它把等待縮成零。
/// `baseline` 是**按下去之前的樣子**，`ready` 會收到它。
///
/// 🔴 **它在這裡面取，不是由呼叫端先取好再傳進來。** 原本隧道那邊是呼叫端
/// 自己 `await` 一次現讀再呼叫這裡，而那次現讀要打外網 health、可能好幾秒
/// ——那段期間 pending 還沒掛上，按鈕還能按，於是使用者再按一次就開出第二
/// 條隧道（審核用Codex 09/14）。
///
/// 移進來之後，`_launchAndWatch` 先掛 pending 再進這個函式，**時序由結構
/// 保證**，不靠呼叫端記得把兩行寫成正確的順序。
Future<Map<String, dynamic>> runOp({
  required String kind,
  required Future<void> Function() launch,
  required Future<bool> Function(String baseline) ready,
  required String okText,
  required String timeoutText,
  Future<bool> Function()? alreadyDone,
  String? alreadyText,
  Future<String> Function()? baseline,
  String? baselineFailText,
  int tries = 12,
  Future<void> Function() gap = _oneSecond,
}) async {
  if (alreadyDone != null) {
    bool before;
    try {
      before = await alreadyDone();
    } on Object catch (e) {
      // 🔴 **查不到就什麼都不做。**
      //
      // 這裡原本當作「沒在跑」照常送出，而那把原本的缺陷原樣放回來：
      // Hub 其實在跑、只是 health 這一瞬間讀不到 ⇒ 送出 ⇒ **第二個進程**；
      // 下一輪 health 恢復，輪詢看到那個「本來就在的」Hub ⇒ 回報本次成功。
      // 兩個錯合起來看起來完全正常（審核用Codex 09/14）。
      //
      // 前置檢查存在的理由就是「別在已經好了的時候再送一次」。它答不出來
      // 的時候，唯一誠實的動作是不動手並且說出來——不是猜一個方向。
      return {
        'kind': kind,
        'ok': false,
        'error': L10n.current
            .hostOpReasonWithError(L10n.current.hostOpNoStatus, '$e'),
      };
    }
    if (before) {
      return {'kind': kind, 'ok': true, 'detail': alreadyText ?? okText};
    }
  }
  String base = '';
  if (baseline != null) {
    try {
      base = await baseline();
    } on Object catch (e) {
      // 與 `alreadyDone` 同一條規則：**快照答不出來就不動手。** 當成空字串
      // 照送的話，一條殘留的舊網址會在下一輪被當成「新的」而假報成功。
      return {
        'kind': kind,
        'ok': false,
        'error': L10n.current.hostOpReasonWithError(
            baselineFailText ?? L10n.current.hostOpNoStatus, '$e'),
      };
    }
  }
  try {
    await launch();
  } on Object catch (e) {
    return {'kind': kind, 'ok': false, 'error': '$e'};
  }
  for (var i = 0; i < tries; i++) {
    await gap();
    bool ok;
    try {
      ok = await ready(base);
    } on Object {
      // 單次失敗不終止輪詢：Hub 正在起來的那幾秒 health 本來就可能拋
      ok = false;
    }
    if (ok) return {'kind': kind, 'ok': true, 'detail': okText};
  }
  return {'kind': kind, 'ok': true, 'detail': timeoutText};
}

Future<void> _oneSecond() => Future<void>.delayed(const Duration(seconds: 1));

/// [runOp] 的 UI 外殼：掛 pending、跑、寫結果。**這裡不做任何判斷**。
Future<void> _launchAndWatch(
  WidgetRef ref, {
  required String kind,
  required Future<void> Function() launch,
  required Future<bool> Function(String baseline) ready,
  required String okText,
  required String timeoutText,
  Future<bool> Function()? alreadyDone,
  String? alreadyText,
  Future<String> Function()? baseline,
  String? baselineFailText,
  int tries = 12,
}) async {
  final op = ref.read(lastDataOpProvider.notifier);
  op.set({'kind': kind, 'pending': true, 'ok': true, 'detail': ''});
  op.set(await runOp(
    kind: kind,
    launch: launch,
    ready: ready,
    okText: okText,
    timeoutText: timeoutText,
    alreadyDone: alreadyDone,
    alreadyText: alreadyText,
    baseline: baseline,
    baselineFailText: baselineFailText,
    tries: tries,
  ));
}

/// 資料與安全——備份、換 token。
///
/// 這兩件事擺在一起不是因為相似，而是因為**它們是這一頁唯二會改變
/// 磁碟上那份資料的動作**，其餘區塊都只是起停與觀察。
class _DataSection extends ConsumerStatefulWidget {
  const _DataSection();

  @override
  ConsumerState<_DataSection> createState() => _DataSectionState();
}

class _DataSectionState extends ConsumerState<_DataSection> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final actions = ref.watch(hostActionsProvider);
    if (actions == null) return const SizedBox.shrink();
    // 只顯示**這一區自己的**結果。起停與隧道的結果現在畫在它們的按鈕旁邊，
    // 再重複一份只會讓人以為剛剛按的動作發生了兩次
    final last = ref.watch(lastDataOpProvider);
    final dataLast = _latest(
        last,
        (k) => !_controlKinds.contains(k) && !_tunnelKinds.contains(k));

    final l10n = AppLocalizations.of(context);

    return _Panel(
      title: l10n.hostPanelBackup,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(spacing: 10, runSpacing: 10, children: [
            UepButton(
              small: true,
              variant: UepButtonVariant.outline,
              label: _busy ? l10n.hostBackupRunning : l10n.hostBackupNow,
              onPressed: _busy ? null : _backup,
            ),
            // 備份與還原要並排。**只有備份沒有還原，等於備份沒有出口**——
            // 而那件事要到真的需要還原的那一天才會被發現
            UepButton(
              small: true,
              variant: UepButtonVariant.outline,
              label: l10n.hostRestoreBackupButton,
              onPressed: _busy ? null : () => _pickAndRestore(context),
            ),
            UepButton(
              small: true,
              variant: UepButtonVariant.outline,
              label: l10n.hostRotateTokenButton,
              onPressed: _busy ? null : () => _confirmRotate(context),
            ),
          ]),
          if (dataLast != null) ...[
            const SizedBox(height: 14),
            _OpResult(result: dataLast),
          ],
        ],
      ),
    );
  }

  Future<void> _backup() async {
    final actions = ref.read(hostActionsProvider);
    if (actions == null) return;
    setState(() => _busy = true);
    try {
      final raw = await actions.backup();
      ref.read(lastDataOpProvider.notifier).set({
        'kind': 'backup',
        ...parseScriptResult(raw),
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 挑一份備份還原。
  ///
  /// 🔴 **清單是腳本給的，不是 UI 自己掃資料夾。** 掃資料夾的話「哪些算是
  /// 一份備份」就有兩份判準（腳本一份、UI 一份），而它們分岔的那一刻
  /// 沒有任何地方報錯——畫面上會出現一個腳本根本不肯還原的選項。
  Future<void> _pickAndRestore(BuildContext context) async {
    final actions = ref.read(hostActionsProvider);
    if (actions == null) return;

    setState(() => _busy = true);
    List<dynamic> backups;
    try {
      final listed = parseScriptResult(await actions.listBackups());
      if (listed['ok'] != true) {
        ref.read(lastDataOpProvider.notifier).set({
          'kind': 'restore', ...listed,
        });
        return;
      }
      backups = (listed['backups'] as List<dynamic>?) ?? const [];
    } finally {
      if (mounted) setState(() => _busy = false);
    }

    if (!context.mounted) return;
    if (backups.isEmpty) {
      ref.read(lastDataOpProvider.notifier).set({
        'kind': 'restore',
        'ok': false,
        'error': AppLocalizations.of(context).hostNoBackups,
      });
      return;
    }

    final chosen = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => _RestorePicker(backups: backups),
    );
    if (chosen == null || !context.mounted) return;

    final go = await _confirmRestore(context, chosen);
    if (go != true) return;

    setState(() => _busy = true);
    try {
      final raw = await actions.restoreBackup('${chosen['path']}');
      ref.read(lastDataOpProvider.notifier).set({
        'kind': 'restore',
        ...parseScriptResult(raw),
      });
      // 資料換了，整頁的觀察結果全部過期
      ref.invalidate(hostHealthProvider);
      ref.invalidate(hostEnvProvider);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 還原的確認框。
  ///
  /// 講的後果與其他幾個都不同：**這是唯一會讓現有資料消失的操作**。
  /// 所以除了後果，還要講那條退路在哪（腳本會先備份現況），
  /// 否則「確定嗎」只會換來反射性的點下去。
  Future<bool?> _confirmRestore(
      BuildContext context, Map<String, dynamic> backup) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final complete = backup['complete'] == true;
    final hasAttachments = backup['attachments_existed'] == true;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: s.bgCard,
        title: Text(l10n.hostRestoreTitle('${backup['name']}'),
            style: UepText.serif(
                size: 15, weight: FontWeight.w600, color: s.inkTitle)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.hostRestoreBody,
              style: UepText.serif(size: 14, color: s.ink, height: 1.7),
            ),
            if (!complete || !hasAttachments) ...[
              const SizedBox(height: 12),
              Text(
                !complete
                    ? l10n.hostBackupNoManifestNote
                    : l10n.hostBackupNoAttachmentsNote,
                style: UepText.serif(
                    size: 13.5, color: UepColors.errorText, height: 1.6),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel,
                style: UepText.serif(size: 14, color: s.inkMute)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.commonRestore,
                style: UepText.serif(size: 14, color: UepColors.gold)),
          ),
        ],
      ),
    );
  }

  /// 換 token 要確認——**它比停止 Hub 更難復原**。
  ///
  /// 停止之後按「啟動」就回來了；token 換掉之後，每一個成員都要重新拿到
  /// 新的那把，而那是一件人工的、會拖很久的事。
  Future<void> _confirmRotate(BuildContext context) async {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: s.bgCard,
        title: Text(l10n.hostRotateTitle,
            style: UepText.serif(
                size: 15, weight: FontWeight.w600, color: s.inkTitle)),
        content: Text(
          l10n.hostRotateBody,
          style: UepText.serif(size: 14, color: s.ink, height: 1.7),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel,
                style: UepText.serif(size: 14, color: s.inkMute)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.hostRotateTokenButton,
                style: UepText.serif(size: 14, color: UepColors.gold)),
          ),
        ],
      ),
    );
    if (go != true) return;

    final actions = ref.read(hostActionsProvider);
    if (actions == null) return;
    setState(() => _busy = true);
    try {
      final raw = await actions.rotateToken();
      ref.read(lastDataOpProvider.notifier).set({
        'kind': 'rotate',
        ...parseScriptResult(raw),
      });
      // .env 變了，「發給成員的連線資訊」那一區要跟著換——不 invalidate
      // 的話它會繼續顯示舊 token，而主持人正要把它複製給別人
      ref.invalidate(hostEnvProvider);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// 一次操作的結果。
///
/// 🔴 **成功要說出範圍**：備份了幾個附件、多大。「備份完成」四個字
/// 與「備份完成但附件一個都沒進去」在畫面上長得一樣，而它們的差別
/// 要到還原那天才看得出來。
/// 挑一份備份。
///
/// 清單直接來自 `restore.py --list`，**連「來歷不明」那種也照列**——
/// 藏起來的話，使用者會在畫面上找不到一個他明明看得到資料夾的東西，
/// 然後去猜是不是自己弄丟了。標記出來比消失好。
class _RestorePicker extends StatelessWidget {
  const _RestorePicker({required this.backups});

  final List<dynamic> backups;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      backgroundColor: s.bgCard,
      title: Text(l10n.hostPickBackupTitle,
          style: UepText.serif(
              size: 15, weight: FontWeight.w600, color: s.inkTitle)),
      content: SizedBox(
        width: 420,
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: backups.length,
          separatorBuilder: (_, _) => Divider(height: 1, color: s.line),
          itemBuilder: (ctx, i) {
            final item = (backups[i] as Map).cast<String, dynamic>();
            final complete = item['complete'] == true;
            final files = item['attachment_files'] ?? 0;
            final bytes = item['db_bytes'] ?? 0;
            return ListTile(
              dense: true,
              title: Text('${item['name']}',
                  style: UepText.code(size: 12.5, color: s.ink)),
              subtitle: Text(
                complete
                    ? l10n.hostBackupMeta('$bytes', '$files')
                    : l10n.hostBackupNoManifest,
                style: UepText.serif(
                    size: 12,
                    color: complete ? s.inkMute : UepColors.errorText),
              ),
              onTap: () => Navigator.pop(ctx, item),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel,
              style: UepText.serif(size: 14, color: s.inkMute)),
        ),
      ],
    );
  }
}

class _OpResult extends StatelessWidget {
  const _OpResult({required this.result});

  final Map<String, dynamic> result;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    // 還在跑。**這一格要存在**——按下去到結果出來之間有十幾秒，
    // 那段空白正是艾斯維爾說的「不知道按了有沒有用」。
    //
    // ⚠️ **擺在成敗判斷之前**：進行中還沒有成敗可言，而 `ok` 缺席時
    // `result['ok'] == true` 是 false ⇒ 會把一個正在跑的操作畫成
    // 「失敗：不知道為什麼」。測試就是這樣抓到的。
    if (result['pending'] == true) {
      return Text(
        result['kind'] == 'tunnel_start'
            ? l10n.hostOpTunnelPending
            : l10n.hostOpPending,
        style: UepText.serif(size: 12.5, color: s.inkMute, height: 1.5),
      );
    }
    final ok = result['ok'] == true;
    if (!ok) {
      return Text(
          l10n.hostOpFailed('${result['error'] ?? l10n.hostOpUnknownReason}'),
          style: UepText.code(size: 12, color: UepColors.errorText));
    }
    if (result['kind'] == 'hub_start' || result['kind'] == 'tunnel_start') {
      // 逾時也走這裡：那不是失敗（進程可能正要起來），措辭在送出端寫好了
      return Text('${result['detail'] ?? ''}',
          style: UepText.serif(size: 12.5, color: s.inkMute, height: 1.5));
    }
    if (result['kind'] == 'rotate') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 這是使用者唯一看得到明碼的時刻，所以不遮——遮了他就得去翻 .env
          _CopyRow(
              label: l10n.hostFieldNewToken,
              value: '${result['token'] ?? ''}'),
          const SizedBox(height: 6),
          Text(l10n.hostRotateResult('${result['backup'] ?? ''}'),
              style: UepText.serif(size: 12.5, color: s.inkMute, height: 1.5)),
        ],
      );
    }
    if (result['kind'] == 'hub_stop') {
      // 成功與否都走這裡：停止是那種「你以為做完了」的操作，沉默等於成功
      return Text('${result['detail'] ?? ''}',
          style: UepText.serif(size: 12.5, color: s.inkMute, height: 1.5));
    }
    if (result['kind'] == 'tunnel_stop') {
      // ⚠️ 這裡的 ok:true 有兩種：真的關掉了，與「本來就沒有隧道」。
      // 兩者都不是失敗，但講成同一句會讓人以為自己關掉了一條不存在的東西
      return Text('${result['detail'] ?? ''}',
          style: UepText.serif(size: 12.5, color: s.inkMute, height: 1.5));
    }
    if (result['kind'] == 'restore') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.hostRestoredFrom('${result['restored_from'] ?? ''}'),
              style: UepText.code(size: 12, color: s.inkSoft)),
          const SizedBox(height: 4),
          // 退路要跟結果一起講。還原完才發現拿錯備份的人，需要的就是這一行
          Text(l10n.hostSafetyBackup('${result['safety_backup'] ?? ''}'),
              style: UepText.serif(size: 12.5, color: s.inkMute, height: 1.5)),
          if (result['attachments_restored'] != true) ...[
            const SizedBox(height: 4),
            Text(l10n.hostBackupNoAttachmentsNote,
                style: UepText.serif(
                    size: 12.5, color: UepColors.errorText, height: 1.5)),
          ],
        ],
      );
    }
    final hadAttachments = result['attachments_existed'] == true;
    final files = result['attachment_files'] ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.hostBackupDest('${result['dest'] ?? ''}'),
            style: UepText.code(size: 12, color: s.inkSoft)),
        const SizedBox(height: 4),
        Text(
          hadAttachments
              ? l10n.hostBackupWithAttachments(
                  '${result['db_bytes'] ?? 0}', '$files')
              // 講明是「來源就沒有」而不是「沒備份到」——這兩者在磁碟上
              // 一模一樣，意義相反
              : l10n.hostBackupWithoutAttachments(
                  '${result['db_bytes'] ?? 0}'),
          style: UepText.serif(
              size: 12.5,
              color: hadAttachments ? s.inkMute : s.inkSoft,
              height: 1.5),
        ),
      ],
    );
  }
}

class _CopyRow extends StatefulWidget {
  const _CopyRow({required this.label, required this.value, this.secret = false});

  final String label;
  final String value;

  /// token 這種東西預設遮起來——這個畫面很可能在螢幕分享或截圖裡。
  /// 遮的是顯示，不是複製：按鈕照樣把真值放進剪貼簿。
  final bool secret;

  @override
  State<_CopyRow> createState() => _CopyRowState();
}

class _CopyRowState extends State<_CopyRow> {
  bool _revealed = false;
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final hidden = widget.secret && !_revealed;
    return Row(children: [
      SizedBox(
        width: 92,
        child: Text(widget.label, style: UepText.fieldLabel(color: s.inkMute)),
      ),
      Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          decoration: BoxDecoration(
            color: s.bgSunken,
            border: Border.all(color: s.line),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            hidden ? '•' * 24 : widget.value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: UepText.code(size: 12.5, color: s.ink),
          ),
        ),
      ),
      if (widget.secret)
        IconButton(
          tooltip: _revealed
              ? AppLocalizations.of(context).commonHide
              : AppLocalizations.of(context).commonShow,
          icon: Icon(_revealed ? Icons.visibility_off : Icons.visibility,
              size: 16, color: s.inkMute),
          onPressed: () => setState(() => _revealed = !_revealed),
        ),
      IconButton(
        tooltip: _copied
            ? AppLocalizations.of(context).commonCopied
            : AppLocalizations.of(context).commonCopy,
        icon: Icon(_copied ? Icons.check : Icons.copy,
            size: 16, color: _copied ? UepColors.success : s.inkMute),
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: widget.value));
          if (!mounted) return;
          setState(() => _copied = true);
          // 回到原狀，否則下一次複製看不出來有沒有成功
          await Future<void>.delayed(const Duration(seconds: 2));
          if (mounted) setState(() => _copied = false);
        },
      ),
    ]);
  }
}

class _KitSection extends StatelessWidget {
  const _KitSection({required this.kit});

  final HostKit kit;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return _Panel(
      title: AppLocalizations.of(context).hostInstallPath,
      child: SelectableText(kit.kitRoot,
          style: UepText.code(size: 12, color: s.inkSoft)),
    );
  }
}

/// 這一頁的東西是**怎麼找到的**：安裝包，還是直接偵測到的本機檔案。
///
/// 不是裝飾：兩種來源能做的事一樣，但「裝了一包」與「找到你 repo 裡那份」
/// 出問題時要找的地方完全不同——升級安裝包救不了本機來源的那一份。
class _SourceLine extends StatelessWidget {
  const _SourceLine({required this.source});

  final KitSource source;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final name = source == KitSource.installed
        ? l10n.hostKitSourceInstalled
        : l10n.hostKitSourceLocal;
    return Text(l10n.hostKitSource(name),
        style: UepText.code(size: 11.5, color: context.uep.inkMute));
  }
}

/// 執行器版本。讀不到就不畫——空的一行比沒有那一行更容易被當成「沒版本」。
class _RunnerVersionLine extends ConsumerWidget {
  const _RunnerVersionLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(runnerVersionProvider).value ?? '';
    if (version.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        AppLocalizations.of(context).hostRunnerVersion(version),
        style: UepText.code(size: 11.5, color: context.uep.inkMute),
      ),
    );
  }
}

/// 「標籤：值」的一行。
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Row(children: [
      SizedBox(
        width: 92,
        child: Text(label, style: UepText.fieldLabel(color: s.inkMute)),
      ),
      Text(value, style: UepText.serif(size: 14.5, color: s.ink)),
    ]);
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 與設定頁的欄位標籤同一組字級（fieldLabel：mono 12／w500）
        Text(title, style: UepText.fieldLabel(color: context.uep.inkMute)),
        const SizedBox(height: 12),
        // 不再包邊框卡片——分段交給 `_sep()` 的分隔線。留 width 撐滿，
        // 否則 Column 會依內容縮寬，右側的說明文字排版跟著跳
        SizedBox(width: double.infinity, child: child),
      ],
    );
  }
}

/// 執行器的工作區設定：工作區裡有哪些專案、公開給誰派工、優先載入哪個 skill。
///
/// ## 兩層：工作區 → 專案
///
/// 工作區是外層資料夾（派工時 Hub 認得的那個 key），專案是它底下的 git repo。
///
/// ## 權威在本機的 `config.json`，不在 Hub
///
/// 專案路徑與 skill 目錄本來就是「這台機器的事」——Hub 驗不了它們在這台
/// 機器上存不存在。所以這一頁與 Hub 分頁讀寫 `.env` 是同一個模式：直接讀寫
/// 本機檔案，改完再經 Hub 對**這台**執行器發一個 `reload`，讓它自己重讀。
///
/// `reload` 走既有的 `runner_command`（issued→acked→applied）——改設定不另開
/// 一條 Hub 不認得的平行通路。
class _RunnerWorkspacesSection extends ConsumerWidget {
  const _RunnerWorkspacesSection({required this.kit});

  final RunnerKit kit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final cfg = ref.watch(runnerConfigProvider);

    return cfg.when(
      loading: () => _Panel(
        title: l10n.hostRunnerPanelWorkspaces,
        child: _LightRow(
            label: l10n.settingsTitle, probe: Probe.checking()),
      ),
      error: (e, _) => _Panel(
        title: l10n.hostRunnerPanelWorkspaces,
        child: _LightRow(
            label: l10n.settingsTitle,
            probe: Probe(ProbeState.unknown, '$e')),
      ),
      data: (config) {
        if (config == null) {
          return _Panel(
            title: l10n.hostRunnerPanelWorkspaces,
            child: _LightRow(
              label: l10n.settingsTitle,
              probe: Probe(ProbeState.unknown,
                  l10n.hostRunnerConfigUnreadable(kit.configPath)),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(l10n.hostRunnerPanelWorkspaces,
                      style: UepText.fieldLabel(color: s.inkMute)),
                ),
                UepButton(
                  label: l10n.hostRunnerAddWorkspace,
                  small: true,
                  variant: UepButtonVariant.outline,
                  onPressed: () => _addWorkspace(context, ref, config),
                ),
              ],
            ),
            const SizedBox(height: 18),
            if (config.workspaces.isEmpty)
              Text(l10n.hostRunnerNoWorkspaces,
                  style: UepText.serif(size: 14, color: s.inkMute)),
            for (final w in config.workspaces) ...[
              _RunnerWorkspaceCard(
                  key: ValueKey('ws:${config.path}:${w.key}'),
                  config: config,
                  workspace: w),
              SizedBox(height: w == config.workspaces.last ? 0 : 26),
            ],
            const SizedBox(height: 18),
            Text(
              l10n.hostRunnerWorkspacePrivateNote,
              style: UepText.serif(size: 13, color: s.inkMute),
            ),
          ],
        );
      },
    );
  }

  Future<void> _addWorkspace(
      BuildContext context, WidgetRef ref, RunnerConfigFile config) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final added = await showDialog<bool>(
      context: context,
      builder: (_) => _AddWorkspaceDialog(config: config),
    );
    if (added != true) return;
    final said = await _runnerApplyReload(ref, l10n);
    messenger.showSnackBar(SnackBar(content: Text(said)));
  }
}

/// 存檔之後：重讀設定，並對這台執行器發 `reload`。
///
/// 回傳的是要給使用者看的那一句——**存檔與命令是兩件事**：寫進去了但命令
/// 沒送出（拿不到 runner_id、Hub 連不上）時要講「已存檔，執行器還沒收到」，
/// 而不是一句籠統的成功，那會讓人以為設定已經在跑著的執行器上生效了。
Future<String> _runnerApplyReload(WidgetRef ref, AppLocalizations l10n) async {
  ref.invalidate(runnerConfigProvider);
  final runnerId = await ref.read(runnerIdProvider.future);
  if (runnerId == null) return l10n.hostRunnerSavedNoRunnerId;
  try {
    await ref.read(runsApiProvider).command(
          runnerId,
          command: 'reload',
          sessionKey: ref.read(appConfigProvider).deviceKey,
        );
    return l10n.hostRunnerSavedReloadSent;
  } on ApiException catch (e) {
    return l10n.hostRunnerReloadFailed(e.message);
  }
}

/// 把資料層的例外翻成一句話。衝突（重讀再試）與值不對（改了再存也一樣）
/// 是兩種不同的處置，訊息要分得開。
String _runnerErrorText(Object error, AppLocalizations l10n) {
  if (error is RunnerConfigConflict) return l10n.hostRunnerConflict;
  if (error is RunnerConfigInvalid) return error.message;
  return l10n.hostRunnerWriteFailed('$error');
}

/// 路徑的最後一段，拿來當專案的預設名稱。
String _lastSegment(String path) {
  final parts = path
      .replaceAll('\\', '/')
      .split('/')
      .where((p) => p.isNotEmpty)
      .toList();
  return parts.isEmpty ? '' : parts.last;
}

/// 開系統的資料夾選擇器。取消回 `null`。
Future<String?> _pickDirectory(String title) async {
  try {
    final path = await FilePicker.getDirectoryPath(dialogTitle: title);
    if (path == null || path.trim().isEmpty) return null;
    return path;
  } on Object {
    // 沒有選擇器可用的平台：旁邊的輸入框照樣打得了字
    return null;
  }
}

/// 一個工作區一張卡。
class _RunnerWorkspaceCard extends ConsumerStatefulWidget {
  const _RunnerWorkspaceCard({
    super.key,
    required this.config,
    required this.workspace,
  });

  final RunnerConfigFile config;
  final RunnerWorkspace workspace;

  @override
  ConsumerState<_RunnerWorkspaceCard> createState() =>
      _RunnerWorkspaceCardState();
}

class _RunnerWorkspaceCardState extends ConsumerState<_RunnerWorkspaceCard> {
  late bool _public = widget.workspace.public;
  late bool _livetest = widget.workspace.allowBrowserLivetest;
  late String _folder = widget.workspace.folder;
  late List<String> _skillDirs = List.of(widget.workspace.skillDirs);
  late String _primarySkill = widget.workspace.primarySkill;
  bool _saving = false;

  late final _model = TextEditingController(text: widget.workspace.model);
  late final _maxTurns = TextEditingController(text: _num(widget.workspace.maxTurns));
  late final _budget = TextEditingController(text: _num(widget.workspace.maxBudgetUsd));
  late final _wallClock =
      TextEditingController(text: _num(widget.workspace.wallClockSeconds));
  late final _contextWindow =
      TextEditingController(text: _num(widget.workspace.contextWindowTokens));

  /// 0 ＝ 沒設，欄位就留空（空的意思是「沿用執行器的預設」，不是 0）。
  static String _num(num value) {
    if (value <= 0) return '';
    if (value is int || value == value.roundToDouble()) {
      return value.toInt().toString();
    }
    return value.toString();
  }

  @override
  void dispose() {
    _model.dispose();
    _maxTurns.dispose();
    _budget.dispose();
    _wallClock.dispose();
    _contextWindow.dispose();
    super.dispose();
  }

  int get _maxTurnsValue => int.tryParse(_maxTurns.text.trim()) ?? 0;
  double get _budgetValue => double.tryParse(_budget.text.trim()) ?? 0;
  int get _wallClockValue => int.tryParse(_wallClock.text.trim()) ?? 0;
  int get _contextWindowValue => int.tryParse(_contextWindow.text.trim()) ?? 0;

  bool get _dirty =>
      _public != widget.workspace.public ||
      _livetest != widget.workspace.allowBrowserLivetest ||
      _folder != widget.workspace.folder ||
      _primarySkill != widget.workspace.primarySkill ||
      _model.text.trim() != widget.workspace.model ||
      _maxTurnsValue != widget.workspace.maxTurns ||
      _budgetValue != widget.workspace.maxBudgetUsd ||
      _wallClockValue != widget.workspace.wallClockSeconds ||
      _contextWindowValue != widget.workspace.contextWindowTokens ||
      !_sameList(_skillDirs, widget.workspace.skillDirs);

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 表單存檔 → 發 `reload`。
  ///
  /// 優先載入 skill 是**另一次寫入**（它要對著 skill_dirs 驗證），所以這裡
  /// 存完要重讀一份設定再寫第二次——拿舊的那份寫會撞上 mtime 檢查。
  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      await saveRunnerWorkspace(
        widget.config,
        workspaceKey: widget.workspace.key,
        folder: _folder,
        public: _public,
        allowBrowserLivetest: _livetest,
        model: _model.text.trim(),
        maxTurns: _maxTurnsValue,
        maxBudgetUsd: _budgetValue,
        wallClockSeconds: _wallClockValue,
        contextWindowTokens: _contextWindowValue,
        skillDirs: _skillDirs,
      );
      if (_primarySkill != widget.workspace.primarySkill) {
        ref.invalidate(runnerConfigProvider);
        final fresh = await readRunnerConfig(widget.config.path);
        if (fresh == null) throw const RunnerConfigConflict();
        await setRunnerPrimarySkill(
          fresh,
          workspaceKey: widget.workspace.key,
          skill: _primarySkill,
        );
      }
    } on Object catch (e) {
      if (mounted) setState(() => _saving = false);
      ref.invalidate(runnerConfigProvider);
      messenger.showSnackBar(
          SnackBar(content: Text(_runnerErrorText(e, l10n))));
      return;
    }

    final said = await _runnerApplyReload(ref, l10n);
    if (mounted) setState(() => _saving = false);
    messenger.showSnackBar(SnackBar(content: Text(said)));
  }

  /// 立刻寫檔的動作（加／移除專案、設預設、移除工作區）。
  ///
  /// 與表單的「儲存並套用」同一條路：寫完重讀設定、發 `reload`、把結果講出來。
  Future<void> _write(Future<void> Function() action) async {
    final l10n = AppLocalizations.of(context);
    // 移除工作區之後這張卡就不在了；訊息要交給不會跟著消失的 messenger
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      await action();
    } on Object catch (e) {
      if (mounted) setState(() => _saving = false);
      ref.invalidate(runnerConfigProvider);
      messenger.showSnackBar(
          SnackBar(content: Text(_runnerErrorText(e, l10n))));
      return;
    }
    final said = await _runnerApplyReload(ref, l10n);
    if (mounted) setState(() => _saving = false);
    messenger.showSnackBar(SnackBar(content: Text(said)));
  }

  Future<void> _addSkillDir() async {
    final path = await showDialog<String>(
      context: context,
      builder: (context) => _PathDialog(
        title: AppLocalizations.of(context).hostRunnerAddSkillDirTitle,
        label: AppLocalizations.of(context).hostRunnerSkillDirHint,
      ),
    );
    if (path == null || path.isEmpty) return;
    if (_skillDirs.contains(path)) return;
    setState(() => _skillDirs = [..._skillDirs, path]);
  }

  Future<void> _pickFolder() async {
    final l10n = AppLocalizations.of(context);
    final path = await _pickDirectory(l10n.hostRunnerFolder);
    if (path == null) return;
    setState(() => _folder = path);
  }

  Future<void> _addProject() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final added = await showDialog<bool>(
      context: context,
      builder: (_) => _AddProjectDialog(
        config: widget.config,
        workspaceKey: widget.workspace.key,
      ),
    );
    if (added != true) return;
    final said = await _runnerApplyReload(ref, l10n);
    messenger.showSnackBar(SnackBar(content: Text(said)));
  }

  Future<void> _removeWorkspace() async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(
            l10n.hostRunnerRemoveWorkspaceConfirm(widget.workspace.key)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.commonRemove),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _write(() => removeRunnerWorkspace(widget.config,
        key: widget.workspace.key));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final w = widget.workspace;

    return _Panel(
      title: w.key,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  _folder.isEmpty ? l10n.hostRunnerNone : _folder,
                  style: UepText.code(size: 12, color: s.inkSoft),
                ),
              ),
              const SizedBox(width: 12),
              UepButton(
                label: l10n.hostRunnerBrowse,
                small: true,
                variant: UepButtonVariant.outline,
                onPressed: _saving ? null : _pickFolder,
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _public,
            title: Text(l10n.hostRunnerPublic,
                style: UepText.serif(size: 14.5, color: s.ink)),
            onChanged: _saving ? null : (v) => setState(() => _public = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _livetest,
            title: Text(l10n.hostRunnerLivetest,
                style: UepText.serif(size: 14.5, color: s.ink)),
            onChanged: _saving ? null : (v) => setState(() => _livetest = v),
          ),
          const SizedBox(height: 14),
          _projects(context, s, l10n, w),
          const SizedBox(height: 14),
          Text(l10n.hostRunnerSkillDirs,
              style: UepText.fieldLabel(color: s.inkMute)),
          const SizedBox(height: 6),
          if (_skillDirs.isEmpty)
            Text(l10n.hostRunnerNone,
                style: UepText.serif(size: 13, color: s.inkMute)),
          for (final dir in _skillDirs)
            Row(
              children: [
                Expanded(
                  child: SelectableText(dir,
                      style: UepText.code(size: 12, color: s.inkSoft)),
                ),
                IconButton(
                  tooltip: l10n.commonRemove,
                  icon: Icon(Icons.close, size: 16, color: s.inkMute),
                  onPressed: _saving
                      ? null
                      : () => setState(
                          () => _skillDirs = [..._skillDirs]..remove(dir)),
                ),
              ],
            ),
          const SizedBox(height: 10),
          _primarySkillField(s, l10n),
          const SizedBox(height: 10),
          _advanced(s, l10n),
          const SizedBox(height: 8),
          Row(
            children: [
              UepButton(
                label: l10n.hostRunnerAddDir,
                small: true,
                variant: UepButtonVariant.outline,
                onPressed: _saving ? null : _addSkillDir,
              ),
              const SizedBox(width: 12),
              UepButton(
                label: l10n.hostRunnerSaveApply,
                small: true,
                onPressed: (_saving || !_dirty) ? null : _save,
              ),
              const Spacer(),
              UepButton(
                label: l10n.hostRunnerRemoveWorkspace,
                small: true,
                variant: UepButtonVariant.outline,
                onPressed: _saving ? null : _removeWorkspace,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 工作區裡的專案：名稱、路徑、預設標記，加與減。
  Widget _projects(BuildContext context, UepSurface s, AppLocalizations l10n,
      RunnerWorkspace w) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(l10n.hostRunnerProjects,
                  style: UepText.fieldLabel(color: s.inkMute)),
            ),
            UepButton(
              label: l10n.hostRunnerAddProject,
              small: true,
              variant: UepButtonVariant.outline,
              onPressed: _saving ? null : _addProject,
            ),
          ],
        ),
        const SizedBox(height: 6),
        for (final e in w.projects.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Expanded(
                  child: SelectableText(
                    e.key == w.defaultProject
                        ? l10n.hostRunnerRepoDefault(e.key, e.value.path)
                        : l10n.hostRunnerRepoEntry(e.key, e.value.path),
                    style: UepText.code(size: 12, color: s.inkSoft),
                  ),
                ),
                if (e.key != w.defaultProject)
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () => _write(() => saveRunnerWorkspace(
                              widget.config,
                              workspaceKey: w.key,
                              defaultProject: e.key,
                            )),
                    child: Text(l10n.hostRunnerSetDefaultProject,
                        style: UepText.serif(size: 12.5, color: s.inkMute)),
                  ),
                IconButton(
                  tooltip: l10n.commonRemove,
                  icon: Icon(Icons.close, size: 16, color: s.inkMute),
                  onPressed: _saving
                      ? null
                      : () => _write(() => removeRunnerProject(
                            widget.config,
                            workspaceKey: w.key,
                            name: e.key,
                          )),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 優先載入 skill：選項來自這個工作區 `skill_dirs` 底下掃到的 skill。
  ///
  /// 目前選著的那個即使掃不到也要留在清單裡——不然它會在畫面上無聲消失，
  /// 而檔案裡還寫著它。
  Widget _primarySkillField(UepSurface s, AppLocalizations l10n) {
    return FutureBuilder<List<String>>(
      future: listRunnerSkills(_skillDirs),
      builder: (context, snap) {
        final names = <String>{...(snap.data ?? const <String>[])};
        if (_primarySkill.isNotEmpty) names.add(_primarySkill);
        final items = names.toList()..sort();
        return Row(
          children: [
            SizedBox(
              width: 140,
              child: Text(l10n.hostRunnerPrimarySkill,
                  style: UepText.fieldLabel(color: s.inkMute)),
            ),
            Expanded(
              child: DropdownButton<String>(
                value: _primarySkill,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                style: UepText.serif(size: 14, color: s.ink),
                dropdownColor: s.bgSoft,
                items: [
                  DropdownMenuItem(
                    value: '',
                    child: Text(l10n.hostRunnerPrimarySkillNone,
                        style: UepText.serif(size: 14, color: s.inkMute)),
                  ),
                  for (final name in items)
                    DropdownMenuItem(
                      value: name,
                      child: Text(name,
                          style: UepText.serif(size: 14, color: s.ink)),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (v) => setState(() => _primarySkill = v ?? ''),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 模型與各種上限。預設收起來——大部分工作區不會碰它們。
  Widget _advanced(UepSurface s, AppLocalizations l10n) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        title: Text(l10n.hostRunnerAdvanced,
            style: UepText.fieldLabel(color: s.inkMute)),
        children: [
          _field(s, l10n.hostRunnerModel, _model),
          _field(s, l10n.hostRunnerMaxTurns, _maxTurns, numeric: true),
          _field(s, l10n.hostRunnerMaxBudget, _budget, numeric: true),
          _field(s, l10n.hostRunnerWallClock, _wallClock, numeric: true),
          _field(s, l10n.hostRunnerContextWindow, _contextWindow,
              numeric: true),
        ],
      ),
    );
  }

  Widget _field(UepSurface s, String label, TextEditingController controller,
      {bool numeric = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child:
                Text(label, style: UepText.fieldLabel(color: s.inkMute)),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              enabled: !_saving,
              keyboardType: numeric ? TextInputType.number : null,
              style: UepText.code(size: 12.5, color: s.ink),
              decoration: InputDecoration(
                isDense: true,
                hintText: AppLocalizations.of(context)
                    .hostRunnerFieldDefaultHint,
                hintStyle: UepText.serif(size: 12.5, color: s.inkMute),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ],
      ),
    );
  }
}

/// 打一個路徑，或按「瀏覽」從系統選一個。
///
/// 兩種都留著：沒有選擇器的平台照樣打得了字，而貼路徑常常比一層層點快。
class _PathDialog extends StatefulWidget {
  const _PathDialog({required this.title, required this.label});

  final String title;
  final String label;

  @override
  State<_PathDialog> createState() => _PathDialogState();
}

class _PathDialogState extends State<_PathDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              autofocus: true,
              decoration: InputDecoration(hintText: widget.label),
              onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () async {
              final path = await _pickDirectory(widget.title);
              if (path == null || !mounted) return;
              setState(() => _controller.text = path);
            },
            child: Text(l10n.hostRunnerBrowse),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(l10n.commonAdd),
        ),
      ],
    );
  }
}

/// 新增工作區：名稱、資料夾，資料夾不是 git repo 時還要一個專案路徑。
///
/// 驗證交給資料層（同一條規則只留一份），錯誤**留在對話框裡**顯示——關掉
/// 再從頭填一次是這種表單最討人厭的一件事。
class _AddWorkspaceDialog extends StatefulWidget {
  const _AddWorkspaceDialog({required this.config});

  final RunnerConfigFile config;

  @override
  State<_AddWorkspaceDialog> createState() => _AddWorkspaceDialogState();
}

class _AddWorkspaceDialogState extends State<_AddWorkspaceDialog> {
  final _key = TextEditingController();
  final _folder = TextEditingController();
  final _project = TextEditingController();
  String _error = '';
  bool _busy = false;

  @override
  void dispose() {
    _key.dispose();
    _folder.dispose();
    _project.dispose();
    super.dispose();
  }

  bool get _ready =>
      !_busy && _key.text.trim().isNotEmpty && _folder.text.trim().isNotEmpty;

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await addRunnerWorkspace(
        widget.config,
        key: _key.text.trim(),
        folder: _folder.text.trim(),
        projectPath: _project.text.trim(),
      );
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _runnerErrorText(e, l10n);
      });
      return;
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.hostRunnerAddWorkspace),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _key,
              autofocus: true,
              enabled: !_busy,
              decoration:
                  InputDecoration(labelText: l10n.hostRunnerWorkspaceKey),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            _pathRow(l10n, _folder, l10n.hostRunnerFolder, ''),
            const SizedBox(height: 10),
            _pathRow(l10n, _project, l10n.hostRunnerFirstProjectPath,
                l10n.hostRunnerFirstProjectHint),
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(_error,
                  style: UepText.serif(size: 13, color: UepColors.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          onPressed: _ready ? _submit : null,
          child: Text(l10n.commonAdd),
        ),
      ],
    );
  }

  Widget _pathRow(AppLocalizations l10n, TextEditingController controller,
      String label, String hint) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            enabled: !_busy,
            decoration: InputDecoration(
              labelText: label,
              hintText: hint.isEmpty ? null : hint,
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: _busy
              ? null
              : () async {
                  final path = await _pickDirectory(label);
                  if (path == null || !mounted) return;
                  setState(() => controller.text = path);
                },
          child: Text(l10n.hostRunnerBrowse),
        ),
      ],
    );
  }
}

/// 在工作區裡加一個專案。名稱留空就用路徑的最後一段。
class _AddProjectDialog extends StatefulWidget {
  const _AddProjectDialog({required this.config, required this.workspaceKey});

  final RunnerConfigFile config;
  final String workspaceKey;

  @override
  State<_AddProjectDialog> createState() => _AddProjectDialogState();
}

class _AddProjectDialogState extends State<_AddProjectDialog> {
  final _name = TextEditingController();
  final _path = TextEditingController();
  String _error = '';
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _path.dispose();
    super.dispose();
  }

  bool get _ready => !_busy && _path.text.trim().isNotEmpty;

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    final path = _path.text.trim();
    final name =
        _name.text.trim().isEmpty ? _lastSegment(path) : _name.text.trim();
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await addRunnerProject(
        widget.config,
        workspaceKey: widget.workspaceKey,
        name: name,
        path: path,
      );
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _runnerErrorText(e, l10n);
      });
      return;
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.hostRunnerAddProject),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              enabled: !_busy,
              decoration:
                  InputDecoration(labelText: l10n.hostRunnerProjectName),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _path,
                    autofocus: true,
                    enabled: !_busy,
                    decoration: InputDecoration(
                        labelText: l10n.hostRunnerProjectPath),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          final path = await _pickDirectory(
                              l10n.hostRunnerProjectPath);
                          if (path == null || !mounted) return;
                          setState(() => _path.text = path);
                        },
                  child: Text(l10n.hostRunnerBrowse),
                ),
              ],
            ),
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(_error,
                  style: UepText.serif(size: 13, color: UepColors.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          onPressed: _ready ? _submit : null,
          child: Text(l10n.commonAdd),
        ),
      ],
    );
  }
}

/// `.env` 一個欄位的規格。**標籤就是 key 本身**——這頁改的是 `.env`，
/// 翻譯一個變數名只會讓人對不上自己檔案裡的那一行。
enum _EnvKind { text, port, nonNegInt, url, choice }

class _EnvFieldSpec {
  const _EnvFieldSpec(this.key,
      {this.kind = _EnvKind.text,
      this.secret = false,
      this.options = const []});

  final String key;
  final _EnvKind kind;

  /// 遮罩顯示，可按眼睛看。
  final bool secret;

  /// `choice` 用的選項，第一項是空字串（沒設，用預設值）。
  final List<String> options;
}

/// Hub 那份 `.env` 可改的欄位。
///
/// `CHATROOM_DB`／`CHATROOM_HUMAN_TOKEN`／`CHATROOM_TUNNEL_URL_FILE` **不在
/// 這裡**：那三個是安裝時決定的，改錯的代價（資料庫換成一個空的、主持人
/// 把自己鎖在外面）遠大於在這頁改它的方便。
const _hubEnvFields = <_EnvFieldSpec>[
  _EnvFieldSpec('CHATROOM_HOST'),
  _EnvFieldSpec('CHATROOM_PORT', kind: _EnvKind.port),
  _EnvFieldSpec('CHATROOM_TOKEN', secret: true),
  _EnvFieldSpec('CHATROOM_IDLE_TIMEOUT', kind: _EnvKind.nonNegInt),
  _EnvFieldSpec('CHATROOM_SUBAGENT_TIMEOUT', kind: _EnvKind.nonNegInt),
  _EnvFieldSpec('CHATROOM_HOLD_MAX', kind: _EnvKind.nonNegInt),
  _EnvFieldSpec('CHATROOM_PURGE_ARCHIVED_DAYS', kind: _EnvKind.nonNegInt),
  _EnvFieldSpec('CHATROOM_RUN_DAILY_QUOTA', kind: _EnvKind.nonNegInt),
  _EnvFieldSpec('CHATROOM_RUN_QUEUE_CAP', kind: _EnvKind.nonNegInt),
  _EnvFieldSpec('CHATROOM_ATTACHMENT_DIR'),
  _EnvFieldSpec('CHATROOM_LOG_LEVEL',
      kind: _EnvKind.choice,
      options: ['', 'DEBUG', 'INFO', 'WARNING', 'ERROR']),
];

/// bridge 那份 `.env` 可改的欄位。
const _mcpEnvFields = <_EnvFieldSpec>[
  _EnvFieldSpec('CHATROOM_URL', kind: _EnvKind.url),
  _EnvFieldSpec('CHATROOM_TOKEN', secret: true),
  _EnvFieldSpec('CHATROOM_DEFAULT_NAME'),
  _EnvFieldSpec('CHATROOM_AGENT_KIND'),
  _EnvFieldSpec('CHATROOM_HOST_NAME'),
  _EnvFieldSpec('CHATROOM_STATE_TTL_DAYS', kind: _EnvKind.nonNegInt),
];

/// Hub 分頁的 `.env` 表單。緊接在起停那一區後面——改完要重啟才生效，
/// 那兩顆按鈕就在上面。
class _HubEnvSection extends ConsumerWidget {
  const _HubEnvSection({required this.kit});

  final HostKit kit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final values = ref.watch(hostEnvRawProvider);

    return values.when(
      loading: () => _Panel(
        title: l10n.hostEnvPanelHubSettings,
        child: _LightRow(label: l10n.settingsTitle, probe: Probe.checking()),
      ),
      error: (e, _) => _Panel(
        title: l10n.hostEnvPanelHubSettings,
        child: _LightRow(
            label: l10n.settingsTitle, probe: Probe(ProbeState.unknown, '$e')),
      ),
      data: (map) {
        if (map == null) {
          return _Panel(
            title: l10n.hostEnvPanelHubSettings,
            child: Text(l10n.hostEnvUnreadable,
                style: UepText.serif(size: 14, color: s.inkMute)),
          );
        }
        return _EnvEditor(
          key: ValueKey('hub:${kit.envFile}'),
          title: l10n.hostEnvPanelHubSettings,
          path: kit.envFile,
          specs: _hubEnvFields,
          values: map,
          savedMessage: l10n.hostEnvSavedRestartHub,
          onSaved: (ref) {
            ref.invalidate(hostEnvProvider);
            ref.invalidate(hostEnvRawProvider);
          },
        );
      },
    );
  }
}

/// MCP kit 分頁的 `.env` 表單。
class _McpEnvSection extends ConsumerWidget {
  const _McpEnvSection({required this.kit});

  final McpKit kit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final values = ref.watch(mcpEnvRawProvider);

    return values.when(
      loading: () => _Panel(
        title: l10n.hostEnvPanelMcpSettings,
        child: _LightRow(label: l10n.settingsTitle, probe: Probe.checking()),
      ),
      error: (e, _) => _Panel(
        title: l10n.hostEnvPanelMcpSettings,
        child: _LightRow(
            label: l10n.settingsTitle, probe: Probe(ProbeState.unknown, '$e')),
      ),
      data: (map) {
        if (map == null) {
          return _Panel(
            title: l10n.hostEnvPanelMcpSettings,
            child: Text(l10n.hostMcpEnvMissing,
                style: UepText.serif(size: 14, color: s.inkMute)),
          );
        }
        return _EnvEditor(
          key: ValueKey('mcp:${kit.envFile}'),
          title: l10n.hostEnvPanelMcpSettings,
          path: kit.envFile,
          specs: _mcpEnvFields,
          values: map,
          savedMessage: l10n.hostEnvSavedNextConnect,
          onSaved: (ref) {
            ref.invalidate(mcpEnvProvider);
            ref.invalidate(mcpEnvRawProvider);
            ref.invalidate(mcpStatusProvider);
          },
        );
      },
    );
  }
}

/// 兩個分頁共用的 `.env` 表單。
///
/// 寫回走 `writeEnvUpdates()`：**只覆寫改過的那幾個 key**，其餘行、註解與
/// 順序原樣保留（規則與 `host-kit/install.py:update_env()` 同一套）。
///
/// 「改過」的判準是與讀進來那一刻的值不同——沒碰過的空欄位不進 updates，
/// 所以存一次檔不會在檔案裡多出一堆空的 `KEY=`。
class _EnvEditor extends ConsumerStatefulWidget {
  const _EnvEditor({
    super.key,
    required this.title,
    required this.path,
    required this.specs,
    required this.values,
    required this.savedMessage,
    required this.onSaved,
  });

  final String title;
  final String path;
  final List<_EnvFieldSpec> specs;
  final Map<String, String> values;
  final String savedMessage;
  final void Function(WidgetRef ref) onSaved;

  @override
  ConsumerState<_EnvEditor> createState() => _EnvEditorState();
}

class _EnvEditorState extends ConsumerState<_EnvEditor> {
  final _controllers = <String, TextEditingController>{};
  final _errors = <String, EnvFieldError?>{};
  final _revealed = <String>{};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    for (final spec in widget.specs) {
      _controllers[spec.key] =
          TextEditingController(text: widget.values[spec.key] ?? '');
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _original(String key) => (widget.values[key] ?? '').trim();

  bool get _dirty => widget.specs.any(
      (spec) => _controllers[spec.key]!.text.trim() != _original(spec.key));

  /// 本來就有值的欄位不能被清空——`CHATROOM_IDLE_TIMEOUT=` 這種空值會讓
  /// Hub 在讀設定時就起不來，而畫面上只會顯示「已存檔」。
  EnvFieldError? _validate(_EnvFieldSpec spec, String value) {
    final required = _original(spec.key).isNotEmpty;
    switch (spec.kind) {
      case _EnvKind.port:
        return validateEnvPort(value, required: required);
      case _EnvKind.nonNegInt:
        return validateEnvNonNegativeInt(value, required: required);
      case _EnvKind.url:
        return validateEnvUrl(value, required: required);
      case _EnvKind.text:
      case _EnvKind.choice:
        return required ? validateEnvRequiredText(value) : null;
    }
  }

  String _message(EnvFieldError error, AppLocalizations l10n) =>
      switch (error) {
        EnvFieldError.required => l10n.hostEnvErrorRequired,
        EnvFieldError.notInteger => l10n.hostEnvErrorInteger,
        EnvFieldError.portRange => l10n.hostEnvErrorPortRange,
        EnvFieldError.negative => l10n.hostEnvErrorNegative,
        EnvFieldError.badUrl => l10n.hostEnvErrorUrl,
      };

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _save() async {
    // await 之後不能再碰 context，先把字拿在手上
    final l10n = AppLocalizations.of(context);

    final errors = <String, EnvFieldError?>{};
    for (final spec in widget.specs) {
      errors[spec.key] = _validate(spec, _controllers[spec.key]!.text);
    }
    if (errors.values.any((e) => e != null)) {
      setState(() => _errors
        ..clear()
        ..addAll(errors));
      return;
    }

    final updates = <String, String>{};
    for (final spec in widget.specs) {
      final value = _controllers[spec.key]!.text.trim();
      if (value == _original(spec.key)) continue;
      updates[spec.key] = value;
    }
    if (updates.isEmpty) return;

    setState(() => _saving = true);
    try {
      await writeEnvUpdates(File(widget.path), updates);
    } on Object catch (e) {
      if (mounted) setState(() => _saving = false);
      // 🔴 訊息裡只有例外本身，不帶欄位值——token 走的是同一條路
      _say(l10n.hostEnvWriteFailed('$e'));
      return;
    }
    widget.onSaved(ref);
    if (mounted) setState(() => _saving = false);
    _say(widget.savedMessage);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);

    return _Panel(
      title: widget.title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final spec in widget.specs)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _field(spec, l10n),
            ),
          SelectableText(widget.path,
              style: UepText.code(size: 11.5, color: s.inkMute)),
          const SizedBox(height: 12),
          UepButton(
            label: l10n.commonSave,
            small: true,
            onPressed: (_saving || !_dirty) ? null : _save,
          ),
        ],
      ),
    );
  }

  Widget _field(_EnvFieldSpec spec, AppLocalizations l10n) {
    final s = context.uep;
    final error = _errors[spec.key];
    final errorText = error == null ? null : _message(error, l10n);

    if (spec.kind == _EnvKind.choice) {
      final current = _controllers[spec.key]!.text.trim();
      final value = spec.options.contains(current) ? current : '';
      return DropdownButtonFormField<String>(
        initialValue: value,
        decoration: InputDecoration(
          labelText: spec.key,
          errorText: errorText,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        items: [
          for (final option in spec.options)
            DropdownMenuItem(
              value: option,
              child: Text(option.isEmpty ? '—' : option,
                  style: UepText.code(size: 13, color: s.ink)),
            ),
        ],
        onChanged: _saving
            ? null
            : (v) => setState(() {
                  _controllers[spec.key]!.text = v ?? '';
                  _errors[spec.key] = null;
                }),
      );
    }

    final hidden = spec.secret && !_revealed.contains(spec.key);
    return TextField(
      controller: _controllers[spec.key],
      enabled: !_saving,
      obscureText: hidden,
      style: UepText.code(size: 13, color: s.ink),
      decoration: InputDecoration(
        labelText: spec.key,
        errorText: errorText,
        isDense: true,
        border: const OutlineInputBorder(),
        suffixIcon: spec.secret
            ? IconButton(
                tooltip: hidden ? l10n.commonShow : l10n.commonHide,
                icon: Icon(hidden ? Icons.visibility_off : Icons.visibility,
                    size: 18, color: s.inkMute),
                onPressed: () => setState(() => hidden
                    ? _revealed.add(spec.key)
                    : _revealed.remove(spec.key)),
              )
            : null,
      ),
      onChanged: (v) => setState(() => _errors[spec.key] = _validate(spec, v)),
    );
  }
}
