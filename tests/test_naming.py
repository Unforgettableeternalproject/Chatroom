"""naming.generate_name 的單元測試：偏好名、後綴、名字池與耗盡退路。

⚠️ 名字池的測試一律**明確傳 locale**。混抽時代的斷言（抽一個名字、假設它
長得像 `Adjective-Noun`）是會隨機紅的——同一段程式碼跑一百次才紅一次，
下一個人只會重跑一遍然後當成偶發。
"""

from chatroom_server.naming import (
    _ADJECTIVES, _NOUNS, _POOLS, _PREMADE_NAMES, generate_name)


def _zh_names() -> set[str]:
    zh = _POOLS["zh"]
    return {*zh["premade"],
            *(f"{a}-{n}" for a in zh["adjectives"] for n in zh["nouns"])}


def test_preferred_name_used_when_free():
    assert generate_name(set(), "Nova") == "Nova"


def test_preferred_name_suffixed_when_taken():
    assert generate_name({"Nova"}, "Nova") == "Nova-2"
    assert generate_name({"Nova", "Nova-2"}, "Nova") == "Nova-3"


def test_english_locale_uses_adjective_noun_pool():
    for _ in range(50):
        name = generate_name(set(), locale="en")
        adj, noun = name.split("-")
        assert adj in _ADJECTIVES and noun in _NOUNS


def test_chinese_locale_uses_chinese_pool():
    # 中文池是預製名單＋中文形容詞-名詞組合，兩種都會出現
    seen = {generate_name(set(), locale="zh-TW") for _ in range(200)}
    assert seen <= _zh_names()
    assert seen & set(_PREMADE_NAMES)
    assert seen - set(_PREMADE_NAMES)


def test_unknown_locale_falls_back_to_english_pool():
    # 空字串與看不懂的值都退英文組合——那條路不必維護名單就組得出名字
    for locale in ("", "ja", "xx-YY"):
        for _ in range(20):
            adj, noun = generate_name(set(), locale=locale).split("-")
            assert adj in _ADJECTIVES and noun in _NOUNS


def test_pool_exhaustion_falls_back_to_suffix():
    # 整個名字池都被占用時，仍要能給出唯一名稱
    taken = {f"{a}-{n}" for a in _ADJECTIVES for n in _NOUNS}
    name = generate_name(taken, locale="en")
    assert name not in taken
    assert name.count("-") == 2  # Adjective-Noun-N 後綴形式


def test_chinese_pool_exhaustion_falls_back_to_suffix():
    taken = _zh_names()
    name = generate_name(taken, locale="zh-TW")
    assert name not in taken
    base, _, suffix = name.rpartition("-")
    assert base in taken and suffix.isdigit()


def test_preferred_name_trimmed_to_32_chars():
    name = generate_name(set(), "X" * 100)
    assert len(name) == 32
