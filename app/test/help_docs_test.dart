import 'package:chatroom_app/l10n/l10n.dart';
import 'package:chatroom_app/screens/help/help_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// 說明內容是資料，不是畫面：三份文件的結構壞掉（少一份、空的節、空的條目）
/// 在畫面上長得像「那一段還沒寫」，不會有人當成 bug 回報。
///
/// 文案抽到 ARB 之後，空白的來源多了一個——鍵漏翻、翻成空字串——所以每個
/// 支援的語言都要各驗一次，不能只驗模板那份。
void main() {
  for (final locale in AppLocalizations.supportedLocales) {
    final l10n = lookupAppLocalizations(locale);
    final docs = helpDocs(l10n);

    test('三個 topic 都有說明文件（$locale）', () {
      for (final topic in HelpTopic.values) {
        expect(docs[topic], isNotNull, reason: '$topic 沒有說明');
      }
    });

    test('分組小標指得到真的存在的條目（$locale）', () {
      for (final entry in docs.entries) {
        for (final section in entry.value.sections) {
          for (final block in section.blocks.whereType<HelpItemsBlock>()) {
            for (final at in block.groups.entries) {
              expect(at.key, inInclusiveRange(0, block.items.length - 1),
                  reason: '${entry.key} 的「${section.title}」分組指到第 ${at.key} 條，'
                      '但那個清單只有 ${block.items.length} 條');
              expect(at.value, isNotEmpty);
            }
          }
        }
      }
    });

    // 只有小標沒有內文的條目在畫面上是一行粗體字，看起來像「這段還沒寫」。
    test('粗體小標後面要有內文（$locale）', () {
      for (final entry in docs.entries) {
        for (final section in entry.value.sections) {
          for (final block in section.blocks.whereType<HelpItemsBlock>()) {
            for (final item in block.items) {
              if (!item.hasLead) continue;
              expect(item.chunks.length, greaterThan(1),
                  reason: '${entry.key} 的「${section.title}」有一條只有小標'
                      '「${item.chunks.first.text}」');
            }
          }
        }
      }
    });

    test('每一節都有標題與至少一個區塊（$locale）', () {
      for (final entry in docs.entries) {
        final doc = entry.value;
        expect(doc.title, isNotEmpty);
        expect(doc.sections, isNotEmpty, reason: '${entry.key} 沒有任何一節');
        for (final section in doc.sections) {
          expect(section.label, isNotEmpty);
          expect(section.title, isNotEmpty);
          expect(section.blocks, isNotEmpty,
              reason: '${entry.key} 的「${section.title}」是空的');
          if (section.intro != null) expect(section.intro, isNotEmpty);
        }
      }
    });

    // 鍵漏翻、翻成空字串，在畫面上是一格空白——每種區塊的每個字串都驗。
    test('各區塊的文字都不是空的、表格欄數對得上（$locale）', () {
      for (final entry in docs.entries) {
        for (final section in entry.value.sections) {
          final where = '${entry.key} 的「${section.title}」';
          for (final block in section.blocks) {
            switch (block) {
              case HelpItemsBlock():
                expect(block.items, isNotEmpty, reason: where);
                for (final item in block.items) {
                  expect(item.chunks, isNotEmpty, reason: where);
                  for (final chunk in item.chunks) {
                    expect(chunk.text, isNotEmpty, reason: where);
                  }
                }
              case HelpCardsBlock():
                expect(block.cards, isNotEmpty, reason: where);
                for (final c in block.cards) {
                  expect(c.title, isNotEmpty, reason: where);
                  expect(c.body, isNotEmpty, reason: where);
                  expect(c.subtitle, isNotEmpty, reason: where);
                }
              case HelpTableBlock():
                expect(block.rows, isNotEmpty, reason: where);
                for (final h in block.headers) {
                  expect(h, isNotEmpty, reason: where);
                }
                for (final row in block.rows) {
                  expect(row.length, block.headers.length,
                      reason: '$where 有一列欄數與表頭不同：$row');
                  for (final cell in row) {
                    expect(cell, isNotEmpty, reason: '$where 有空白儲存格：$row');
                  }
                }
              case HelpCalloutBlock():
                expect(block.text, isNotEmpty, reason: where);
              case HelpStepsBlock():
                expect(block.steps, isNotEmpty, reason: where);
                for (final step in block.steps) {
                  expect(step.title, isNotEmpty, reason: where);
                  if (step.body != null) {
                    expect(step.body, isNotEmpty, reason: where);
                  }
                }
              case HelpParagraphBlock():
                expect(block.text, isNotEmpty, reason: where);
            }
          }
        }
      }
    });
  }

  test('未知的網址 slug 退回主畫面那份', () {
    expect(helpTopicFromSlug('settings'), HelpTopic.settings);
    expect(helpTopicFromSlug('host'), HelpTopic.host);
    expect(helpTopicFromSlug('nope'), HelpTopic.main);
    expect(helpTopicFromSlug(null), HelpTopic.main);
  });
}
