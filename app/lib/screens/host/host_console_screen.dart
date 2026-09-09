import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../models/host_kit.dart';
import '../../state/host_kit_providers.dart';
import '../../state/host_probe.dart';
import '../../widgets/kind_badge.dart';

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

    return Scaffold(
      backgroundColor: s.bg,
      appBar: AppBar(
        backgroundColor: s.bgSoft,
        title: Text('主機',
            style: UepText.mono(
                size: 12, color: s.inkTitle, letterSpacing: 2.0)),
        actions: [
          IconButton(
            tooltip: '重新檢查',
            icon: Icon(Icons.refresh, size: 18, color: s.inkMute),
            onPressed: () {
              ref.invalidate(hostEnvProvider);
              ref.invalidate(hostHealthProvider);
            },
          ),
        ],
      ),
      body: kit == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  '這台機器上找不到 Hub 主持包。',
                  style: UepText.serif(size: 14, color: s.inkMute),
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
              children: [
                _HealthSection(),
                const SizedBox(height: 28),
                _ShareSection(kit: kit),
                const SizedBox(height: 28),
                _KitSection(kit: kit),
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
