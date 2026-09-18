import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
/// 那台機器上有意義（見 kit UI 設計簡報 §6.0）。
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
            tooltip: '說明',
            icon: Icon(Icons.help_outline, size: 18, color: s.inkMute),
            onPressed: () => context.push('/help'),
          ),
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
                  '這台機器沒有 Hub 主持包。',
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
      title: '狀態',
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
              label: '設定',
              probe: Probe(ProbeState.unknown, 'server/.env 缺少埠號或 token'),
            );
          }
          return Column(children: [
            _LightRow(label: '進程', probe: h.process),
            const SizedBox(height: 14),
            _LightRow(label: '對外綁定', probe: h.reachable),
            const SizedBox(height: 14),
            _LightRow(label: '認證', probe: h.auth),
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
        title: '連線資訊',
        child: Text('讀不到 server/.env。',
            style: UepText.serif(size: 13, color: s.inkMute)),
      );
    }

    // 綁 0.0.0.0 時字面上的位址沒有意義——**沒有人連得到 0.0.0.0**。
    // 這裡不猜一個 IP 填進去（猜錯比留白更糟），而是講明要填什麼
    final address = env.bindsAllInterfaces
        ? 'http://<這台機器的 IP>:${env.port}'
        : 'http://${env.host}:${env.port}';

    return _Panel(
      title: '連線資訊',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CopyRow(label: 'Hub 位址', value: address),
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
            _CopyRow(label: '人類 token', value: env.humanToken, secret: true),
            const SizedBox(height: 10),
            _CopyRow(label: 'Agent token', value: env.token, secret: true),
            const SizedBox(height: 12),
            Text(
              'Agent token 不能開主持人模式。',
              style: UepText.serif(size: 12, color: s.inkMute, height: 1.6),
            ),
          ] else ...[
            _CopyRow(label: 'Token', value: env.token, secret: true),
            const SizedBox(height: 12),
            Text(
              '這台 Hub 只有一把共用 token。',
              style: UepText.serif(size: 12, color: s.inkMute, height: 1.6),
            ),
          ],
          if (env.bindsAllInterfaces) ...[
            const SizedBox(height: 6),
            Text(
              '位址請改成成員連得到的 IP。',
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
      title: 'AGENT 接入',
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
                  probe: Probe(ProbeState.unknown, '讀不到 kit 根目錄的 .env'),
                );
              }
              return Column(children: [
                _LightRow(label: '連線', probe: m.reach),
                const SizedBox(height: 14),
                _LightRow(label: '認證', probe: m.auth),
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
          MonoLabel('BRIDGE 版本', size: 9, letterSpacing: 1.6),
          const SizedBox(height: 5),
          SelectableText(
            version.isEmpty ? '讀不到 _build.json' : version,
            style: UepText.code(
                size: 13,
                color: version.isEmpty ? s.inkMute : UepColors.gold),
          ),
          if (version.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              '要確認 agent 用的是這一份，讓它呼叫 chatroom_join，'
              '比對回傳的 bridge.commit。',
              style: UepText.serif(size: 11.5, color: s.inkMute, height: 1.6),
            ),
          ],
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
    final status = ref.watch(tunnelStatusProvider);
    final actions = ref.watch(hostActionsProvider);
    final op = _opOf(ref, _tunnelKinds);
    final tunnelOpening = _isPending(ref, 'tunnel_start');

    return _Panel(
      title: '隧道',
      child: status.when(
        loading: () => const _LightRow(
            label: '狀態', probe: Probe.checking()),
        error: (e, _) => _LightRow(
            label: '狀態', probe: Probe(ProbeState.unknown, '$e')),
        data: (t) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _LightRow(
              label: '狀態',
              probe: Probe(t.state, t.detail, caveat: t.caveat),
            ),
            if (t.hasUrl) ...[
              const SizedBox(height: 12),
              _CopyRow(label: '隧道網址', value: t.url),
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
                      ? '開啟中…'
                      : !t.hasUrl
                          ? '開隧道'
                          : (t.state == ProbeState.unknown
                              ? '偵測到舊網址'
                              : '已經有一條'),
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
                    label: '關閉隧道',
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
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: s.bgCard,
        title: Text('開啟隧道',
            style: UepText.serif(
                size: 15, weight: FontWeight.w600, color: s.inkTitle)),
        content: Text(
          '開啟後任何拿到網址與 token 的人都能讀取所有房間。',
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
            child: Text('開啟',
                style: UepText.serif(size: 13, color: UepColors.gold)),
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
      baselineFailText: '讀不到隧道狀態，沒有送出指令',
      launch: actions.startTunnel,
      ready: (beforeUrl) async {
        ref.invalidate(tunnelStatusProvider);
        final t = await ref.read(tunnelStatusProvider.future);
        return t.hasUrl && t.url != beforeUrl;
      },
      okText: '隧道已開啟',
      timeoutText: '已送出，網址尚未更新。請查看 logs\\tunnel-*.log',
    );
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
          '目前的網址會立刻失效，重開會是新的網址。',
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

    return _Panel(
      title: 'HUB',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (windows) ...[
            _StatusLine(
              label: '狀態',
              value: switch (health?.process.state) {
                ProbeState.ok => '執行中',
                ProbeState.bad => '已停止',
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
                label: hubStarting ? '啟動中…' : '啟動 Hub',
                onPressed: hubStarting ? null : () => _startHub(ref, actions),
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
            ]),
            const SizedBox(height: 18),
            _StatusLine(
              label: '自動啟動',
              value: service?.registered == true ? '已註冊' : '未註冊',
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
  Future<void> _startHub(WidgetRef ref, HostActions actions) =>
      _launchAndWatch(
        ref,
        kind: 'hub_start',
        alreadyDone: () => _hubRunning(ref),
        alreadyText: 'Hub 已在執行中',
        launch: actions.startHub,
        ready: (_) => _hubRunning(ref),
        okText: 'Hub 已啟動',
        timeoutText: '已送出，尚未啟動完成。請查看 logs\\',
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
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: s.bgCard,
        title: Text('停止 Hub',
            style: UepText.serif(
                size: 15, weight: FontWeight.w600, color: s.inkTitle)),
        content: Text(
          '所有 agent 與 App 會立即斷線。',
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
      'detail': err.isNotEmpty ? err : (out.isNotEmpty ? out : 'Hub 已停止'),
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
        'error': '讀不到目前狀態，沒有送出指令（$e）',
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
        'error': '${baselineFailText ?? '讀不到目前狀態，沒有送出指令'}（$e）',
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

    return _Panel(
      title: '備份',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(spacing: 10, runSpacing: 10, children: [
            UepButton(
              small: true,
              variant: UepButtonVariant.outline,
              label: _busy ? '執行中…' : '立即備份',
              onPressed: _busy ? null : _backup,
            ),
            // 備份與還原要並排。**只有備份沒有還原，等於備份沒有出口**——
            // 而那件事要到真的需要還原的那一天才會被發現
            UepButton(
              small: true,
              variant: UepButtonVariant.outline,
              label: '還原備份',
              onPressed: _busy ? null : () => _pickAndRestore(context),
            ),
            UepButton(
              small: true,
              variant: UepButtonVariant.outline,
              label: '換 token',
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
        'error': '沒有可還原的備份',
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
              '現有的訊息、成員與附件會被這份備份取代。還原前 Hub 必須先停止。',
              style: UepText.serif(size: 13, color: s.ink, height: 1.7),
            ),
            if (!complete || !hasAttachments) ...[
              const SizedBox(height: 12),
              Text(
                !complete
                    ? '這份備份沒有 manifest，內容不明。'
                    : '這份備份不含附件。',
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
          '重啟 Hub 後舊 token 失效，所有成員都要換成新的。',
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
      title: Text('選擇備份',
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
                    : '沒有 manifest',
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
    // 還在跑。**這一格要存在**——按下去到結果出來之間有十幾秒，
    // 那段空白正是艾斯維爾說的「不知道按了有沒有用」。
    //
    // ⚠️ **擺在成敗判斷之前**：進行中還沒有成敗可言，而 `ok` 缺席時
    // `result['ok'] == true` 是 false ⇒ 會把一個正在跑的操作畫成
    // 「失敗：不知道為什麼」。測試就是這樣抓到的。
    if (result['pending'] == true) {
      return Text(
        result['kind'] == 'tunnel_start' ? '正在開啟隧道…' : '正在啟動…',
        style: UepText.serif(size: 11.5, color: s.inkMute, height: 1.5),
      );
    }
    final ok = result['ok'] == true;
    if (!ok) {
      return Text('失敗：${result['error'] ?? '原因不明'}',
          style: UepText.code(size: 11.5, color: UepColors.errorText));
    }
    if (result['kind'] == 'hub_start' || result['kind'] == 'tunnel_start') {
      // 逾時也走這裡：那不是失敗（進程可能正要起來），措辭在送出端寫好了
      return Text('${result['detail'] ?? ''}',
          style: UepText.serif(size: 11.5, color: s.inkMute, height: 1.5));
    }
    if (result['kind'] == 'rotate') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 這是使用者唯一看得到明碼的時刻，所以不遮——遮了他就得去翻 .env
          _CopyRow(label: '新 token', value: '${result['token'] ?? ''}'),
          const SizedBox(height: 6),
          Text('重啟 Hub 後生效。舊設定：${result['backup'] ?? ''}',
              style: UepText.serif(size: 11.5, color: s.inkMute, height: 1.5)),
        ],
      );
    }
    if (result['kind'] == 'hub_stop') {
      // 成功與否都走這裡：停止是那種「你以為做完了」的操作，沉默等於成功
      return Text('${result['detail'] ?? ''}',
          style: UepText.serif(size: 11.5, color: s.inkMute, height: 1.5));
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
          Text('還原前的備份：${result['safety_backup'] ?? ''}',
              style: UepText.serif(size: 11.5, color: s.inkMute, height: 1.5)),
          if (result['attachments_restored'] != true) ...[
            const SizedBox(height: 4),
            Text('這份備份不含附件。',
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
        Text('已備份：${result['dest'] ?? ''}',
            style: UepText.code(size: 11.5, color: s.inkSoft)),
        const SizedBox(height: 4),
        Text(
          hadAttachments
              ? '資料庫 ${result['db_bytes'] ?? 0} 位元組，附件 $files 個檔案'
              // 講明是「來源就沒有」而不是「沒備份到」——這兩者在磁碟上
              // 一模一樣，意義相反
              : '資料庫 ${result['db_bytes'] ?? 0} 位元組，不含附件',
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
      title: '安裝位置',
      child: SelectableText(kit.kitRoot,
          style: UepText.code(size: 11.5, color: s.inkSoft)),
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
        width: 78,
        child: MonoLabel(label, size: 9, letterSpacing: 1.4),
      ),
      Text(value, style: UepText.serif(size: 13.5, color: s.ink)),
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
