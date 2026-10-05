import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/l10n.dart';
import '../../state/runner_kit_providers.dart';
import '../../widgets/uep_button.dart';
import 'host_value_row.dart';

/// 執行器裝好之後那一列：**claude 登入了沒**。
///
/// 這件事不能放進安裝前的前置條件——登入是裝完才做得到的（要先有執行器的
/// `CLAUDE_CONFIG_DIR`）。但它與「裝好了沒」一樣會讓執行器整個不能動，
/// 所以要有自己的一列，而不是等第一筆單炸了才知道。
///
/// 底下另有長效 token：OAuth 常過期的機器改用 `claude setup-token` 產生的
/// token。🔴 token **只寫進檔案**，畫面只說有沒有設定，不回顯、不進 log。
class RunnerLoginRow extends ConsumerStatefulWidget {
  const RunnerLoginRow({super.key});

  @override
  ConsumerState<RunnerLoginRow> createState() => _RunnerLoginRowState();
}

class _RunnerLoginRowState extends ConsumerState<RunnerLoginRow> {
  final _token = TextEditingController();
  bool _busy = false;
  String? _tokenError;

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  /// 重新判斷。`mcp list` 的過期旗標也會壓住登入狀態，要一起重讀。
  void _recheck() {
    ref.invalidate(machineMcpServersProvider);
    ref.invalidate(runnerClaudeLoginProvider);
  }

  /// 開新終端視窗跑 claude，視窗關掉後重新判斷。
  Future<void> _launch(String configDir, List<String> claudeArgs) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final launch = ref.read(claudeTerminalLauncherProvider);
    setState(() => _busy = true);
    try {
      await launch(configDir, claudeArgs);
    } on Object catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text(l10n.hostRunnerTerminalFailed('$e'))));
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _recheck();
  }

  Future<void> _saveToken({required bool clear}) async {
    final l10n = AppLocalizations.of(context);
    final cfg = ref.read(runnerConfigProvider).value;
    final file = cfg == null ? null : runnerOAuthTokenFileFor(cfg);
    if (file == null) return;
    setState(() => _tokenError = null);
    try {
      if (clear) {
        await clearRunnerOAuthToken(file);
      } else {
        await writeRunnerOAuthToken(file, _token.text);
      }
    } on FormatException {
      if (mounted) setState(() => _tokenError = l10n.hostRunnerTokenInvalid);
      return;
    } on FileSystemException catch (e) {
      // 只放例外的說明（路徑與系統錯誤），不放 token
      final why = e.osError?.message ?? e.message;
      if (mounted) {
        setState(() => _tokenError = l10n.hostRunnerTokenSaveFailed(why));
      }
      return;
    }
    if (!mounted) return;
    _token.clear();
    _recheck();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final login = ref.watch(runnerClaudeLoginProvider).value;
    // 推不出設定目錄就整列不畫——對著一個猜出來的路徑說「尚未登入」，
    // 人照著那行指令去登也登不到執行器會讀的地方
    if (login == null) return const SizedBox.shrink();

    final status = login.loggedIn
        ? l10n.hostRunnerLoginOk
        : login.expired
            ? l10n.hostRunnerLoginExpired
            : l10n.hostRunnerLoginMissing;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.hostRunnerLoginTitle,
            style: UepText.fieldLabel(color: s.inkMute)),
        const SizedBox(height: 10),
        Row(children: [
          Icon(login.loggedIn ? Icons.check : Icons.close,
              size: 15,
              color: login.loggedIn ? UepColors.success : UepColors.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(status, style: UepText.serif(size: 13.5, color: s.ink)),
          ),
          if (!login.loggedIn) ...[
            UepButton(
              label: l10n.hostRunnerLoginAction,
              small: true,
              onPressed: _busy
                  ? null
                  : () => _launch(login.configDir, const ['auth', 'login']),
            ),
            const SizedBox(width: 4),
          ],
          IconButton(
            tooltip: l10n.hostRunnerLoginRecheck,
            onPressed: _busy ? null : _recheck,
            icon: Icon(Icons.refresh, size: 18, color: s.inkMute),
          ),
        ]),
        if (!login.loggedIn) ...[
          const SizedBox(height: 8),
          Text(l10n.hostRunnerLoginHint,
              style: UepText.serif(size: 13, color: s.inkSoft)),
          const SizedBox(height: 6),
          CopyRow(
              label: l10n.hostRunnerLoginCommand, value: login.loginCommand),
        ],
        const SizedBox(height: 16),
        Row(children: [
          Text(l10n.hostRunnerTokenLabel,
              style: UepText.fieldLabel(color: s.inkMute)),
          const SizedBox(width: 10),
          Icon(login.tokenSet ? Icons.check : Icons.remove,
              size: 14,
              color: login.tokenSet ? UepColors.success : s.inkMute),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              login.tokenSet ? l10n.hostRunnerTokenSet : l10n.hostRunnerTokenUnset,
              style: UepText.serif(size: 13, color: s.ink),
            ),
          ),
          UepButton(
            label: l10n.hostRunnerTokenGenerate,
            small: true,
            variant: UepButtonVariant.outline,
            onPressed: _busy
                ? null
                : () => _launch(login.configDir, const ['setup-token']),
          ),
          if (login.tokenSet) ...[
            const SizedBox(width: 8),
            UepButton(
              label: l10n.hostRunnerTokenClear,
              small: true,
              variant: UepButtonVariant.danger,
              onPressed: () => _saveToken(clear: true),
            ),
          ],
        ]),
        const SizedBox(height: 6),
        Text(l10n.hostRunnerTokenNote,
            style: UepText.serif(size: 13, color: s.inkSoft)),
        const SizedBox(height: 8),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: EditRow(
              // 標題列已經寫了是什麼；這裡只留對齊用的標籤欄
              label: '',
              controller: _token,
              fieldKey: const ValueKey('runner-oauth-token'),
              hint: l10n.hostRunnerTokenHint,
              // 不給眼睛：貼進來的東西一律不回顯
              obscure: true,
              trailingSlots: 0,
              errorText: _tokenError,
            ),
          ),
          const SizedBox(width: 8),
          UepButton(
            label: l10n.commonSave,
            small: true,
            onPressed: () => _saveToken(clear: false),
          ),
        ]),
      ],
    );
  }
}
