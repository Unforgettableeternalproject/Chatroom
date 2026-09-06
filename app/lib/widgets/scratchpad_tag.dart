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

/// 衝突重試時該送哪一份標籤。
///
/// 🔴 **不可以送本地那份。** `_save` 帶 `b.tags` 是對的（剛編輯完，手上就是
/// 最新的），但**衝突的定義就是「對方改過了」**——那條路徑上的 `b` 必然是
/// 舊的。同一行程式碼，前提相反。
///
/// 審核用Codex 2026-09-05 用現行 API 重現：另一端把標籤改成 `bug`（rev 2）
/// → 舊內容寫入拿 409 → 依 UI 的「保留我的」retry 後 200，**最終 tags 變回
/// `[]`**。兩端各自的測試都不會紅（兩條路徑都「有把 tags 送出去」），要有人
/// 真的讓兩端交錯才看得見。
///
/// [detail] 是 409 `scratchpad_block_stale` 的 detail。它帶 `tags` 就用它
/// ——**含 `[]`**（那是「對方把標籤拿掉了」，一個值，不是「沒講」）。
///
/// ⚠️ [fallback] 只在**舊 Hub 不帶這一欄**時走到，而**那條路徑仍然會覆蓋**。
/// 沒有更好的選擇：API 要的是整份新值，不送等於清空（更糟）。這是已知的
/// 降級，不是修好了。
List<String> conflictTags(
  Map<String, dynamic> detail, {
  required List<String> fallback,
}) {
  if (!detail.containsKey('tags')) return fallback;
  return [
    for (final t in (detail['tags'] as List?) ?? const [])
      if (t is String && t.isNotEmpty) t,
  ];
}

// 段落狀態**沒有**對應的 `conflictState()`，那是刻意的。
//
// 它走的是 containsKey 語意（不送＝不動），所以衝突重試什麼都不必做：
// 不碰那一欄，對方剛標的自然留著。**需要一個 conflict helper 這件事本身，
// 就是整份覆寫語意的成本**——真要為 state 寫一支，寫出來的會是一個永遠不
// 該被呼叫的函式。
//
// 🔴 **Hub `0e1cae1` 之後 tags 也吃 containsKey 了，這支仍然留著。**
// 那不是漏刪：App 與 Hub 分開更新，新 App 打舊 Hub 時「不送 tags」＝清除
// （舊 model 是 `default_factory=list`）。所以 UI 這邊仍然一律送整份值，
// 而只要還在送，衝突重試就仍然需要它把對方剛改的那份撈回來。
//
// 要拿掉這支的前提是**確定沒有舊 Hub 在跑**，那是部署面的判斷，不是這裡
// 能決定的。

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

/// 標籤改不動時要說的那句話。空字串＝不必說。
///
/// 🔴 **只在「狀態標得動、標籤標不動」時才說。** 那是唯一會讓人以為壞掉的
/// 組合：兩顆同形、並排、一樣大的 chip，一顆點得動一顆點不動（決策 09/06
/// 裁定 tags 的權限今天不跟著 state 放寬）。
///
/// 整塊板唯讀時不說——那時「＋狀態」也不在，沒有並排的對照，多一句話只是
/// 對一個沒有人期待的東西解釋。**「被擋」與「這裡本來就沒有這個功能」是
/// 兩種訊息**，只有前者需要理由。
///
/// **抽成頂層函式是為了測得到**（同 `tagRemovalError`）：這是這顆 chip 上
/// 唯一有判斷的東西，埋在 build 裡等於沒有守著。
String tagLockedReason({required bool canEdit, required bool canSetState}) {
  if (canEdit) return '';
  if (!canSetState) return '';
  return '標籤只有寫這一段的人能改。狀態（後來怎麼了）任何板成員都標得動。';
}

/// 一顆標籤徽章。
///
/// [onPick] 給了才可以改；`null` 時它只是一個顯示——**唯讀的人不該看到一個
/// 按下去沒反應的東西**。
///
/// [lockedReason] 非空時，這顆 chip 會帶著那句話（見 [tagLockedReason]）。
/// 那是「被擋」而不是「沒有這個功能」的情況，畫面要說得出差別。
///
/// [allowed] 空的時候整顆不畫（舊 Hub 沒有這個功能），呼叫端不必自己判斷。
class ScratchpadTagChip extends StatelessWidget {
  const ScratchpadTagChip({
    super.key,
    required this.tag,
    this.allowed = const [],
    this.onPick,
    this.lockedReason = '',
  });

  /// 改不動的理由。空＝不必說（見 [tagLockedReason]）。
  final String lockedReason;

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
    if (onPick == null || allowed.isEmpty) {
      // 被擋下來的要說得出為什麼；純粹唯讀的不說（見 [tagLockedReason]）
      return lockedReason.isEmpty
          ? chip
          : Tooltip(message: lockedReason, child: chip);
    }

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
