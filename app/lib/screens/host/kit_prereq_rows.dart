import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/l10n.dart';
import '../../state/kit_prereq.dart';
import '../../state/kit_installer.dart';

/// 安裝按鈕上方那幾列「這台機器準備好了沒」。
///
/// 每一列只講三件事：**名稱、過了沒、一句原因**。沒有原因的 ✕ 與一顆灰掉
/// 的按鈕是同一種東西——人看得到不能裝，但不知道要去修什麼。
class KitPrereqRows extends ConsumerWidget {
  const KitPrereqRows({super.key, required this.kit});

  final KitId kit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final prereqs = ref.watch(kitPrereqsProvider(kit));
    final rows = prereqs.value;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Text(l10n.hostKitPrereqTitle,
              style: UepText.fieldLabel(color: s.inkMute)),
          const Spacer(),
          IconButton(
            tooltip: l10n.hostKitPrereqRecheck,
            icon: Icon(Icons.refresh, size: 16, color: s.inkMute),
            onPressed: () => recheckKitPrereqs(ref),
          ),
        ]),
        if (rows == null)
          Text(l10n.hostKitPrereqChecking,
              style: UepText.serif(size: 13, color: s.inkSoft))
        else
          for (final row in rows) ...[
            _PrereqRow(prereq: row),
            const SizedBox(height: 4),
          ],
      ],
    );
  }
}

class _PrereqRow extends StatelessWidget {
  const _PrereqRow({required this.prereq});

  final KitPrereq prereq;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(prereq.ok ? Icons.check : Icons.close,
          size: 15, color: prereq.ok ? UepColors.success : UepColors.error),
      const SizedBox(width: 8),
      Text(_name(l10n, prereq.kind),
          style: UepText.serif(size: 13.5, color: s.ink)),
      const SizedBox(width: 10),
      Flexible(
        child: Text(_reason(l10n, prereq),
            style: UepText.serif(size: 13, color: s.inkSoft)),
      ),
    ]);
  }

  static String _name(AppLocalizations l10n, KitPrereqKind kind) =>
      switch (kind) {
        KitPrereqKind.python => l10n.hostKitPrereqPython,
        KitPrereqKind.agentCli => l10n.hostKitPrereqAgentCli,
        KitPrereqKind.claudeCli => l10n.hostKitPrereqClaudeCli,
        KitPrereqKind.hub => l10n.hostKitPrereqHub,
      };

  /// 一句原因。過了也要講——講出**找到的是哪一個**，那是人唯一能核對
  /// 「它找到的與我裝的是同一份嗎」的地方。
  static String _reason(AppLocalizations l10n, KitPrereq prereq) {
    if (prereq.ok) {
      return switch (prereq.kind) {
        KitPrereqKind.hub => l10n.hostKitPrereqHubOk(prereq.detail),
        _ => l10n.hostKitPrereqFound(prereq.detail),
      };
    }
    return switch (prereq.issue!) {
      KitPrereqIssue.missing => switch (prereq.kind) {
          KitPrereqKind.python => l10n.hostKitPrereqPythonMissing,
          KitPrereqKind.agentCli => l10n.hostKitPrereqAgentCliMissing,
          _ => l10n.hostKitPrereqClaudeCliMissing,
        },
      KitPrereqIssue.hubUnset => l10n.hostKitPrereqHubUnset,
      KitPrereqIssue.hubUnreachable =>
        l10n.hostKitPrereqHubUnreachable(prereq.detail),
    };
  }
}
