"""房內唯一命名——偏好名稱優先，衝突加序號，未指定則從名字池發放。"""

import random

# 名字池：中性、好唸、跟 agent 種類無關
_ADJECTIVES = [
    "Swift", "Quiet", "Bright", "Amber", "Cobalt", "Ivory", "Crimson", "Silver",
    "Nimble", "Steady", "Vivid", "Mellow", "Astral", "Lucid", "Ember", "Frost",
]
_NOUNS = [
    "Falcon", "Otter", "Lynx", "Heron", "Fox", "Raven", "Wren", "Badger",
    "Comet", "Harbor", "Cinder", "Willow", "Beacon", "Drift", "Quill", "Sable",
]


def generate_name(taken: set[str], preferred: str | None = None) -> str:
    """回傳一個不在 taken 中的顯示名稱。

    preferred 有值時優先使用；衝突則加 -2、-3… 後綴。
    無 preferred 時從名字池隨機組合，池子撞滿了就退回加後綴。
    """
    if preferred:
        preferred = preferred.strip()[:32]
    if preferred and preferred not in taken:
        return preferred
    if preferred:
        for i in range(2, 100):
            candidate = f"{preferred}-{i}"
            if candidate not in taken:
                return candidate

    for _ in range(64):
        candidate = f"{random.choice(_ADJECTIVES)}-{random.choice(_NOUNS)}"
        if candidate not in taken:
            return candidate
    base = f"{random.choice(_ADJECTIVES)}-{random.choice(_NOUNS)}"
    i = 2
    while f"{base}-{i}" in taken:
        i += 1
    return f"{base}-{i}"
