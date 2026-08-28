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
      selectable: true,
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

/// 比對「@ + mentions 中任一名字」的 inline syntax。
/// 名字先逐一 RegExp.escape、長的在前——「Nova-2」要贏過「Nova」。
class _MentionSyntax extends md.InlineSyntax {
  _MentionSyntax(List<String> names)
      : super(_patternFor(names), caseSensitive: true);

  static String _patternFor(List<String> names) {
    final sorted = [...names]..sort((a, b) => b.length.compareTo(a.length));
    final joined = sorted.map(RegExp.escape).join('|');
    return '@(?:$joined)';
  }

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('uepMention', match[0]!));
    return true;
  }
}

/// mention chip：金色細框 + 淡底，把 @名字 從內文中框出來。
class _MentionChipBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 1),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: UepColors.gold.withValues(alpha: .10),
        border: Border.all(color: UepColors.gold.withValues(alpha: .45)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        element.textContent,
        style: UepText.sans(
            size: 12.5, weight: FontWeight.w600, color: UepColors.gold)
            .copyWith(height: 1.3),
      ),
    );
  }
}
