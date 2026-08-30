import 'package:flutter/material.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../core/util/relative_time.dart';
import '../models/message.dart';

/// system 訊息：兩側髮絲線 + mono 小字（設計稿樣式），
/// 與一般發言視覺明顯不同（P3-06 條件 3）。
///
/// 「收據」是例外——提問的答案與釘選通知帶著**內容**，塞進髮絲線中間的
/// 一行小字會被截斷成沒有用的東西。那類走 [_ReceiptTile]。
class SystemMessageTile extends StatelessWidget {
  const SystemMessageTile({super.key, required this.message});

  final Message message;

  @override
  Widget build(BuildContext context) {
    if (message.isReceipt) return _ReceiptTile(message: message);
    final s = context.uep;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(child: Container(height: 1, color: s.hairline)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            '${message.content} · ${clockTime(message.createdAt)}',
            style: UepText.mono(size: 9, color: s.inkMute, letterSpacing: 1.4),
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
  (String, Color) _badge() => switch (message.systemEvent) {
        'question_answered' => ('已回答', UepColors.success),
        'question_skipped' => ('未在此回答', UepColors.info),
        'pin' => ('已釘選', UepColors.gold),
        _ => ('紀錄', UepColors.info),
      };

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final (label, color) = _badge();
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
                            size: 9, color: color, letterSpacing: 1.2)),
                  ),
                  const SizedBox(width: 8),
                  Text(clockTime(message.createdAt),
                      style: UepText.mono(size: 9, color: s.inkMute)),
                ]),
                const SizedBox(height: 6),
                Text(
                  message.content,
                  style: UepText.serif(
                      size: 12.5, color: s.inkSoft, height: 1.55),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
