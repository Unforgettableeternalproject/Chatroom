import 'package:flutter/material.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import 'kind_badge.dart';

/// 說明頁用的視覺區塊。樣式全走主題 token（`context.uep`、`UepText`），
/// 亮暗主題與字級縮放都跟著走；版面以「換算成 100% 字級後的寬度」決定
/// 單欄或多欄，所以字級放大時會比視窗變窄更早收成單欄，不會擠爆。
///
/// 區塊內的文字支援兩種行內標記：`` `code` `` 畫成 chip（快捷鍵、語法、
/// 設定鍵），`**粗體**` 是要被掃到的關鍵詞。

/// 條目裡的一段文字。`code` 的那段畫成 chip（快捷鍵、語法、位址），
/// `bold` 的那段是要被掃到的關鍵詞。
@immutable
class HelpChunk {
  const HelpChunk.text(this.text)
      : isCode = false,
        isBold = false;
  const HelpChunk.code(this.text)
      : isCode = true,
        isBold = false;
  const HelpChunk.bold(this.text)
      : isCode = false,
        isBold = true;

  final String text;
  final bool isCode;
  final bool isBold;
}

final _markup = RegExp(r'`([^`]+)`|\*\*([^*]+)\*\*');

/// 把含 `` `code` `` 與 `**bold**` 標記的字串拆成 chunk。
List<HelpChunk> parseHelpMarkup(String raw) {
  final out = <HelpChunk>[];
  var at = 0;
  for (final m in _markup.allMatches(raw)) {
    if (m.start > at) out.add(HelpChunk.text(raw.substring(at, m.start)));
    final code = m.group(1);
    out.add(code != null ? HelpChunk.code(code) : HelpChunk.bold(m.group(2)!));
    at = m.end;
  }
  if (at < raw.length) out.add(HelpChunk.text(raw.substring(at)));
  return out;
}

/// 行內 token（快捷鍵、語法、位址）的小 chip。
class HelpCodeChip extends StatelessWidget {
  const HelpCodeChip({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: s.bgCard,
        border: Border.all(color: s.line),
        borderRadius: BorderRadius.circular(4),
      ),
      child:
          Text(text, style: UepText.code(size: 12, color: s.ink, height: 1.3)),
    );
  }
}

/// 一段內文：chunk 清單（或含標記的字串）排成一個 Text.rich。
class HelpRichText extends StatelessWidget {
  const HelpRichText(this.markup, {super.key, this.style, this.color});

  /// 含 `` `code` ``／`**bold**` 標記的字串。
  final String markup;
  final TextStyle? style;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final base = style ??
        UepText.serif(size: 14, color: color ?? s.inkSoft, height: 1.7);
    return Text.rich(
      helpChunksSpan(parseHelpMarkup(markup)),
      style: base,
    );
  }
}

/// chunk → TextSpan（code 用 WidgetSpan 畫 chip）。條目列與區塊共用。
TextSpan helpChunksSpan(List<HelpChunk> chunks) => TextSpan(children: [
      for (final chunk in chunks)
        if (chunk.isCode)
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: HelpCodeChip(text: chunk.text),
          )
        else
          TextSpan(
            text: chunk.text,
            style:
                chunk.isBold ? const TextStyle(fontWeight: FontWeight.w700) : null,
          ),
    ]);

/// 換算成 100% 字級的可用寬度。字級放大時這個值會變小，
/// 區塊因此更早收成單欄。
double _effectiveWidth(BuildContext context, double maxWidth) {
  final scale = MediaQuery.textScalerOf(context).scale(10) / 10;
  return maxWidth / (scale <= 0 ? 1 : scale);
}

/// 分節：大標＋一句導語，底下接區塊。
class HelpSectionBlock extends StatelessWidget {
  const HelpSectionBlock({
    super.key,
    required this.title,
    required this.icon,
    required this.children,
    this.label,
    this.intro,
  });

  final String title;

  /// 標題旁的 mono 小標；與標題同字時不要傳。
  final String? label;
  final String? intro;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: s.line)),
          ),
          width: double.infinity,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 10,
                runSpacing: 2,
                children: [
                  Icon(icon, size: 18, color: s.inkSoft),
                  Text(title, style: UepText.sectionTitle(color: s.inkTitle)),
                  if (label != null)
                    MonoLabel(label!, color: s.inkMute.withValues(alpha: .7)),
                ],
              ),
              if (intro != null) ...[
                const SizedBox(height: 6),
                HelpRichText(intro!, color: s.inkSoft),
              ],
            ],
          ),
        ),
        for (final child in children) ...[
          const SizedBox(height: 14),
          child,
        ],
      ],
    );
  }
}

/// 一張資訊卡的內容。
@immutable
class HelpCardData {
  const HelpCardData({
    required this.title,
    required this.body,
    this.tag,
    this.subtitle,
  });

  /// 左上的 mono 小標籤。
  final String? tag;
  final String title;
  final String? subtitle;
  final String body;
}

/// 並排的資訊卡片。寬度夠就 2～3 欄，窄或字級放大時自動改單欄；
/// 同一列的卡片等高。
class HelpCardGrid extends StatelessWidget {
  const HelpCardGrid({super.key, required this.cards});

  final List<HelpCardData> cards;

  /// 依換算寬度決定欄數。
  static int columnsFor(double effectiveWidth, int count) {
    final fit = effectiveWidth >= 640 ? 3 : (effectiveWidth >= 420 ? 2 : 1);
    return fit.clamp(1, count < 1 ? 1 : count);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cols = columnsFor(_effectiveWidth(context, c.maxWidth), cards.length);
      // 4 張卡排 3 欄會剩一張孤兒，改 2 欄
      final n = (cards.length == 4 && cols == 3) ? 2 : cols;
      final rows = <List<HelpCardData>>[];
      for (var i = 0; i < cards.length; i += n) {
        rows.add(cards.sublist(i, i + n > cards.length ? cards.length : i + n));
      }
      return Column(
        children: [
          for (var r = 0; r < rows.length; r++) ...[
            if (r > 0) const SizedBox(height: 10),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < n; i++) ...[
                    if (i > 0) const SizedBox(width: 10),
                    Expanded(
                      child: i < rows[r].length
                          ? _HelpCard(data: rows[r][i])
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      );
    });
  }
}

class _HelpCard extends StatelessWidget {
  const _HelpCard({required this.data});

  final HelpCardData data;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: s.bgSoft,
        border: Border.all(color: s.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (data.tag != null) ...[
            MonoLabel(data.tag!, color: s.inkMute.withValues(alpha: .8)),
            const SizedBox(height: 6),
          ],
          Text(data.title, style: UepText.itemTitle(color: s.inkTitle)),
          if (data.subtitle != null) ...[
            const SizedBox(height: 2),
            Text(data.subtitle!,
                style: UepText.sans(size: 13, color: s.inkMute, height: 1.4)),
          ],
          const SizedBox(height: 8),
          HelpRichText(data.body,
              style: UepText.serif(size: 13.5, color: s.inkSoft, height: 1.65)),
        ],
      ),
    );
  }
}

/// 表格：表頭＋多列。寬時是真正的表格，窄或字級放大時每列收成一張小卡
/// （第一欄當標題，其餘欄「表頭：內容」）。
class HelpTable extends StatelessWidget {
  const HelpTable({super.key, required this.headers, required this.rows});

  final List<String> headers;

  /// 每列的欄數必須等於 [headers] 的長度。
  final List<List<String>> rows;

  /// 低於這個換算寬度就改堆疊。
  static const double stackBelow = 520;

  @override
  Widget build(BuildContext context) {
    assert(headers.length >= 2 && rows.every((r) => r.length == headers.length),
        '每列的欄數必須等於表頭');
    return LayoutBuilder(builder: (context, c) {
      final stacked = _effectiveWidth(context, c.maxWidth) < stackBelow;
      return stacked ? _stacked(context) : _table(context);
    });
  }

  Widget _table(BuildContext context) {
    final s = context.uep;
    final n = headers.length;
    final head = UepText.mono(size: 11, color: s.inkMute, letterSpacing: 1.2);
    final lead = UepText.sans(
        size: 13.5, weight: FontWeight.w700, color: s.inkTitle, height: 1.5);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: s.line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Table(
          columnWidths: {
            for (var i = 0; i < n; i++)
              i: FlexColumnWidth(i == 0 ? 1.1 : (i == n - 1 ? 2.0 : 1.6)),
          },
          defaultVerticalAlignment: TableCellVerticalAlignment.top,
          border: TableBorder(
            horizontalInside: BorderSide(color: s.line),
            verticalInside: BorderSide(color: s.line),
          ),
          children: [
            TableRow(
              decoration: BoxDecoration(color: s.bgSunken),
              children: [
                for (final h in headers)
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Text(h, style: head),
                  ),
              ],
            ),
            for (final row in rows)
              TableRow(
                decoration: BoxDecoration(color: s.bgSoft),
                children: [
                  for (var i = 0; i < n; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      child: i == 0
                          ? HelpRichText(row[i], style: lead)
                          : HelpRichText(row[i],
                              style: UepText.serif(
                                  size: 13.5, color: s.inkSoft, height: 1.65)),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _stacked(BuildContext context) {
    final s = context.uep;
    return Column(
      children: [
        for (var r = 0; r < rows.length; r++) ...[
          if (r > 0) const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: s.bgSoft,
              border: Border.all(color: s.line),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                HelpRichText(rows[r][0],
                    style: UepText.sans(
                        size: 14,
                        weight: FontWeight.w700,
                        color: s.inkTitle,
                        height: 1.5)),
                for (var i = 1; i < headers.length; i++) ...[
                  const SizedBox(height: 6),
                  MonoLabel(headers[i],
                      size: 10, color: s.inkMute.withValues(alpha: .8)),
                  const SizedBox(height: 2),
                  HelpRichText(rows[r][i],
                      style: UepText.serif(
                          size: 13.5, color: s.inkSoft, height: 1.65)),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// 提示（tip）與注意（warn）兩種語氣。
enum HelpCalloutTone { tip, warn }

/// 提示／注意區塊：左邊一條色線＋淡底，不用整塊色。
class HelpCallout extends StatelessWidget {
  const HelpCallout({
    super.key,
    required this.text,
    this.tone = HelpCalloutTone.tip,
    this.title,
  });

  final String text;
  final HelpCalloutTone tone;

  /// 小標（例如「提示」「注意」）；不傳就只有內文。
  final String? title;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final warn = tone == HelpCalloutTone.warn;
    final accent = warn ? UepColors.error : UepColors.info;
    // 左邊色線不用 Border(left:)：四邊顏色不同的 Border 配 borderRadius
    // 會在繪製時丟例外，所以改成外框一致、色線另外畫。
    return Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Color.alphaBlend(accent.withValues(alpha: .07), s.bgSoft),
        border: Border.all(color: s.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 3, color: accent.withValues(alpha: .85)),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 14, 11),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(
                        warn
                            ? Icons.warning_amber_rounded
                            : Icons.lightbulb_outline,
                        size: 16,
                        color: accent.withValues(alpha: .9),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (title != null) ...[
                            MonoLabel(title!, color: s.inkSoft),
                            const SizedBox(height: 3),
                          ],
                          HelpRichText(text,
                              style: UepText.serif(
                                  size: 13.5, color: s.ink, height: 1.65)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一個步驟。
@immutable
class HelpStepData {
  const HelpStepData({required this.title, this.body});

  final String title;
  final String? body;
}

/// 編號步驟清單。
class HelpSteps extends StatelessWidget {
  const HelpSteps({super.key, required this.steps});

  final List<HelpStepData> steps;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Column(
      children: [
        for (var i = 0; i < steps.length; i++)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 28,
                  child: Column(
                    children: [
                      Container(
                        constraints:
                            const BoxConstraints(minWidth: 24, minHeight: 24),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: s.bgSunken,
                          shape: BoxShape.circle,
                          border: Border.all(color: s.lineStrong),
                        ),
                        child: Text('${i + 1}',
                            style: UepText.mono(
                                size: 11.5,
                                color: s.inkSoft,
                                letterSpacing: 0)),
                      ),
                      if (i != steps.length - 1)
                        Expanded(
                          child: Container(width: 1, color: s.line),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                        top: 2, bottom: i == steps.length - 1 ? 0 : 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(steps[i].title,
                            style: UepText.serif(
                                size: 14.5,
                                weight: FontWeight.w700,
                                color: s.inkTitle,
                                height: 1.5)),
                        if (steps[i].body != null) ...[
                          const SizedBox(height: 2),
                          HelpRichText(steps[i].body!,
                              style: UepText.serif(
                                  size: 13.5, color: s.inkSoft, height: 1.65)),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
