import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/l10n.dart';
import '../../state/runner_kit_providers.dart';
import '../../widgets/empty_error_states.dart';
import '../../widgets/uep_button.dart';
import 'runner_workspaces_section.dart';

/// 執行器層的「允許派工 agent 使用的 MCP 伺服器」。
///
/// ## 為什麼在執行器分頁而不是工作區卡片
///
/// `allowed_mcp_servers` 是 `RunnerConfig` 的欄位，整台執行器共用一份——
/// 每一筆 run 不論派到哪個工作區，都吃同一份允許清單。放進工作區卡片的話，
/// 畫面會暗示「這個工作區可以有自己的 MCP」，而檔案裡根本沒有那一層。
///
/// ## 選項從哪裡來
///
/// `claude mcp list`，而且是在**執行器自己的 `CLAUDE_CONFIG_DIR`** 底下列。
/// 跟著登入進來的 claude.ai 連接器不在任何 `.claude.json` 的 `mcpServers`
/// 裡，只有這一條命令問得到；本機 stdio 伺服器也一起列出來，因為執行器
/// 對它們同樣是預設拒絕。
///
/// 已經寫在設定裡、但這次沒列到的名字**照樣要畫出來**並標「本機找不到」：
/// 靜默丟掉的症狀是存檔那一刻把別人設的允許項目一起拿掉。
class RunnerMcpSection extends ConsumerWidget {
  const RunnerMcpSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final cfg = ref.watch(runnerConfigProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.hostRunnerPanelMcp,
            style: UepText.fieldLabel(color: s.inkMute)),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: cfg.when(
            loading: () => Text(l10n.commonLoading,
                style: UepText.serif(size: 14, color: s.inkMute)),
            error: (e, _) => ErrorState(error: e),
            data: (config) {
              if (config == null) return const SizedBox.shrink();
              return _RunnerMcpCard(
                key: ValueKey('mcp:${config.path}:'
                    '${config.allowedMcpServers.join(",")}'),
                config: config,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _RunnerMcpCard extends ConsumerStatefulWidget {
  const _RunnerMcpCard({super.key, required this.config});

  final RunnerConfigFile config;

  @override
  ConsumerState<_RunnerMcpCard> createState() => _RunnerMcpCardState();
}

class _RunnerMcpCardState extends ConsumerState<_RunnerMcpCard> {
  late Set<String> _selected = _initial();
  bool _saving = false;

  /// 檔案裡的值。**沒有這一鍵時是「只有 chatroom」**——執行器的預設就是它，
  /// 不是「全部允許」。
  Set<String> _initial() {
    final names = widget.config.allowedMcpServers
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
    names.add(kRunnerRequiredMcpServer);
    return names;
  }

  bool get _dirty {
    final before = _initial();
    return before.length != _selected.length ||
        !before.containsAll(_selected);
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      await saveRunnerAllowedMcpServers(widget.config,
          servers: _selected.toList()..sort());
    } on Object catch (e) {
      if (mounted) setState(() => _saving = false);
      ref.invalidate(runnerConfigProvider);
      messenger.showSnackBar(SnackBar(content: Text(runnerErrorText(e, l10n))));
      return;
    }
    final said = await runnerApplyReload(ref, l10n);
    if (mounted) setState(() => _saving = false);
    messenger.showSnackBar(SnackBar(content: Text(said)));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final machine = ref.watch(machineMcpServersProvider);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration:
          BoxDecoration(color: s.bgCard, border: Border.all(color: s.hairline)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(l10n.hostRunnerMcpNote,
                    style: UepText.serif(size: 13, color: s.inkMute)),
              ),
              IconButton(
                tooltip: l10n.hostRunnerMcpRefresh,
                onPressed: machine.isLoading
                    ? null
                    : () => ref.invalidate(machineMcpServersProvider),
                icon: Icon(Icons.refresh, size: 18, color: s.inkMute),
              ),
            ],
          ),
          const SizedBox(height: 4),
          machine.when(
            loading: () => Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(l10n.hostRunnerMcpLoading,
                  style: UepText.serif(size: 13, color: s.inkMute)),
            ),
            error: (e, _) => _rows(s, l10n, machine: null, error: '$e'),
            // 🔴 問不到不等於「本機沒有這些」：`names` 是 null 時照樣列出
            // 設定裡的名字，但**不**在它們旁邊標「本機找不到」
            data: (found) =>
                _rows(s, l10n, machine: found.names, error: found.error),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: UepButton(
              label: l10n.hostRunnerSaveApply,
              small: true,
              onPressed: (_saving || !_dirty) ? null : _save,
            ),
          ),
        ],
      ),
    );
  }

  /// 一台伺服器一列。清單＝本機列到的 ∪ 設定裡已經有的。
  Widget _rows(UepSurface s, AppLocalizations l10n,
      {required List<String>? machine, required String error}) {
    final known = <String>{...?machine, ..._initial(), ..._selected};
    final names = known.toList()
      ..sort((a, b) {
        // chatroom 永遠在最上面：它是唯一一個不能取消的
        if (a == kRunnerRequiredMcpServer) return -1;
        if (b == kRunnerRequiredMcpServer) return 1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(l10n.hostRunnerMcpListFailed(error),
                style: UepText.serif(size: 12.5, color: UepColors.error)),
          ),
        for (final name in names)
          _row(
            s,
            l10n,
            name: name,
            missing: machine != null && !machine.contains(name),
          ),
      ],
    );
  }

  Widget _row(UepSurface s, AppLocalizations l10n,
      {required String name, required bool missing}) {
    final required = name == kRunnerRequiredMcpServer;
    final checked = required || _selected.contains(name);
    void toggle(bool? v) {
      if (required) return;
      setState(() {
        if (v == true) {
          _selected = {..._selected, name};
        } else {
          _selected = {..._selected}..remove(name);
        }
      });
    }

    return InkWell(
      onTap: (_saving || required) ? null : () => toggle(!checked),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
              width: 34,
              child: Checkbox(
                value: checked,
                activeColor: UepColors.gold,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                onChanged: (_saving || required) ? null : toggle,
              ),
            ),
            Expanded(
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: UepText.code(size: 12.5, color: s.ink)),
            ),
            if (required)
              _tag(s, l10n.hostRunnerMcpRequired)
            else if (missing)
              _tag(s, l10n.hostRunnerMcpMissing),
          ],
        ),
      ),
    );
  }

  Widget _tag(UepSurface s, String label) => Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Text(label, style: UepText.fieldLabel(color: s.inkMute)),
      );
}
