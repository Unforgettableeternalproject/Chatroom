import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';

/// Markdown 套件的唯一接觸點——換套件只改這裡。
/// 安全限制：訊息內容來自 agent，不啟用 raw HTML / 任意 widget 注入。
class UepMarkdownBody extends StatelessWidget {
  const UepMarkdownBody({
    super.key,
    required this.data,
    this.baseColor,
    this.mentions = const [],
  });

  final String data;
  final Color? baseColor;

  /// 訊息的 mentions 清單：內文中的「@名字」會渲染成帶外框的 chip，
  /// 與一般內容視覺區分。只認清單裡的名字，不做整段 @ 掃描。
  final List<String> mentions;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final ink = baseColor ?? s.ink;
    return MarkdownBody(
      data: data,
      // ⚠️ 不要開 selectable。它會用 SelectableText 渲染，而 SelectableText
      // **即使沒有選取任何文字也會吃下右鍵**，彈出系統的「Select All」選單，
      // 把訊息自己的右鍵選單（釘選／回覆／刪除）搶走，位置也由它決定。
      // 選取能力改由聊天畫面外層的 SelectionArea 提供——它只在真的有選取時
      // 才顯示選單，右鍵就還給我們了，而且能跨訊息選取（2026-08-30 實測）。
      selectable: false,
      inlineSyntaxes: [
        if (mentions.isNotEmpty) _MentionSyntax(mentions),
      ],
      builders: {'uepMention': _MentionChipBuilder()},
      styleSheet: MarkdownStyleSheet(
        p: UepText.serif(size: 14.5, color: ink),
        strong: UepText.serif(
            size: 14.5, weight: FontWeight.w600, color: s.inkTitle),
        em: UepText.serif(size: 14.5, color: ink).copyWith(
            fontStyle: FontStyle.italic),
        listBullet: UepText.serif(size: 14.5, color: ink),
        blockquote: UepText.serif(size: 13.5, color: s.inkSoft),
        blockquoteDecoration: BoxDecoration(
          border: Border(left: BorderSide(color: s.hairlineStrong, width: 2)),
        ),
        blockquotePadding: const EdgeInsets.only(left: 12, top: 2, bottom: 2),
        code: UepText.code(size: 12.5, color: s.inkSoft).copyWith(
          backgroundColor: s.bgSunken,
        ),
        codeblockDecoration: BoxDecoration(
          color: s.bgSunken,
          border: Border.all(color: s.line),
          borderRadius: BorderRadius.circular(4),
        ),
        codeblockPadding: const EdgeInsets.symmetric(
            horizontal: 14, vertical: 12),
        h1: UepText.display(size: 22, color: s.inkTitle),
        h2: UepText.display(size: 19, color: s.inkTitle),
        h3: UepText.serif(
            size: 16, weight: FontWeight.w600, color: s.inkTitle),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(top: BorderSide(color: s.hairline)),
        ),
        a: TextStyle(color: UepColors.gold),
        tableBorder: TableBorder.all(color: s.line),
        tableBody: UepText.serif(size: 13, color: ink, height: 1.6),
      ),
    );
  }
}

/// 「@ + mentions 中任一名字」的比對式。
///
/// 名字先逐一 RegExp.escape、長的在前——「Nova-2」要贏過「Nova」。渲染 chip
/// 與判斷「哪些 mention 沒出現在正文」共用這一份：兩邊若各自實作，
/// `'@Nova-2'.contains('@Nova')` 這種前綴包含就會讓 Nova 被當成已渲染而從
/// 泡泡上消失（實際發生過，測試抓到）。
String mentionPattern(List<String> names) {
  final sorted = [...names]..sort((a, b) => b.length.compareTo(a.length));
  return '@(?:${sorted.map(RegExp.escape).join('|')})';
}

/// 比對「@ + mentions 中任一名字」的 inline syntax。
class _MentionSyntax extends md.InlineSyntax {
  _MentionSyntax(List<String> names)
      : super(mentionPattern(names), caseSensitive: true);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('uepMention', match[0]!));
    return true;
  }
}

/// mention chip：金色細框 + 淡底。
///
/// 兩處共用——內文裡的 `@名字`，以及泡泡底下那排「正文沒寫 @ 的 mentions」
/// （agent 走 API 的 `mentions` 參數時是常態）。樣式只有一份，不會漂移。
class MentionChip extends StatelessWidget {
  const MentionChip(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 1),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: UepColors.gold.withValues(alpha: .10),
        border: Border.all(color: UepColors.gold.withValues(alpha: .45)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: UepText.sans(
                size: 12.5, weight: FontWeight.w600, color: UepColors.gold)
            .copyWith(height: 1.3),
      ),
    );
  }
}

/// 把內文中比對到的 `@名字` 交給 [MentionChip] 呈現。
class _MentionChipBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    return MentionChip(element.textContent);
  }
}

/// 這則訊息裡「有被 ping、但正文沒有出現 `@名字`」的對象。
///
/// mention 在這個系統裡是結構化欄位（`chatroom_post(mentions=[...])`），與正文
/// 寫不寫 `@` 無關。人類在 App 用 mention_field 打字會把 `@名字` 帶進正文，
/// 所以看得到 chip；agent 直接帶 mentions 參數則不會——泡泡上因此完全看不出
/// 這則訊息 tag 了人，即使收件端的 `mentioned` 判定是 true。這個函式補的就是
/// 那段落差（2026-08-29 實機發現）。
List<String> unrenderedMentions(String content, List<String> mentions) {
  if (mentions.isEmpty) return const [];
  // 走與渲染同一條比對式，結果才會互補而不是各說各話
  final rendered = RegExp(mentionPattern(mentions), caseSensitive: true)
      .allMatches(content)
      .map((m) => m[0]!.substring(1))
      .toSet();
  return [for (final n in mentions) if (!rendered.contains(n)) n];
}
