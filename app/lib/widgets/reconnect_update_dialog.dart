import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../l10n/l10n.dart';
import '../screens/settings/app_update_row.dart';
import '../state/app_updater.dart';
import '../state/kit_installer.dart';
import '../state/reconnect_update.dart';
import 'uep_button.dart';

/// 重連後的更新提示：問一次，選「更新」才動手，選「稍後」這次執行期間
/// 不再問同一個版本。
Future<void> askReconnectUpdate(
  BuildContext context,
  WidgetRef ref,
  ReconnectUpdatePrompt prompt,
) async {
  final notifier = ref.read(reconnectUpdateProvider.notifier);
  final yes = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final s = ctx.uep;
      final l10n = AppLocalizations.of(ctx);
      return AlertDialog(
        backgroundColor: s.bgCard,
        content: SizedBox(
          width: 380,
          child: Text(
            prompt.kind == ReconnectUpdateKind.app
                ? l10n.reconnectUpdateAppBody(prompt.tag)
                : prompt.unconfirmed
                    ? '${l10n.reconnectUpdateHubBody(prompt.tag)}'
                        '\n${l10n.hubRunsUnconfirmed}'
                    : l10n.reconnectUpdateHubBody(prompt.tag),
            style: UepText.serif(size: 14.5, color: s.inkSoft, height: 1.7),
          ),
        ),
        actions: [
          UepButton(
            label: l10n.commonLater,
            variant: UepButtonVariant.outline,
            small: true,
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
          UepButton(
            label: l10n.reconnectUpdateAction,
            small: true,
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
      );
    },
  );
  if (yes != true) {
    notifier.decline();
    return;
  }
  if (!context.mounted) return;
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(SnackBar(
    content: Text(prompt.kind == ReconnectUpdateKind.app
        ? l10n.reconnectUpdateAppDownloading(prompt.tag)
        : l10n.reconnectUpdateHubRunning(prompt.tag)),
  ));
  final ok = await notifier.accept();
  if (ok) return;
  final String message;
  if (prompt.kind == ReconnectUpdateKind.app) {
    message = appUpdateFailureText(l10n, ref.read(appUpdateProvider).failure);
  } else {
    final st = ref.read(kitInstallsProvider)[KitId.hub];
    message = st?.failure == KitInstallFailure.hubBusy
        ? l10n.hubRunsBusy(st!.detail)
        : l10n.hostKitInstallFailed(st?.detail ?? '');
  }
  messenger.showSnackBar(SnackBar(content: Text(message)));
}
