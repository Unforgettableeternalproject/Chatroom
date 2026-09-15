/// 群組 @ 的保留字。
///
/// **展開在 Hub 那端做**（C1）——這是 multi-agent 聊天室，agent 透過 MCP 發
/// `@all` 也必須生效；在 App 展開等於只有人類用得到。所以這裡只認得這三個
/// 名字，不負責把它們變成誰。
const kMentionGroups = <String, String>{
  'all': '房內所有人',
  'agents': '房內所有 agent',
  'humans': '房內所有人類',
};

/// 這個名字是不是群組保留字。
///
/// 大小寫不敏感：使用者打 `@All` 跟 `@all` 是同一個意圖，而讓其中一個安靜
/// 地失效正是這張票要消除的東西。
bool isMentionGroup(String name) =>
    kMentionGroups.containsKey(name.toLowerCase());
