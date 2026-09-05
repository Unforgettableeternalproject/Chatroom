/// 想法板段落標籤的顯示規則。
///
/// 標籤的**值**是跨端一致的識別字（Hub 存的就是這個），顯示出來的字才是
/// 繁中——兩者分開是刻意的：把「bug」直接畫在畫面上，下一個人就會開始用
/// 「錯誤」當自訂標籤，而那兩個是同一件事，分堆會慢慢失效。
///
/// ⚠️ **這裡只管怎麼畫，不管有哪些。** 有哪些一律來自 Hub 的 `allowed_tags`
/// （預設 ∪ 板自訂），UI 不留第二份清單。
library;

import 'package:flutter/material.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';

/// 預設集合的繁中顯示名。**不在這份表裡的是板自訂標籤，原樣顯示**——
/// 那是使用者自己取的名字，翻譯它只會讓他認不出來。
const _defaultTagLabels = {
  'bug': 'Bug',
  'feature': '新功能',
  'design': '設計',
  'question': '疑問',
};

String tagLabel(String tag) => _defaultTagLabels[tag] ?? tag;

/// 標籤的顏色。預設集合各有一個固定色，自訂標籤走中性色——
/// 自訂的可以有無限多個，硬要給每個一個顏色只會撞在一起。
Color tagColor(String tag) => switch (tag) {
      'bug' => UepColors.error,
      'feature' => UepColors.gold,
      'design' => const Color(0xFF5A98CC),
      'question' => const Color(0xFFD98A3A),
      _ => const Color(0xFF7A8290),
    };

/// 一顆標籤徽章。
///
/// [onPick] 給了才可以改；`null` 時它只是一個顯示——**唯讀的人不該看到一個
/// 按下去沒反應的東西**。
///
/// [allowed] 空的時候整顆不畫（舊 Hub 沒有這個功能），呼叫端不必自己判斷。
class ScratchpadTagChip extends StatelessWidget {
  const ScratchpadTagChip({
    super.key,
    required this.tag,
    this.allowed = const [],
    this.onPick,
  });

  /// 現在標的那一個。`null` = 沒標。
  final String? tag;

  final List<String> allowed;

  /// 選了新的標籤（或選「不標」時給 `null`）。
  final ValueChanged<String?>? onPick;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    // 沒有選單可用、自己也沒標籤 ⇒ 這塊板沒有這個功能，什麼都不要畫
    if (allowed.isEmpty && tag == null) return const SizedBox.shrink();

    final chip = _chip(s);
    if (onPick == null || allowed.isEmpty) return chip;

    return PopupMenuButton<String>(
      tooltip: '標籤',
      position: PopupMenuPosition.under,
      // 「不標」與「標成別的」是同一個選單裡的兩個選項——分成兩個入口的話，
      // 取消標籤會變成一個要先找到才做得到的動作
      onSelected: (v) => onPick!(v.isEmpty ? null : v),
      itemBuilder: (_) => [
        for (final t in allowed)
          PopupMenuItem(
            value: t,
            child: Row(children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                    color: tagColor(t), shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(tagLabel(t), style: UepText.sans(size: 12, color: s.ink)),
            ]),
          ),
        if (tag != null) ...[
          const PopupMenuDivider(),
          PopupMenuItem(
            value: '',
            child: Text('不標',
                style: UepText.sans(size: 12, color: s.inkMute)),
          ),
        ],
      ],
      child: chip,
    );
  }

  Widget _chip(UepSurface s) {
    final t = tag;
    if (t == null) {
      // 還沒標的時候要看得出「這裡可以標」，但不能搶走段落本身的注意力
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: s.line),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text('＋標籤',
            style: UepText.mono(size: 8.5, letterSpacing: 1.0,
                color: s.inkMute)),
      );
    }
    final c = tagColor(t);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: .13),
        border: Border.all(color: c.withValues(alpha: .5)),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(tagLabel(t),
          style: UepText.mono(size: 8.5, letterSpacing: 1.0, color: c)),
    );
  }
}
