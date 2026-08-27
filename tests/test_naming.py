"""naming.generate_name 的單元測試：偏好名、後綴、名字池與耗盡退路。"""

from chatroom_server.naming import _ADJECTIVES, _NOUNS, generate_name


def test_preferred_name_used_when_free():
    assert generate_name(set(), "Nova") == "Nova"


def test_preferred_name_suffixed_when_taken():
    assert generate_name({"Nova"}, "Nova") == "Nova-2"
    assert generate_name({"Nova", "Nova-2"}, "Nova") == "Nova-3"


def test_pool_assignment_without_preference():
    name = generate_name(set())
    adj, noun = name.split("-")
    assert adj in _ADJECTIVES and noun in _NOUNS


def test_pool_exhaustion_falls_back_to_suffix():
    # 整個名字池都被占用時，仍要能給出唯一名稱
    taken = {f"{a}-{n}" for a in _ADJECTIVES for n in _NOUNS}
    name = generate_name(taken)
    assert name not in taken
    assert name.count("-") == 2  # Adjective-Noun-N 後綴形式


def test_preferred_name_trimmed_to_32_chars():
    name = generate_name(set(), "X" * 100)
    assert len(name) == 32
