import '../l10n/l10n.dart';
import '../models/participant.dart';

/// 群組 @ 的保留字。
///
/// **展開在 Hub 那端做**（C1）——這是 multi-agent 聊天室，agent 透過 MCP 發
/// `@all` 也必須生效；在 App 展開等於只有人類用得到。所以這裡只認得這三個
/// 名字，不負責把它們變成誰。
///
/// 說明文字跟著語言走，所以這裡是 getter 而不是 `const`——鍵集合仍然固定，
/// 呼叫端照樣用 `.keys` / `.entries` / `.containsKey`。
Map<String, String> get kMentionGroups => <String, String>{
      'all': L10n.current.mentionGroupAll,
      'agents': L10n.current.mentionGroupAgents,
      'humans': L10n.current.mentionGroupHumans,
    };

/// 這個名字是不是群組保留字。
///
/// 大小寫不敏感：使用者打 `@All` 跟 `@all` 是同一個意圖，而讓其中一個安靜
/// 地失效正是這張票要消除的東西。
bool isMentionGroup(String name) =>
    kMentionGroups.containsKey(name.toLowerCase());

/// 「會 tag 到」預覽用：把群組換成中文、並略掉已被群組涵蓋的個別成員。
///
/// 只影響顯示，送出的 mentions 不變（Hub 會展開群組並去重）。涵蓋範圍與
/// Hub 的 `_expand_mention_groups` 對齊：`all` 涵蓋所有人、`agents` 涵蓋
/// role=agent、`humans` 涵蓋 role=human；發話者自己與臨時成員（subagent）
/// 不會被群組展開，所以不能因為有群組就藏起來。
List<String> mentionPreviewNames(
  List<String> names,
  List<Participant> members, {
  String? selfParticipantId,
}) {
  final groups = <String>{
    for (final n in names)
      if (isMentionGroup(n)) n.toLowerCase(),
  };
  final byName = <String, Participant>{
    for (final p in members) p.displayName: p,
  };
  bool covered(String name) {
    final p = byName[name];
    if (p == null || p.ephemeral || p.id == selfParticipantId) return false;
    if (groups.contains('all')) return true;
    return p.isHuman
        ? groups.contains('humans')
        : groups.contains('agents') && p.role == 'agent';
  }

  final l10n = L10n.current;
  final out = <String>[];
  final shown = <String>{};
  for (final n in names) {
    if (isMentionGroup(n)) {
      final g = n.toLowerCase();
      // `@all` 已涵蓋兩個子群組，不必再列
      if (g != 'all' && groups.contains('all')) continue;
      if (!shown.add(g)) continue;
      out.add(switch (g) {
        'all' => l10n.chatTagGroupAll,
        'agents' => l10n.chatTagGroupAgents,
        _ => l10n.chatTagGroupHumans,
      });
    } else if (!covered(n)) {
      out.add(n);
    }
  }
  return out;
}
