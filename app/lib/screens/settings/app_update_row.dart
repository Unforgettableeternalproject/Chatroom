import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/l10n.dart';
import '../../state/app_updater.dart';
import '../../widgets/uep_button.dart';

/// 設定頁「App 版本」底下的檢查更新列。
///
/// dev build、dirty build 與非 Windows 不顯示——那些 App 對不回任何一份
/// Release，按了也沒有東西可比。
class AppUpdateRow extends ConsumerWidget {
  const AppUpdateRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(appUpdateEnabledProvider)) return const SizedBox.shrink();
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(appUpdateProvider);
    final notifier = ref.read(appUpdateProvider.notifier);

    final (label, action) = switch (state.phase) {
      AppUpdatePhase.available ||
      AppUpdatePhase.downloading =>
        (l10n.settingsUpdateDownload, notifier.download),
      AppUpdatePhase.ready ||
      AppUpdatePhase.applying =>
        (l10n.settingsUpdateRestart, notifier.restart),
      _ => (l10n.settingsUpdateCheck, notifier.check),
    };
    final text = switch (state.phase) {
      AppUpdatePhase.upToDate => l10n.settingsUpdateUpToDate,
      AppUpdatePhase.available => l10n.settingsUpdateAvailable(state.tag),
      AppUpdatePhase.checkFailed => l10n.settingsUpdateCheckFailed,
      AppUpdatePhase.downloading => l10n
          .settingsUpdateDownloading('${(state.progress * 100).round()}'),
      AppUpdatePhase.ready => l10n.settingsUpdateReady(state.tag),
      AppUpdatePhase.failed => _failureText(l10n, state.failure),
      _ => '',
    };
    final failed = state.phase == AppUpdatePhase.failed ||
        state.phase == AppUpdatePhase.checkFailed;
    final spinning = state.phase == AppUpdatePhase.checking ||
        state.phase == AppUpdatePhase.applying;

    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Row(children: [
        UepButton(
          label: label,
          small: true,
          variant: UepButtonVariant.outline,
          onPressed: state.busy ? null : action,
        ),
        const SizedBox(width: 14),
        if (spinning)
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: UepColors.gold),
          )
        else if (text.isNotEmpty)
          Expanded(
            child: Text(text,
                style: UepText.serif(
                    size: 13,
                    color: failed ? UepColors.errorText : s.inkSoft,
                    height: 1.5)),
          ),
      ]),
    );
  }

  String _failureText(AppLocalizations l10n, AppUpdateFailure? failure) =>
      switch (failure) {
        AppUpdateFailure.notWritable => l10n.settingsUpdateFailNotWritable,
        AppUpdateFailure.sizeMismatch ||
        AppUpdateFailure.digestMismatch ||
        AppUpdateFailure.incomplete =>
          l10n.settingsUpdateFailVerify,
        AppUpdateFailure.extract => l10n.settingsUpdateFailExtract,
        AppUpdateFailure.launch => l10n.settingsUpdateFailLaunch,
        AppUpdateFailure.download || null => l10n.settingsUpdateFailDownload,
      };
}
