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
          _InstalledAt(kit: kit),
        ],
      ),
    );
  }
}

/// 安裝時間，以及它為什麼在這裡。
///
/// 🔴 **App 看不到 agent 的進程，所以「agent 認得那些工具了嗎」這一題
/// 答不了。** 但那個落差真實存在而且咬過人：Claude Code 若在安裝之前就
/// 開著，它連的是舊的 bridge——設定檔更新了，跑著的那個沒有
/// （2026-09-09：舊 bridge 沒有 `card_refs` 參數，發文被 Hub 擋下，
/// 而錯誤訊息指向他手上沒有的東西）。
///
/// **答不了的事不要假裝答得了**：這裡不畫一盞燈，只把安裝時間講出來，
/// 讓使用者自己對照——那是他答得出來而 App 答不出來的事。
class _InstalledAt extends ConsumerWidget {
  const _InstalledAt({required this.kit});

  final McpKit kit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final version = ref.watch(mcpBridgeVersionProvider).value ?? '';
    final when = kit.installedAt.isEmpty
        ? '（不知道）'
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
          Row(children: [
            MonoLabel('安裝於', size: 9, letterSpacing: 1.4),
            const SizedBox(width: 10),
            Text(when, style: UepText.code(size: 11.5, color: s.inkSoft)),
          ]),
          if (version.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(children: [
              MonoLabel('BRIDGE', size: 9, letterSpacing: 1.4),
              const SizedBox(width: 10),
              Flexible(
                child: Text(version,
                    style: UepText.code(size: 11.5, color: s.inkSoft)),
              ),
            ]),
          ],
          if (kit.targets.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(children: [
              MonoLabel('裝給', size: 9, letterSpacing: 1.4),
              const SizedBox(width: 10),
              Text(kit.targets.join('、'),
                  style: UepText.code(size: 11.5, color: s.inkSoft)),
            ]),
          ],
          const SizedBox(height: 10),
          Text(
            '⚠️ 你的 Claude Code / Codex 如果在上面那個時間之前就開著，'
            '它連的還是舊的 bridge——設定檔更新了，跑著的那個沒有。'
            '症狀是工具少了新參數，而錯誤訊息會指向你手上沒有的東西。'
            '重啟 agent 就會換過去。',
            style: UepText.serif(size: 11.5, color: s.inkMute, height: 1.6),
          ),
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
