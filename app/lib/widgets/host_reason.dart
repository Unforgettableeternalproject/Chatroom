import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/host_reason.dart';
import '../core/theme/uep_tokens.dart';
import '../core/theme/uep_theme.dart';
import '../l10n/l10n.dart';
import '../state/app_providers.dart';
import 'uep_button.dart';

/// 主持人操作確認框裡的選填「理由」欄。
///
/// 只在主持人模式開啟時才該畫出來（呼叫端用 [isHostViewOn] 判斷）；欄位本身
/// 不替呼叫端決定。文字由呼叫端持有的 [controller] 讀回。
class HostReasonField extends StatelessWidget {
  const HostReasonField({super.key, required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    return Container(
      decoration: BoxDecoration(
        color: s.bgSunken,
        border: Border.all(color: s.lineStrong),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: TextField(
        key: const Key('hostReasonField'),
        controller: controller,
        maxLines: 2,
        minLines: 1,
        maxLength: 500,
        style: UepText.sans(size: 13.5, color: s.ink),
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          counterText: '',
          labelText: l10n.hostReasonLabel,
          labelStyle: UepText.sans(size: 12.5, color: s.inkMute),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
        ),
      ),
    );
  }
}

/// 目前是不是主持人模式（確認框要不要多一欄理由）。
bool isHostViewOn(BuildContext context) =>
    ProviderScope.containerOf(context, listen: false).read(hostViewProvider);

/// 沒有既有確認框的主持人操作：主持人模式下彈一個只有理由欄的小框。
///
/// 回傳理由（沒填是空字串）；取消回 null。**非主持人模式不彈框、直接回空字串**
/// ——既有流程完全不變。
Future<String?> askHostReason(
  BuildContext context, {
  required String title,
  String? body,
  String? confirmLabel,
}) async {
  if (!isHostViewOn(context)) return '';
  // 不 dispose：showDialog 的 Future 在關閉動畫結束前就完成，此時 TextField
  // 還在用它；沒有 listener 的 controller 交給 GC 即可
  final ctl = TextEditingController();
  {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        final s = context.uep;
        final l10n = AppLocalizations.of(context);
        return AlertDialog(
          title: Text(title, style: UepText.pageTitle(color: s.inkTitle)),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (body != null && body.isNotEmpty) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(body,
                      style: UepText.serif(
                          size: 14, color: s.inkSoft, height: 1.6)),
                ),
                const SizedBox(height: 12),
              ],
              HostReasonField(controller: ctl),
            ]),
          ),
          actions: [
            UepButton(
              label: l10n.commonCancel,
              variant: UepButtonVariant.outline,
              small: true,
              onPressed: () => Navigator.of(context).pop(false),
            ),
            UepButton(
              label: confirmLabel ?? l10n.hostReasonConfirm,
              small: true,
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        );
      },
    );
    return ok == true ? ctl.text.trim() : null;
  }
}

/// [askHostReason] 之後把 [body] 放進帶理由的 Zone 執行。取消回 null。
Future<T?> withAskedHostReason<T>(
  BuildContext context, {
  required String title,
  String? body,
  String? confirmLabel,
  required Future<T> Function() run,
}) async {
  final reason =
      await askHostReason(context, title: title, body: body, confirmLabel: confirmLabel);
  if (reason == null) return null;
  return runWithHostReason(reason, run);
}
