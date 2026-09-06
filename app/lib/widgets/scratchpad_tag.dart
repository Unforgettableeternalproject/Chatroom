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

/// 哪些標籤刪得掉：**`allowed` 減掉預設集合**，而預設集合是
/// `allowed - custom` 推出來的，不是 UI 這邊列的。
///
/// [custom] 為 `null` 表示 Hub 沒說（舊版不回 `custom_tags`）。那時**全部
/// 都當可刪**，由 Hub 用 422 `tag_is_default` 擋——鎖錯比多一次拒絕貴：
/// 猜錯而把某塊板真的自訂的標籤鎖起來，那個標籤就永遠刪不掉了。
List<String> removableTags({
  required List<String> allowed,
  required List<String>? custom,
}) {
  if (custom == null) return allowed;
  final c = custom.toSet();
  return [
    for (final t in allowed)
      if (c.contains(t)) t,
  ];
}

// 這裡曾經有一支 `conflictTags()`：衝突重試時把 409 帶回來的現值撈出來
// 重送，因為當時 tags 是整份覆寫語意，不送等於清空（2026-09-05 真的丟過
// 一次資料——兩端各自的測試都不會紅，要有人讓兩端交錯才看得見）。
//
// 🔴 **tags 改走 containsKey 之後（09/06 `dfb98c7b`），那支函式連存在的
// 理由都沒有了**：不送就是不動，對方剛改的自然留著。
//
// 📌 留著它作為紀錄，是因為這個對比值得下一個人看到——**需要一個 conflict
// helper 這件事本身，就是整份覆寫語意的成本**。同一段路，state 從第一天就
// 走 containsKey，所以從來不需要那支函式。

/// 刪不掉一個標籤時要對人說的那句話。
///
/// **抽成頂層函式是為了測得到**（同 `padRoute()`）：這幾句是這個對話框裡
/// 唯一有判斷的東西，埋在 State 裡等於沒有守著。
///
/// 🔴 `tag_in_use` 一定要講出**幾則**。Hub 特地在 409 裡附上 `block_ids`
/// 就是為了這個——擋下來而已是把問題換個地方放，使用者會反覆按同一顆刪除
/// 鈕，因為畫面沒告訴他該先去改什麼。
String tagRemovalError(String code, String tag,
    {int blockCount = 0, String fallback = ''}) =>
    switch (code) {
      'tag_in_use' => '還有 $blockCount 則段落標著「${tagLabel(tag)}」，'
          '先把它們改成別的標籤才刪得掉。',
      'tag_is_default' => '「${tagLabel(tag)}」是預設標籤，每塊板都有，刪不掉。',
      _ => fallback,
    };

// 這裡曾經有一支 `tagLockedReason()`：當 `state` 已放寬而 `tags` 還限作者
// 時，那顆點不動的標籤 chip 要說得出為什麼——兩顆同形、並排、一樣大的
// chip，一顆點得動一顆點不動，不說的話那看起來就是壞了。
//
// 🔴 **同一天晚上 tags 也放寬了（`c2cd3c22`），那個不對稱消失，函式恆回
// 空字串。** 它從 `9cd469e` 到 `afb240c`，存在了 2 小時 8 分。
//
// （那個數字是讀 commit 時間戳得到的。第一版註解寫「大約一小時」——憑感覺
// 寫的，少了一倍。agent 沒有可靠的時間感，凡是結論依賴經過時間就去讀時間
// 戳，包括這種看起來只是修辭的。）
//
// 📌 留這段紀錄不是為了懷念，是因為**它被刪掉的理由與它被寫出來的理由是
// 同一件事**：畫面上兩個並排的東西行為不同時，差別必須說得出口；行為一樣
// 了，那句解釋就成了描述一個不存在的差異，比不說更糟。

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

/// 段落狀態的繁中顯示名。
String blockStateLabel(String state) => switch (state) {
      'implemented' => '已實作',
      'abandoned' => '已放棄',
      _ => state,
    };

/// 段落狀態的顏色。
///
/// 「已放棄」刻意走中性灰而不是紅：放棄是一個**正常的結局**，不是錯誤。
/// 畫成紅的話，一份健康的想法板看起來會像出了一堆事。
Color blockStateColor(String state) => switch (state) {
      'implemented' => UepColors.gold,
      'abandoned' => const Color(0xFF7A8290),
      _ => const Color(0xFF7A8290),
    };

/// 一顆段落狀態徽章：這則觀察後來怎麼了。
///
/// 與 [ScratchpadTagChip] 是**正交的兩個軸**（標籤講性質、這裡講結局），
/// 所以並排而不是二選一。
///
/// 🔴 **沒標時不畫實心徽章。** 三態裡「還沒標」是常態，把它畫成一個有顏色
/// 的東西，等於宣告一件沒有人決定過的事——沒標與已放棄在畫面上必須分得開。
/// 可以改的時候給一個安靜的「＋狀態」入口，唯讀時整顆不畫。
class ScratchpadStateChip extends StatelessWidget {
  const ScratchpadStateChip({super.key, required this.state, this.onPick});

  /// 現在的狀態。`null` = 還沒標。
  final String? state;

  /// 選了新狀態（或選「清除標記」時給 `null`）。`null` = 不能改。
  final ValueChanged<String?>? onPick;

  static const _choices = ['implemented', 'abandoned'];

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final st = state;
    // 唯讀又沒標 ⇒ 這裡沒有任何事可講，不要留一個空殼
    if (onPick == null && st == null) return const SizedBox.shrink();

    final chip = _chip(s);
    if (onPick == null) return chip;

    return PopupMenuButton<String>(
      tooltip: '這則後來怎麼了',
      position: PopupMenuPosition.under,
      // 「清除標記」與「改成別的」在同一個選單裡——分成兩個入口的話，
      // 標錯了要改回「還沒決定」會變成一個找不到的動作
      onSelected: (v) => onPick!(v.isEmpty ? null : v),
      itemBuilder: (_) => [
        for (final v in _choices)
          PopupMenuItem(
            value: v,
            child: Row(children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                    color: blockStateColor(v), shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(blockStateLabel(v),
                  style: UepText.sans(size: 12, color: s.ink)),
            ]),
          ),
        if (st != null) ...[
          const PopupMenuDivider(),
          PopupMenuItem(
            value: '',
            child: Text('清除標記',
                style: UepText.sans(size: 12, color: s.inkMute)),
          ),
        ],
      ],
      child: chip,
    );
  }

  Widget _chip(UepSurface s) {
    final st = state;
    if (st == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: s.line),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text('＋狀態',
            style: UepText.mono(
                size: 8.5, letterSpacing: 1.0, color: s.inkMute)),
      );
    }
    final c = blockStateColor(st);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: .13),
        border: Border.all(color: c.withValues(alpha: .5)),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(blockStateLabel(st),
          style: UepText.mono(size: 8.5, letterSpacing: 1.0, color: c)),
    );
  }
}
