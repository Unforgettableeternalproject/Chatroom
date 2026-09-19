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

    test('每一節都有標題與至少一條說明（$locale）', () {
      for (final entry in docs.entries) {
        final doc = entry.value;
        expect(doc.title, isNotEmpty);
        expect(doc.sections, isNotEmpty, reason: '${entry.key} 沒有任何一節');
        for (final section in doc.sections) {
          expect(section.label, isNotEmpty);
          expect(section.title, isNotEmpty);
          expect(section.items, isNotEmpty,
              reason: '${entry.key} 的「${section.title}」是空的');
          for (final item in section.items) {
            expect(item.chunks, isNotEmpty);
            for (final chunk in item.chunks) {
              expect(chunk.text, isNotEmpty);
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
