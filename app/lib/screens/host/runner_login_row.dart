import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/l10n.dart';
import '../../state/runner_kit_providers.dart';
import 'host_value_row.dart';

/// 執行器裝好之後那一列：**claude 登入了沒**。
///
/// 這件事不能放進安裝前的前置條件——登入是裝完才做得到的（要先有執行器的
/// `CLAUDE_CONFIG_DIR`）。但它與「裝好了沒」一樣會讓執行器整個不能動，
/// 所以要有自己的一列，而不是等第一筆單炸了才知道。
class RunnerLoginRow extends ConsumerWidget {
  const RunnerLoginRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final login = ref.watch(runnerClaudeLoginProvider).value;
    // 推不出設定目錄就整列不畫——對著一個猜出來的路徑說「尚未登入」，
    // 人照著那行指令去登也登不到執行器會讀的地方
    if (login == null) return const SizedBox.shrink();

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
          Text(
            login.loggedIn ? l10n.hostRunnerLoginOk : l10n.hostRunnerLoginMissing,
            style: UepText.serif(size: 13.5, color: s.ink),
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
      ],
    );
  }
}
