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
        title: Text('這台機器',
            style: UepText.mono(
                size: 12, color: s.inkTitle, letterSpacing: 2.0)),
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
          : ListView(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
              children: [
                // 一個人可以同時是主持人與成員（多半就是），所以兩塊並存；
                // 沒有的那一塊**整個不出現**，不是空著佔一個標題
                if (mcp != null) ...[
                  _McpSection(kit: mcp),
                  const SizedBox(height: 28),
                ],
                if (kit != null) ...[
                  _HealthSection(),
                  const SizedBox(height: 28),
                  _ShareSection(kit: kit),
                  const SizedBox(height: 28),
                  const _TunnelSection(),
                  const SizedBox(height: 28),
                  const _ControlSection(),
                  const SizedBox(height: 28),
                  _KitSection(kit: kit),
                ],
              ],
            ),
    );
  }
}

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
/// ⚠️ **所以這裡不給任何「怎麼查」的方法，只給一個必然正確的動作：重啟。**
/// 重啟很便宜，而確認它有沒有必要反而不便宜——在還沒有一條驗證過的查法
/// 之前，給一個沒驗過的方法就是今天已經犯過三次的那個錯。
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
                : '不確定 agent 跑的是不是這一份的話，重啟一次 Claude Code / '
                    'Codex 最快——重啟很便宜，而確認它有沒有必要反而不便宜。\n\n'
                    '⚠️ 不要用工具說明結尾的版本判斷：宿主端會快取工具描述，'
                    '同一個 session 裡不同工具可能報出不同的版本，而其中一個'
                    '已經不存在了。',
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
                  label: t.hasUrl ? '再開一條' : '開隧道',
                  onPressed: () => _confirmTunnel(context, ref, actions),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    // 「關」不放在這裡是刻意的：隧道活在自己的視窗裡，
                    // 關掉那個視窗就是關隧道。做一顆按鈕去殺別人的進程，
                    // 會在殺錯的時候完全看不出來
                    '關隧道＝把那個隧道視窗關掉。',
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
                label: '啟動 Hub',
                onPressed: () async {
                  await actions.startHub();
                  await Future<void>.delayed(const Duration(seconds: 3));
                  ref.invalidate(hostHealthProvider);
                },
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  // 講明它跑在哪裡——不講的話，關掉那個黑視窗會讓所有人斷線，
                  // 而按下按鈕的人不會預期那件事
                  '會開一個獨立的視窗跑 Hub。關掉那個視窗＝停止 Hub；'
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
                label: service?.registered == true ? '重新註冊' : '註冊',
                onPressed: () => _runService(ref, 'install'),
              ),
              UepButton(
                label: '啟動',
                onPressed: () => _runService(ref, 'start'),
              ),
              UepButton(
                label: '停止',
                onPressed: () => _runService(ref, 'stop'),
              ),
              if (service?.registered == true)
                UepButton(
                  label: '取消註冊',
                  onPressed: () => _runService(ref, 'uninstall'),
                ),
            ]),
            const SizedBox(height: 8),
            Text(
              // 這個差別現在只寫在 README 裡，而它決定「重開機之後還在不在」
              '一般權限註冊＝登入時自啟；以系統管理員執行這個 App 再註冊'
              '＝開機自啟（沒登入也跑）。',
              style: UepText.serif(size: 11.5, color: s.inkMute, height: 1.5),
            ),
            const SizedBox(height: 18),
          ],
          UepButton(label: '開啟日誌資料夾', onPressed: actions.openLogs),
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
    final s = context.uep;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MonoLabel(title, size: 9.5, letterSpacing: 2.0),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: s.bgCard,
            border: Border.all(color: s.line),
            borderRadius: BorderRadius.circular(8),
          ),
          child: child,
        ),
      ],
    );
  }
}
