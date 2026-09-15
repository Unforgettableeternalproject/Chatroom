"""build 腳本要驗產物，不能只印自己打算做的事。

2026-08-31：`build-app.py` 印出 `✓ 1.1.5+428732709f4f`，而 `app.so` 裡是
`1.0.0`——`--dart-define` 的值沒有進到那份產物（實際成因是另一個不帶 define
的 `flutter build` 蓋掉了它）。build 回報成功、log 漂亮、沒有任何地方報錯，
直到有人去讀畫面右上角看到「COMMIT 未知」。

> 那行 `✓` 印的是**它打算編進去的值**，不是產物裡真的有的東西。

這是文件裡「驗證器本身也需要被驗證」的實例（F15）。
"""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from buildstamp import dart_default_version, verify_embedded  # noqa: E402


def _blob(*parts: str) -> bytes:
    """假的產物：AOT 產物裡那些字串就是以明文出現的。"""
    return b"...binary..." + "".join(parts).encode() + b"...more..."


def test_a_good_build_reports_no_problems():
    problems = verify_embedded(
        _blob("1.1.5", "7bebe8168def"), "1.1.5", "7bebe8168def", "1.0.0")
    assert problems == []


def test_the_fallback_being_present_is_the_strongest_signal():
    """產物裡還有 defaultValue，代表 Dart 端走了「沒有 define」那條路。

    這是實際發生過的那一份的形狀：commit 不在、版本不在、fallback 在。
    """
    problems = verify_embedded(_blob("1.0.0"), "1.1.5", "7bebe8168def", "1.0.0")

    assert len(problems) == 3
    assert any("defaultValue" in p for p in problems)
    assert any("7bebe8168def" in p for p in problems)


def test_a_missing_commit_alone_is_caught():
    """版本對、commit 不見——那份產物對不回任何一顆 commit。"""
    problems = verify_embedded(_blob("1.1.5"), "1.1.5", "deadbeefcafe", "1.0.0")
    assert len(problems) == 1
    assert "deadbeefcafe" in problems[0]


def test_no_commit_is_not_treated_as_a_problem():
    """抓不到 commit 時（不在 git 工作樹）不要再報一次。

    那個情況上游已經 WARNING 過，這裡重複報只會讓人以為是另一件事。
    """
    assert verify_embedded(_blob("1.1.5"), "1.1.5", "", "1.0.0") == []


def test_version_equal_to_fallback_does_not_self_trip():
    """真的要出 1.0.0 版時，不能因為它等於 defaultValue 就報錯。

    邊界看起來很遠，但它會在最不該失敗的時候失敗——而且症狀是
    「build 突然壞了，而我什麼都沒改」。
    """
    assert verify_embedded(_blob("1.0.0", "abc123"), "1.0.0", "abc123",
                           "1.0.0") == []


def test_default_version_is_read_from_the_dart_source(tmp_path):
    """defaultValue 從 Dart 原始碼讀，不硬編。

    硬編一份的話，Dart 那邊改了值，這個檢查就會安靜地失去意義——而它正是
    用來抓「安靜失去意義」的。
    """
    src = tmp_path / "build_info.dart"
    src.write_text(
        "  static const _version = String.fromEnvironment(\n"
        "    'CHATROOM_VERSION',\n"
        "    defaultValue: '9.9.9',\n"
        "  );\n",
        encoding="utf-8",
    )
    assert dart_default_version(src) == "9.9.9"


def test_unreadable_source_degrades_instead_of_exploding(tmp_path):
    """讀不到就回 None，讓那一項檢查跳過——不要讓 build 因為它而掛掉。"""
    assert dart_default_version(tmp_path / "nope.dart") is None
    # None 時只是少一項檢查，其餘照驗
    assert verify_embedded(_blob("1.0.0"), "1.1.5", "abc", None)


def test_the_real_build_info_still_matches_the_pattern():
    """真的那份 build_info.dart 解析得出來。

    上面那些都是假資料——這條防的是「正規表示式與現場漂移了」，而那會讓
    fallback 檢查靜靜地被跳過。
    """
    repo = Path(__file__).resolve().parents[1]
    value = dart_default_version(repo / "app/lib/core/config/build_info.dart")
    assert value, "解析不到 defaultValue：pattern 可能與現場漂移了"
