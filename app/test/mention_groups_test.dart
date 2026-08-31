import 'package:chatroom_app/api/messages_api.dart';
import 'package:chatroom_app/core/mention_groups.dart';
import 'package:chatroom_app/models/message.dart';
import 'package:chatroom_app/widgets/mention_field.dart';
import 'package:flutter_test/flutter_test.dart';

/// 群組 @（`@all` / `@agents` / `@humans`）的 App 端。
///
/// **展開在 Hub 那端做**——這是 multi-agent 聊天室，agent 透過 MCP 發
/// `@all` 也必須生效。App 只負責：把群組名送出去、把回來的展開結果摺疊
/// 回一顆 chip。
void main() {
  group('保留字辨識', () {
    test('三個群組名都認得', () {
      expect(isMentionGroup('all'), isTrue);
      expect(isMentionGroup('agents'), isTrue);
      expect(isMentionGroup('humans'), isTrue);
    });

    test('大小寫不敏感——@All 與 @all 是同一個意圖，'
        '讓其中一個安靜失效正是這張票要消除的東西', () {
      expect(isMentionGroup('All'), isTrue);
      expect(isMentionGroup('HUMANS'), isTrue);
    });

    test('不是群組的名字就不是', () {
      expect(isMentionGroup('Novia'), isFalse);
      expect(isMentionGroup('allen'), isFalse);
    });
  });

  group('送出時把群組字面一起帶走，不在 App 展開', () {
    test('@all 會出現在 mentions 裡', () {
      final found = extractMentions(
        '@all 這件事大家都要知道',
        ['Novia', 'Bernie', ...kMentionGroups.keys],
      );
      expect(found, contains('all'));
    });

    test('群組與人名可以並存', () {
      final found = extractMentions(
        '@humans 麻煩看一下，@Novia 你也是',
        ['Novia', 'Bernie', ...kMentionGroups.keys],
      );
      expect(found, containsAll(['humans', 'Novia']));
    });

    test('@allen 不算 @all——右邊界檢查對群組名同樣要成立', () {
      final found = extractMentions(
        '@allen 你好',
        ['allen', ...kMentionGroups.keys],
      );
      expect(found, ['allen']);
    });
  });

  group('收到之後摺疊回一顆 chip', () {
    Message msg({
      List<String> mentions = const [],
      List<String> groups = const [],
    }) =>
        Message.fromJson({
          'id': 'm1',
          'seq': 1,
          'content': '@all 大家好',
          'mentions': mentions,
          'mention_groups': groups,
        });

    test('mention_groups 解析得出來', () {
      final m = msg(mentions: ['Novia', 'Bernie'], groups: ['all']);
      expect(m.mentionGroups, ['all']);
      expect(m.mentions, ['Novia', 'Bernie']);
    });

    test('舊版 Hub 不回這個欄位時是空清單，不是 null——'
        '那時 mentions 本來也不會有展開的結果，兩邊自然一致', () {
      final m = msg(mentions: ['Novia']);
      expect(m.mentionGroups, isEmpty);
    });
  });

  group('展開成空的群組不能安靜地丟掉', () {
    PostResult parse(Map<String, dynamic> json) => PostResult(
          id: json['id'] as String,
          seq: json['seq'] as int,
          emptyGroups: ((json['empty_groups'] as List?) ?? const [])
              .map((e) => e.toString())
              .toList(),
        );

    test('empty_groups 帶得回來', () {
      final r = parse({'id': 'm1', 'seq': 1, 'empty_groups': ['humans']});
      expect(r.emptyGroups, ['humans']);
    });

    test('舊版 Hub 沒有這個欄位時是空清單——那時它也不做群組展開', () {
      final r = parse({'id': 'm1', 'seq': 1});
      expect(r.emptyGroups, isEmpty);
    });
  });
}
