/// 執行器分頁頂部那一列：**這台機器上的執行器現在動不動**，以及起停它。
///
/// 在這一列之前，App 裡沒有任何入口開得了或關得了本機執行器——要停一台
/// 正在接派工的機器，只能去開 PowerShell 打 `Disable-ScheduledTask`。
/// 而「先停用再停止」這個順序不知道的人會做錯：只 `Stop` 的話排程會在
/// 一分鐘內把它拉回來（理由見 `runner_service.dart` 的開頭）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/l10n.dart';
import '../../state/kit_installer.dart';
import '../../state/runner_service.dart';
import '../../widgets/uep_button.dart';
import 'host_value_row.dart';

class RunnerServiceRow extends ConsumerStatefulWidget {
  const RunnerServiceRow({super.key});

  @override
  ConsumerState<RunnerServiceRow> createState() => _RunnerServiceRowState();
}

class _RunnerServiceRowState extends ConsumerState<RunnerServiceRow> {
  Timer? _poll;

  /// 現在正在起或停。按鈕按不得，字改成進行中——不然按下去畫面完全不動，
  /// 而「還在停」與「根本沒動」長得一樣。
  bool _busy = false;

  /// 上一次操作說的那一句。成功時清空。
  String _failure = '';

  @override
  void initState() {
    super.initState();
    // 輪詢放在畫面層（同派工異常面板）：這一列不在畫面上時定時器跟著走
    _poll = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_busy) ref.invalidate(runnerServiceStatusProvider);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    // 排程工作只有 Windows 有：其他機器上這一列**整個不畫**，不是變灰
    // （同分頁本身的規則——一個永遠按不動的入口比沒有更糟）
    if (!ref.watch(kitInstallSupportedProvider)) return const SizedBox.shrink();

    final status = ref.watch(runnerServiceStatusProvider).value;
    final state = status?.state ?? RunnerServiceState.unknown;
    final running = state == RunnerServiceState.running;
    // 查狀態自己失敗的那一句也要看得到——否則「狀態不明」會被當成
    // 「這台沒裝排程工作」，而它可能只是 PowerShell 叫不起來
    final detail = _failure.isNotEmpty ? _failure : (status?.detail ?? '');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.hostRunnerServiceTitle,
            style: UepText.fieldLabel(color: s.inkMute)),
        const SizedBox(height: 10),
        Row(children: [
          SizedBox(
            width: kValueRowLabelWidth,
            child: Row(children: [
              Icon(_icon(state), size: 15, color: _color(state)),
              const SizedBox(width: 8),
              Text(_label(l10n, state),
                  style: UepText.serif(size: 13.5, color: s.ink)),
            ]),
          ),
          const SizedBox(width: 18),
          UepButton(
            small: true,
            variant: running
                ? UepButtonVariant.outline
                : UepButtonVariant.gold,
            label: _busy
                ? (running
                    ? l10n.hostRunnerServiceStopping
                    : l10n.hostRunnerServiceStarting)
                : (running
                    ? l10n.hostRunnerServiceStopButton
                    : l10n.hostRunnerServiceStartButton),
            onPressed: _busy ? null : () => running ? _stop() : _start(),
          ),
        ]),
        if (detail.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(l10n.hostRunnerServiceFailed(detail),
              style: UepText.serif(size: 12.5, color: UepColors.errorText)),
        ],
      ],
    );
  }

  IconData _icon(RunnerServiceState state) => switch (state) {
        RunnerServiceState.running => Icons.play_circle_outline,
        RunnerServiceState.stopped => Icons.stop_circle_outlined,
        RunnerServiceState.disabled => Icons.block,
        RunnerServiceState.unknown => Icons.help_outline,
      };

  Color _color(RunnerServiceState state) => switch (state) {
        RunnerServiceState.running => UepColors.success,
        RunnerServiceState.disabled => UepColors.error,
        _ => context.uep.inkMute,
      };

  String _label(AppLocalizations l10n, RunnerServiceState state) =>
      switch (state) {
        RunnerServiceState.running => l10n.hostRunnerServiceRunning,
        RunnerServiceState.stopped => l10n.hostRunnerServiceStopped,
        RunnerServiceState.disabled => l10n.hostRunnerServiceDisabled,
        RunnerServiceState.unknown => l10n.hostRunnerServiceUnknown,
      };

  /// 停止前先問，而**問的內容取決於它手上還有沒有 run**：
  /// 那幾筆會被砍掉並在 Hub 上標成失敗，那是這個操作唯一不可逆的後果。
  Future<void> _stop() async {
    final l10n = AppLocalizations.of(context);
    ref.invalidate(runnerActiveRunCountProvider);
    final active = await ref.read(runnerActiveRunCountProvider.future);
    if (!mounted) return;
    final go = await _confirm(
      title: l10n.hostRunnerServiceStopButton,
      body: active > 0
          ? l10n.hostRunnerServiceStopBusyBody(active)
          : l10n.hostRunnerServiceStopBody,
      confirmLabel: l10n.hostRunnerServiceStopButton,
      danger: active > 0,
    );
    if (go != true) return;
    await _run((c) => c.stop());
  }

  Future<void> _start() => _run((c) => c.start());

  Future<void> _run(
      Future<String?> Function(RunnerServiceController) action) async {
    setState(() {
      _busy = true;
      _failure = '';
    });
    String? failure;
    try {
      final controller = await ref.read(runnerServiceControllerProvider.future);
      failure = await action(controller);
    } on Object catch (e) {
      failure = '$e';
    } finally {
      // 做完一定重讀：畫面上那個字是操作結果的唯一證據
      ref.invalidate(runnerServiceStatusProvider);
      ref.invalidate(runnerActiveRunCountProvider);
      if (mounted) {
        setState(() {
          _busy = false;
          _failure = failure ?? '';
        });
      }
    }
  }

  Future<bool?> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
    required bool danger,
  }) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: s.bgCard,
        title: Text(title,
            style: UepText.serif(
                size: 15, weight: FontWeight.w600, color: s.inkTitle)),
        content: Text(body,
            style: UepText.serif(size: 14, color: s.ink, height: 1.7)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel,
                style: UepText.serif(size: 14, color: s.inkMute)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              confirmLabel,
              style: UepText.serif(
                  size: 14,
                  color: danger ? UepColors.errorText : UepColors.gold),
            ),
          ),
        ],
      ),
    );
  }
}
