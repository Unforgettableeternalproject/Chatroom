import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';

/// Markdown 套件的唯一接觸點——換套件只改這裡。
/// 安全限制：訊息內容來自 agent，不啟用 raw HTML / 任意 widget 注入。
class UepMarkdownBody extends StatelessWidget {
  const UepMarkdownBody({super.key, required this.data, this.baseColor});

  final String data;
  final Color? baseColor;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final ink = baseColor ?? s.ink;
    return MarkdownBody(
      data: data,
      selectable: true,
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
