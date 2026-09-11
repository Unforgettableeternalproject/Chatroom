import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../models/host_kit.dart';
import '../../state/host_actions.dart';
import '../../state/host_kit_providers.dart';
import '../../state/host_probe.dart';
import '../../state/mcp_kit_providers.dart';
import '../../widgets/kind_badge.dart';
import '../../widgets/uep_button.dart';

/// 主機控制台——**這台機器上的 Hub**。
///
/// ## 它與這個 App 其餘部分是兩種東西
///
/// App 的其餘部分是**客戶端**：連到某台 Hub，在哪台機器上跑都可以。
/// 這一頁是**遙控器**：它管理本機的 Hub 進程與檔案，只在裝了 host-kit 的
/// 那台機器上有意義（見 `docs/KIT-UI-DESIGN-BRIEF.md` §6.0）。
///
/// 所以沒有 host-kit 時，通往這裡的入口**整個不存在**——不是變灰。
/// 一個永遠按不動的入口比沒有這個功能更糟。
class HostConsoleScreen extends ConsumerWidget {
  const HostConsoleScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final kit = ref.watch(hostKitProvider).value;
    final mcp = ref.watch(mcpKitProvider).value;

    return Scaffold(
      backgroundColor: s.bg,
      appBar: AppBar(
        backgroundColor: s.bgSoft,
        // 與設定頁同一套：display 標題 + 底線。這頁原本用 mono 12 的小字
        // 標題，在其他頁之間看起來像另一個 App 的畫面
        surfaceTintColor: Colors.transparent,
        shape: Border(bottom: BorderSide(color: s.line)),
        title: Text('這台機器',
            style: UepText.display(size: 22, color: s.inkTitle)),
        actions: [
          IconButton(
            tooltip: '重新檢查',
            icon: Icon(Icons.refresh, size: 18, color: s.inkMute),
            onPressed: () {
              ref.invalidate(hostEnvProvider);
              ref.invalidate(hostHealthProvider);
              ref.invalidate(tunnelStatusProvider);
              ref.invalidate(serviceStatusProvider);
              ref.invalidate(mcpEnvProvider);
              ref.invalidate(mcpStatusProvider);
            },
          ),
        ],
      ),
      body: (kit == null && mcp == null)
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  '這台機器上找不到 Hub 主持包，也沒有接上 chatroom。',
                  style: UepText.serif(size: 14, color: s.inkMute),
                ),
              ),
            )
          // 與設定頁同寬同內距（560／32）。原本滿寬 24 內距，在寬視窗上
          // 每一行都拉到螢幕兩端——與其他頁擺在一起時最突兀的就是這件事
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: ListView(
                  padding: const EdgeInsets.all(32),
                  children: [
                    // 一個人可以同時是主持人與成員（多半就是），所以兩塊並存；
                    // 沒有的那一塊**整個不出現**，不是空著佔一個標題
                    if (mcp != null) ...[
                      _McpSection(kit: mcp),
                      if (kit != null) _sep(s),
                    ],
                    if (kit != null) ...[
                      _HealthSection(),
                      _sep(s),
                      _ShareSection(kit: kit),
                      _sep(s),
                      const _TunnelSection(),
                      _sep(s),
                      const _ControlSection(),
                      _sep(s),
                      const _DataSection(),
                      _sep(s),
                      _KitSection(kit: kit),
                    ],
                  ],
                ),
              ),
            ),
    );
  }
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

    return _Panel(
      title: '現在的狀態',
      // 主持人多半只是想確認一切正常，所以三盞燈要能一眼掃過去——
      // 「掃視」比「操作」重要（設計稿 §5）
      child: health.when(
        loading: () => const _LightRow(
          label: '檢查中',
          probe: Probe.checking(),
        ),
        error: (e, _) => _LightRow(
          label: '檢查失敗',
          probe: Probe(ProbeState.unknown, '$e'),
        ),
        data: (h) {
          if (h == null) {
            return const _LightRow(
              label: '設定不完整',
              probe: Probe(ProbeState.unknown, 'server/.env 裡沒有埠號或 token',
                  caveat: '重跑 host-kit 的 install.py 可以重建它'),
            );
          }
          return Column(children: [
            _LightRow(label: '① 進程', probe: h.process),
            const SizedBox(height: 14),
            _LightRow(label: '② 對外綁定', probe: h.reachable),
            const SizedBox(height: 14),
            _LightRow(label: '③ 認證', probe: h.auth),
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
              MonoLabel(label, size: 9, letterSpacing: 1.6),
              const SizedBox(width: 10),
              Flexible(
                child: Text(probe.detail,
                    style: UepText.serif(size: 13.5, color: s.ink)),
              ),
            ]),
            // ⚠️ **綠燈也可能有 caveat。** 「本機打得到」不等於「別台機器
            // 連得到」，而那個落差是主持人最常撞、也最難自己想到的一關
            if (probe.caveat.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(probe.caveat,
                  style: UepText.serif(
                      size: 11.5, color: s.inkMute, height: 1.5)),
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
    final env = ref.watch(hostEnvProvider).value;

    if (env == null || !env.isComplete) {
      return _Panel(
        title: '發給成員的連線資訊',
        child: Text('讀不到 server/.env，沒有東西可以發。',
            style: UepText.serif(size: 13, color: s.inkMute)),
      );
    }

    // 綁 0.0.0.0 時字面上的位址沒有意義——**沒有人連得到 0.0.0.0**。
    // 這裡不猜一個 IP 填進去（猜錯比留白更糟），而是講明要填什麼
    final address = env.bindsAllInterfaces
        ? 'http://<這台機器的 IP>:${env.port}'
        : 'http://${env.host}:${env.port}';

    return _Panel(
      title: '發給成員的連線資訊',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CopyRow(label: 'Hub 位址', value: address),
          const SizedBox(height: 10),
          _CopyRow(label: 'Token', value: env.token, secret: true),
          const SizedBox(height: 14),
          Text(
            '成員把這兩行填進 chatroom-mcp-kit 的 install.py 提示即可。',
            style: UepText.serif(size: 12, color: s.inkMute, height: 1.6),
          ),
          if (env.bindsAllInterfaces) ...[
            const SizedBox(height: 6),
            Text(
              '⚠️ 目前綁在所有介面（0.0.0.0），位址要換成成員連得到的那個 IP'
              '——同區網填內網 IP，走 VPN 填 VPN 介面的 IP。',
              style: UepText.serif(size: 12, color: s.inkMute, height: 1.6),
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

    return _Panel(
      title: 'AGENT 接入（MCP）',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          status.when(
            loading: () =>
                const _LightRow(label: '連線', probe: Probe.checking()),
            error: (e, _) => _LightRow(
                label: '連線', probe: Probe(ProbeState.unknown, '$e')),
            data: (m) {
              if (m == null) {
                return const _LightRow(
                  label: '設定',
                  probe: Probe(ProbeState.unknown, '讀不到 kit 根目錄的 .env',
                      caveat: '重跑 install.py 可以重建它'),
                );
              }
              return Column(children: [
                _LightRow(label: '① 連線', probe: m.reach),
                const SizedBox(height: 14),
                _LightRow(label: '② 認證', probe: m.auth),
              ]);
            },
          ),
          if (env != null && env.url.isNotEmpty) ...[
            const SizedBox(height: 14),
            _CopyRow(label: '連的 Hub', value: env.url),
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
          MonoLabel('已安裝的 BRIDGE', size: 9, letterSpacing: 1.6),
          const SizedBox(height: 5),
          SelectableText(
            version.isEmpty ? '讀不到（找不到 bridge/chatroom_mcp/_build.json）' : version,
            style: UepText.code(
                size: 13,
                color: version.isEmpty ? s.inkMute : UepColors.gold),
          ),
          const SizedBox(height: 10),
          Text(
            version.isEmpty
                // 讀不到就不要給一個做不到的指示——講清楚少了什麼
                ? '沒有這份檔案就對照不了版本。kit 解開之後沒有 .git，'
                    '_build.json 是現場唯一可靠的版本來源；缺了它多半是解壓不完整。'
                : '要確認 agent 跑的是不是這一份：讓它呼叫 chatroom_join，'
                    '看回傳的 bridge.commit。和上面這個不一樣，就是它還連著'
                    '舊的——重啟 Claude Code / Codex 就會換過去。\n\n'
                    '⚠️ 不要看工具說明結尾的版本：那個數字報的是「這支工具的'
                    '描述何時載入」，與 bridge 實際跑什麼無關。同一個 session '
                    '裡每支工具還可能不一樣，而且可能全部都是過期的。',
            style: UepText.serif(size: 11.5, color: s.inkMute, height: 1.6),
          ),
          const SizedBox(height: 10),
          // 次要資訊：對照不上時拿來判斷「這包是什麼時候、裝給誰的」
          Wrap(spacing: 18, runSpacing: 4, children: [
            if (when.isNotEmpty)
              Text('安裝於 $when',
                  style: UepText.code(size: 10.5, color: s.inkMute)),
            if (kit.targets.isNotEmpty)
              Text('裝給 ${kit.targets.join('、')}',
                  style: UepText.code(size: 10.5, color: s.inkMute)),
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
    final s = context.uep;
    final status = ref.watch(tunnelStatusProvider);
    final actions = ref.watch(hostActionsProvider);

    return _Panel(
      title: '對外協作（隧道）',
      child: status.when(
        loading: () => const _LightRow(
            label: '隧道', probe: Probe.checking()),
        error: (e, _) => _LightRow(
            label: '隧道', probe: Probe(ProbeState.unknown, '$e')),
        data: (t) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _LightRow(
              label: '隧道',
              probe: Probe(t.state, t.detail, caveat: t.caveat),
            ),
            if (t.hasUrl) ...[
              const SizedBox(height: 12),
              _CopyRow(label: '隧道網址', value: t.url),
            ],
            if (actions != null && Platform.isWindows) ...[
              const SizedBox(height: 14),
              Row(children: [
                UepButton(
                  small: true,
                  variant: UepButtonVariant.outline,
                  label: t.hasUrl ? '再開一條' : '開隧道',
                  onPressed: () => _confirmTunnel(context, ref, actions),
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
                    label: '關閉隧道',
                    onPressed: () => _confirmStopTunnel(context, ref),
                  ),
                ],
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    t.hasUrl
                        ? '關掉那個隧道視窗也等於關閉。網址是臨時的，'
                            '重開一定是新的網址。'
                        : '開了之後這台 Hub 就在公網上，擋在前面的只有 token。',
                    style: UepText.serif(
                        size: 11.5, color: s.inkMute, height: 1.5),
                  ),
                ),
              ]),
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
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: s.bgCard,
        title: Text('開隧道之前',
            style: UepText.serif(
                size: 15, weight: FontWeight.w600, color: s.inkTitle)),
        content: Text(
          '隧道一開，任何知道網址的人都能連到這個 Hub，擋在前面的只有 token。\n\n'
          '而 token 的權限比多數人以為的大：拿到它的人讀得到「所有房間」的訊息、'
          '成員與附件——包含他沒有加入的房間，以及已經封存的舊房間。\n\n'
          '所以不要用「開另一個房間」當隔離。不同信任層級的協作請開不同的 Hub。',
          style: UepText.serif(size: 13, color: s.ink, height: 1.7),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消',
                style: UepText.serif(size: 13, color: s.inkMute)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('開隧道',
                style: UepText.serif(size: 13, color: UepColors.gold)),
          ),
        ],
      ),
    );
    if (go != true) return;
    await actions.startTunnel();
    // 隧道要幾秒才拿得到網址（cloudflared 要先跟 Cloudflare 要一個），
    // 立刻重讀只會看到「沒開」——那會讓人以為按了沒反應而再按一次
    await Future<void>.delayed(const Duration(seconds: 4));
    ref.invalidate(tunnelStatusProvider);
  }

  /// 關閉隧道。
  ///
  /// 要確認，但講的後果與開隧道那個不同：關掉之後**網址永久失效**，
  /// 而外面的人手上拿的就是那個網址。重開會是新的一條，要重發給所有人。
  Future<void> _confirmStopTunnel(BuildContext context, WidgetRef ref) async {
    final s = context.uep;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: s.bgCard,
        title: Text('關閉隧道',
            style: UepText.serif(
                size: 15, weight: FontWeight.w600, color: s.inkTitle)),
        content: Text(
          '現在那個網址會立刻失效，從外面連進來的人全部斷線。\n\n'
          '重開會拿到**不一樣的**網址——你得再發一次給所有成員。'
          '只是想換 token 或重啟 Hub 的話，不必關隧道。\n\n'
          '內網與 VPN 的連線不受影響。',
          style: UepText.serif(size: 13, color: s.ink, height: 1.7),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消',
                style: UepText.serif(size: 13, color: s.inkMute)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('關閉隧道',
                style: UepText.serif(size: 13, color: UepColors.gold)),
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
    final s = context.uep;
    final actions = ref.watch(hostActionsProvider);
    if (actions == null) return const SizedBox.shrink();

    // 服務註冊是排程任務，只有 Windows 有。**藏起來而不是顯示為失敗**——
    // 那不是壞掉，是這台機器沒有那個東西（設計稿 §6.3）
    final windows = Platform.isWindows;
    final service = ref.watch(serviceStatusProvider).value;

    return _Panel(
      title: '啟動與自啟',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (windows) ...[
            Row(children: [
              UepButton(
                small: true,
                label: '啟動 Hub',
                onPressed: () async {
                  await actions.startHub();
                  await Future<void>.delayed(const Duration(seconds: 3));
                  ref.invalidate(hostHealthProvider);
                },
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
                label: '停止 Hub',
                onPressed: () => _confirmStop(context, ref),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  // 講明它跑在哪裡——不講的話，關掉那個黑視窗會讓所有人斷線，
                  // 而按下按鈕的人不會預期那件事
                  '會開一個獨立的視窗跑 Hub。關掉那個視窗也等於停止；'
                  '關掉這個 App 不會——它只是遙控器。',
                  style: UepText.serif(
                      size: 11.5, color: s.inkMute, height: 1.5),
                ),
              ),
            ]),
            const SizedBox(height: 18),
          ],
          if (windows) ...[
            Text('開機／登入時自動啟動',
                style: UepText.serif(
                    size: 13, weight: FontWeight.w600, color: s.inkTitle)),
            const SizedBox(height: 6),
            Text(
              service?.raw.isNotEmpty == true ? service!.raw : '（問不到狀態）',
              style: UepText.code(size: 11.5, color: s.inkSoft),
            ),
            const SizedBox(height: 10),
            Wrap(spacing: 10, runSpacing: 10, children: [
              UepButton(
                small: true,
                variant: UepButtonVariant.outline,
                label: service?.registered == true ? '重新註冊' : '註冊',
                onPressed: () => _runService(ref, 'install'),
              ),
              UepButton(
                small: true,
                variant: UepButtonVariant.outline,
                label: '啟動',
                onPressed: () => _runService(ref, 'start'),
              ),
              // 停止不在這裡——它是全域的（連前景起的都殺），放在上面
              // 「啟動 Hub」旁邊。同一件事出現兩個入口只會讓人以為
              // 這顆停的是排程、那顆停的是前景
              if (service?.registered == true)
                UepButton(
                  small: true,
                  variant: UepButtonVariant.outline,
                  label: '取消註冊',
                  onPressed: () => _runService(ref, 'uninstall'),
                ),
            ]),
            const SizedBox(height: 8),
            Text(
              // 這個差別現在只寫在 README 裡，而它決定「重開機之後還在不在」
              '一般權限註冊＝登入時自啟；以系統管理員執行這個 App 再註冊'
              '＝開機自啟（沒登入也跑）。停止 Hub 請用上面那顆——'
              '它連前景視窗裡跑的那個也停得掉。',
              style: UepText.serif(size: 11.5, color: s.inkMute, height: 1.5),
            ),
            const SizedBox(height: 18),
          ],
          Wrap(spacing: 10, runSpacing: 10, children: [
            UepButton(
                small: true,
                variant: UepButtonVariant.outline,
                label: '開啟日誌資料夾',
                onPressed: actions.openLogs),
            UepButton(
                small: true,
                variant: UepButtonVariant.outline,
                label: '開啟備份資料夾',
                onPressed: actions.openBackups),
          ]),
        ],
      ),
    );
  }

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
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: s.bgCard,
        title: Text('停止 Hub',
            style: UepText.serif(
                size: 15, weight: FontWeight.w600, color: s.inkTitle)),
        content: Text(
          '現在連著的每一個 agent 與每一台 App 都會在這一刻斷線。\n\n'
          '排程起的與手動起的都會停——包含那個黑視窗裡跑的。\n\n'
          '如果有註冊自啟，觸發器會一併停用（按「啟動」會自動啟用回來），'
          '否則排程會在一分鐘內把它拉回來。',
          style: UepText.serif(size: 13, color: s.ink, height: 1.7),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消',
                style: UepText.serif(size: 13, color: s.inkMute)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('停止 Hub',
                style: UepText.serif(size: 13, color: UepColors.gold)),
          ),
        ],
      ),
    );
    if (go != true) return;
    final actions = ref.read(hostActionsProvider);
    if (actions == null) return;
    await actions.stopHub();
    ref.invalidate(serviceStatusProvider);
    ref.invalidate(hostHealthProvider);
  }
}

/// 最近一次備份／換 token 的結果。
///
/// 🔴 **不放在 widget 的 State 裡。** 這一頁的 provider 一 invalidate
/// （按了「重新檢查」、或任何一個狀態刷新）整個子樹就重建，那時剛換出來的
/// token 會跟著消失——而它是隨機字串，畫面上那一次是使用者唯一看得到它的
/// 機會。同樣的形狀在這個 repo 已經咬過四次（草稿存在 State 裡）。
class LastDataOp extends Notifier<Map<String, dynamic>?> {
  @override
  Map<String, dynamic>? build() => null;

  void set(Map<String, dynamic> result) => state = result;
}

final lastDataOpProvider =
    NotifierProvider<LastDataOp, Map<String, dynamic>?>(LastDataOp.new);

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
    final s = context.uep;
    final actions = ref.watch(hostActionsProvider);
    if (actions == null) return const SizedBox.shrink();
    final last = ref.watch(lastDataOpProvider);

    return _Panel(
      title: '資料與安全',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(spacing: 10, runSpacing: 10, children: [
            UepButton(
              small: true,
              variant: UepButtonVariant.outline,
              label: _busy ? '執行中…' : '立即備份',
              onPressed: _busy ? () {} : _backup,
            ),
            // 備份與還原要並排。**只有備份沒有還原，等於備份沒有出口**——
            // 而那件事要到真的需要還原的那一天才會被發現
            UepButton(
              small: true,
              variant: UepButtonVariant.outline,
              label: '還原備份',
              onPressed: _busy ? () {} : () => _pickAndRestore(context),
            ),
            UepButton(
              small: true,
              variant: UepButtonVariant.outline,
              label: '換 token',
              onPressed: _busy ? () {} : () => _confirmRotate(context),
            ),
          ]),
          const SizedBox(height: 8),
          Text(
            // 為什麼備份是兩份東西——這件事不講，還原的人會以為只要 db
            '備份會把資料庫與 attachments/ 一起收進 backups\\。'
            '兩份缺一，還原後訊息都在、圖全變 410。'
            '還原前 Hub 必須先停，而且會自動先備份現況。',
            style: UepText.serif(size: 11.5, color: s.inkMute, height: 1.5),
          ),
          if (last != null) ...[
            const SizedBox(height: 14),
            _OpResult(result: last),
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
        'error': '還沒有任何備份可以還原。先按一次「立即備份」。',
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
    final complete = backup['complete'] == true;
    final hasAttachments = backup['attachments_existed'] == true;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: s.bgCard,
        title: Text('還原 ${backup['name']}',
            style: UepText.serif(
                size: 15, weight: FontWeight.w600, color: s.inkTitle)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '現在的訊息、成員與附件會被這份備份**整個取代**。\n\n'
              '還原之前會自動備份現況，拿錯備份時從那一份退回來。\n\n'
              'Hub 必須先停——還在跑的話會中止，不會做一半。\n\n'
              'server\\.env（token、port）不會被動到：還原的是資料，不是設定。',
              style: UepText.serif(size: 13, color: s.ink, height: 1.7),
            ),
            if (!complete || !hasAttachments) ...[
              const SizedBox(height: 12),
              Text(
                !complete
                    // 沒有 manifest 的那種要特別講：它不是這支腳本產的，
                    // 裡面有什麼沒人知道
                    ? '⚠️ 這份備份沒有 manifest，來歷不明。它裡面有什麼、'
                        '完不完整，這裡答不出來。'
                    : '⚠️ 這份備份不含附件。還原後訊息都在，但圖與檔案'
                        '會變成「metadata 在、內容不在」（下載時回 410）。',
                style: UepText.serif(
                    size: 12.5, color: UepColors.errorText, height: 1.6),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消',
                style: UepText.serif(size: 13, color: s.inkMute)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('還原',
                style: UepText.serif(size: 13, color: UepColors.gold)),
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
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: s.bgCard,
        title: Text('換掉 token',
            style: UepText.serif(
                size: 15, weight: FontWeight.w600, color: s.inkTitle)),
        content: Text(
          '換完要重啟 Hub 才生效。在重啟之前，舊的那把照樣通、新的不通。\n\n'
          '重啟之後反過來：每一個 agent、每一台 App 都連不上，'
          '直到你把新 token 一個一個發給他們。\n\n'
          '舊的會留在 server\\.env.bak-<時間> 裡，要退回去時從那裡拿。',
          style: UepText.serif(size: 13, color: s.ink, height: 1.7),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消',
                style: UepText.serif(size: 13, color: s.inkMute)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('換 token',
                style: UepText.serif(size: 13, color: UepColors.gold)),
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
    return AlertDialog(
      backgroundColor: s.bgCard,
      title: Text('要還原哪一份',
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
                  style: UepText.code(size: 12, color: s.ink)),
              subtitle: Text(
                complete
                    ? '資料庫 $bytes 位元組・附件 $files 個檔案'
                    : '沒有 manifest，來歷不明',
                style: UepText.serif(
                    size: 11,
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
          child: Text('取消',
              style: UepText.serif(size: 13, color: s.inkMute)),
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
    final ok = result['ok'] == true;
    if (!ok) {
      return Text('失敗：${result['error'] ?? '不知道為什麼'}',
          style: UepText.code(size: 11.5, color: UepColors.errorText));
    }
    if (result['kind'] == 'rotate') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 這是使用者唯一看得到明碼的時刻，所以不遮——遮了他就得去翻 .env
          _CopyRow(label: '新 token', value: '${result['token'] ?? ''}'),
          const SizedBox(height: 6),
          Text('還沒生效，要重啟 Hub。舊設定：${result['backup'] ?? ''}',
              style: UepText.serif(size: 11.5, color: s.inkMute, height: 1.5)),
        ],
      );
    }
    if (result['kind'] == 'tunnel_stop') {
      // ⚠️ 這裡的 ok:true 有兩種：真的關掉了，與「本來就沒有隧道」。
      // 兩者都不是失敗，但講成同一句會讓人以為自己關掉了一條不存在的東西
      return Text('${result['detail'] ?? ''}',
          style: UepText.serif(size: 11.5, color: s.inkMute, height: 1.5));
    }
    if (result['kind'] == 'restore') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('已還原：${result['restored_from'] ?? ''}',
              style: UepText.code(size: 11.5, color: s.inkSoft)),
          const SizedBox(height: 4),
          // 退路要跟結果一起講。還原完才發現拿錯備份的人，需要的就是這一行
          Text('還原前的現況備份在：${result['safety_backup'] ?? ''}',
              style: UepText.serif(size: 11.5, color: s.inkMute, height: 1.5)),
          if (result['attachments_restored'] != true) ...[
            const SizedBox(height: 4),
            Text('⚠️ 那份備份不含附件——圖與檔案現在會是 410。',
                style: UepText.serif(
                    size: 11.5, color: UepColors.errorText, height: 1.5)),
          ],
        ],
      );
    }
    final hadAttachments = result['attachments_existed'] == true;
    final files = result['attachment_files'] ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('備份完成：${result['dest'] ?? ''}',
            style: UepText.code(size: 11.5, color: s.inkSoft)),
        const SizedBox(height: 4),
        Text(
          hadAttachments
              ? '資料庫 ${result['db_bytes'] ?? 0} 位元組，附件 $files 個檔案'
              // 講明是「來源就沒有」而不是「沒備份到」——這兩者在磁碟上
              // 一模一樣，意義相反
              : '資料庫 ${result['db_bytes'] ?? 0} 位元組；'
                  '來源沒有 attachments/，這份備份不含附件',
          style: UepText.serif(
              size: 11.5,
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
        width: 78,
        child: MonoLabel(widget.label, size: 9, letterSpacing: 1.4),
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
            style: UepText.code(size: 12, color: s.ink),
          ),
        ),
      ),
      if (widget.secret)
        IconButton(
          tooltip: _revealed ? '遮起來' : '顯示',
          icon: Icon(_revealed ? Icons.visibility_off : Icons.visibility,
              size: 16, color: s.inkMute),
          onPressed: () => setState(() => _revealed = !_revealed),
        ),
      IconButton(
        tooltip: _copied ? '已複製' : '複製',
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
      title: '這一包在哪',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(kit.kitRoot,
              style: UepText.code(size: 11.5, color: s.inkSoft)),
          const SizedBox(height: 8),
          Text(
            '設定在 server/.env，日誌在 logs/，資料庫與附件在 server/。'
            '搬動這個資料夾會讓這一頁找不到它。',
            style: UepText.serif(size: 12, color: s.inkMute, height: 1.6),
          ),
        ],
      ),
    );
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
        // 字級用 MonoLabel 預設（9／1.8），與設定頁的區塊標籤同一組
        MonoLabel(title),
        const SizedBox(height: 12),
        // 不再包邊框卡片——分段交給 `_sep()` 的分隔線。留 width 撐滿，
        // 否則 Column 會依內容縮寬，右側的說明文字排版跟著跳
        SizedBox(width: double.infinity, child: child),
      ],
    );
  }
}
