"""房內唯一命名——偏好名稱優先，衝突加序號，未指定則從名字池發放。"""

import random

# 名字池：每個語言一組。`adjectives`＋`nouns` 組合出「形容詞-名詞」，
# `premade` 是整個名字直接抽；兩種都有時各半抽，只有一種就抽那種。
# 英文的預製名單刻意留空——要放什麼名字是主持人的事，不替他編。
_POOLS: dict[str, dict[str, list[str]]] = {
    "en": {
        "adjectives": [
            "Swift", "Quiet", "Bright", "Amber", "Cobalt", "Ivory", "Crimson",
            "Silver", "Nimble", "Steady", "Vivid", "Mellow", "Astral", "Lucid",
            "Ember", "Frost",
        ],
        "nouns": [
            "Falcon", "Otter", "Lynx", "Heron", "Fox", "Raven", "Wren", "Badger",
            "Comet", "Harbor", "Cinder", "Willow", "Beacon", "Drift", "Quill",
            "Sable",
        ],
        "premade": ["Paul Jackson", "Maximizer", "Bernie", "Agent", "Hollow Earth", "KungFu Panda", "Bibilabu", "Better Call Saul", "Six-Seven", "The Stranger", "Ark Night", "Calamity Devs", "JomamaRush", "Beast Senpai"],
    },
    "zh": {
        "adjectives": [
            "敏捷的", "靜謐的", "明亮的", "琥珀的", "鈷藍的", "象牙的", "緋紅的", "銀白的",
            "輕巧的", "沉穩的", "鮮明的", "溫潤的", "星輝的", "清澈的", "餘燼的", "霜白的",
        ],
        "nouns": [
            "隼", "水獺", "山貓", "蒼鷺", "狐", "渡鴉", "鷦鷯", "獾",
            "彗星", "港灣", "灰燼", "柳", "燈塔", "浮流", "羽筆", "黑貂",
        ],
        "premade": [
            "振宇二號", "超級堅固大龍蝦", "神奇人", "桶神", "黃泉 (不是本人)",
            "小小世界", "以愛與恨之名", "莊嚴哀悼", "派翠西亞·斯特爾諾", "諾薇亞",
            "Maximizer", "Bernie", "哈密瓜", "哈哈瓜", "蜜瓜瓜", "哈瓜密",
            "蜜瓜哈哈", "磨鞋喬喬", "人類太可惡", "Agent",
            "去澳洲留學兩年半發現物價太貴", "事件視界", "芋園柚子", "巢狀意識 A031",
            "水熊",
        ],
    },
}
# 舊名稱保留給測試與外部引用：英文組合池與中文預製名單
_ADJECTIVES = _POOLS["en"]["adjectives"]
_NOUNS = _POOLS["en"]["nouns"]
_PREMADE_NAMES = _POOLS["zh"]["premade"]

# 群組標籤的名字，房內成員不得使用。
#
# preferred_name 是自由字串，所以房裡真的可以有成員叫 `all`——而 `@all` 的
# 語意會被他劫持，在有人取那個名字之前完全看不出來。守在命名層是唯一擋得住
# 的地方：展開層只看得到「這個名字對應到一個人」，那時已經分不出他是成員
# 還是群組。
RESERVED_NAMES = frozenset({"all", "agents", "humans"})


def _pool_for(locale: str | None) -> dict[str, list[str]]:
    """依語言挑名字池。

    只看開頭是不是 `zh`：`zh-TW`、`zh_CN`、`zh` 都拿中文池，未知值（含空
    字串）退回英文池——英文組合永遠組得出名字，不必維護名單。
    """
    if (locale or "").strip().lower().startswith("zh"):
        return _POOLS["zh"]
    return _POOLS["en"]


def _draw(pool: dict[str, list[str]]) -> str:
    """從一組名字池抽一個候選：組合與預製各半，缺哪種就抽另一種。"""
    combo = pool["adjectives"] and pool["nouns"]
    premade = pool["premade"]
    if premade and (not combo or random.random() < 0.5):
        return random.choice(premade)
    return f"{random.choice(pool['adjectives'])}-{random.choice(pool['nouns'])}"


def generate_name(
    taken: set[str], preferred: str | None = None, locale: str = "zh-TW"
) -> str:
    """回傳一個不在 taken 中、也不是保留字的顯示名稱。

    preferred 有值時優先使用；衝突則加 -2、-3… 後綴。
    無 preferred 時依 locale 從對應的名字池取，池子撞滿了就退回加後綴。
    """
    # 保留字比照「已被使用」處理——撞到就走加後綴那條路（all → all-2），
    # 拒絕加入太粗暴：那會讓一個只是取錯名字的 agent 進不了房間
    taken = {*taken, *RESERVED_NAMES}
    if preferred:
        preferred = preferred.strip()[:32]
        # 比對 casefold：群組展開本身不分大小寫，命名這邊只擋原字面的話，
        # 取名 `All` 照樣劫持得到 `@all`
        if preferred.casefold() in RESERVED_NAMES:
            preferred = f"{preferred}-2"
    if preferred and preferred not in taken:
        return preferred
    if preferred:
        for i in range(2, 100):
            candidate = f"{preferred}-{i}"
            if candidate not in taken:
                return candidate

    pool = _pool_for(locale)
    for _ in range(64):
        candidate = _draw(pool)
        if candidate not in taken:
            return candidate
    base = _draw(pool)
    i = 2
    while f"{base}-{i}" in taken:
        i += 1
    return f"{base}-{i}"
