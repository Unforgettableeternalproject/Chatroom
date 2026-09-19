import 'package:flutter/material.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../core/util/relative_time.dart';
import '../l10n/l10n.dart';
import '../models/message.dart';
import 'kind_badge.dart';
import 'markdown_body.dart';

/// 這則 system 訊息是不是「一段內容」而不是「一行通知」。
///
/// run 的收工摘要走 system 訊息進房（REMOTE-OPS-PLAN §12 待辦 2），而它是
/// 一整段 Markdown。塞進髮絲線中間那行置中 mono 小字裡，字小、標題不渲染，
/// 換行後每一行的縮排還會把內容推出訊息框——**看得到但讀不了**。
///
/// 門檻刻意寬鬆：誤判成區塊的代價是一行通知變大一點，誤判成一行的代價是
/// 一份報告讀不到。
bool systemMessageNeedsBlock(String content) =>
    content.contains('\n') || content.contains('###') || content.length > 200;

/// system 訊息：兩側髮絲線 + mono 小字（設計稿樣式），
/// 與一般發言視覺明顯不同（P3-06 條件 3）。
///
/// 「收據」是例外——提問的答案與釘選通知帶著**內容**，塞進髮絲線中間的
/// 一行小字會被截斷成沒有用的東西。那類走 [_ReceiptTile]。
///
/// 帶著整段 Markdown 的（run 的收工摘要）走 [_BlockTile]，判定見
/// [systemMessageNeedsBlock]。
class SystemMessageTile extends StatelessWidget {
  const SystemMessageTile({super.key, required this.message});

  final Message message;

  @override
  Widget build(BuildContext context) {
    if (message.isReceipt) return _ReceiptTile(message: message);
    if (systemMessageNeedsBlock(message.content)) {
      return _BlockTile(message: message);
    }
    final s = context.uep;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(child: Container(height: 1, color: s.hairline)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            '${message.content} · ${clockTime(message.createdAt)}',
            style: UepText.mono(size: 10, color: s.inkMute, letterSpacing: 1.4),
            textAlign: TextAlign.center,
          ),
        ),
        Expanded(child: Container(height: 1, color: s.hairline)),
      ]),
    );
  }
}

/// 收據：房內留下的一筆「這件事有結論了」。
///
/// 置中的小卡，不是氣泡——它不屬於任何人的發言，但也不是可以一眼掠過的
/// 系統噪音。提問的答案尤其：那是一個已經拍板的決定，房內其他 agent 照著
/// 做就對了，所以答案全文完整顯示，不截斷。
class _ReceiptTile extends StatelessWidget {
  const _ReceiptTile({required this.message});

  final Message message;

  /// 事件 → (標籤, 顏色)。未知事件不會走到這裡（isReceipt 已經過濾），
  /// 但仍給一個中性的預設，免得日後新增事件時整塊消失。
  (String, Color) _badge(AppLocalizations l10n) =>
      switch (message.systemEvent) {
        'question_answered' => (l10n.msgReceiptAnswered, UepColors.success),
        'question_skipped' => (l10n.msgReceiptSkipped, UepColors.info),
        'pin' => (l10n.msgReceiptPinned, UepColors.gold),
        // 要人去處理的，不是已經有結論的——用 error 軸與收據區分開
        'board_supervisor_left_runs' => (
            l10n.boardSupervisorLeftRunsBadge,
            UepColors.error
          ),
        _ => (l10n.msgReceiptRecord, UepColors.info),
      };

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final (label, color) = _badge(AppLocalizations.of(context));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Align(
        alignment: Alignment.center,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
            decoration: BoxDecoration(
              color: color.withValues(alpha: .05),
              border: Border.all(color: color.withValues(alpha: .24)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      border: Border.all(color: color.withValues(alpha: .5)),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(label,
                        style: UepText.mono(
                            size: 10, color: color, letterSpacing: 1.2)),
                  ),
                  const SizedBox(width: 8),
                  Text(clockTime(message.createdAt),
                      style: UepText.mono(size: 10, color: s.inkMute)),
                ]),
                const SizedBox(height: 6),
                Text(
                  message.content,
                  style: UepText.serif(
                      size: 13.5, color: s.inkSoft, height: 1.55),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 帶內容的 system 訊息（run 的收工摘要是主要來源）。
///
/// 靠左、正常字級、Markdown 渲染——它是要被讀完的東西，不是掃過去的噪音。
/// 寬度完全交給父層：內部沒有任何 `IntrinsicWidth`／固定寬，長的路徑與
/// code block 由 [UepMarkdownBody] 自己換行或在自己的框內水平捲動，不會把
/// 訊息框撐破（§12 待辦 2 的實機症狀就是被撐出右緣）。
class _BlockTile extends StatelessWidget {
  const _BlockTile({required this.message});

  final Message message;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: s.bgSunken,
          border: Border.all(color: s.line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              MonoLabel(AppLocalizations.of(context).commonSystem,
                  size: 8.5, letterSpacing: 2.2),
              const SizedBox(width: 8),
              Text(clockTime(message.createdAt),
                  style: UepText.mono(size: 10, color: s.inkMute)),
            ]),
            const SizedBox(height: 8),
            UepMarkdownBody(data: message.content, baseColor: s.inkSoft),
          ],
        ),
      ),
    );
  }
}
