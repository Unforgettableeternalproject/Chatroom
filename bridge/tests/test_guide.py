"""內建使用手冊。

手冊要對所有 MCP client 有效——Codex 讀不到 Claude Code 的 skill，卻同樣會
把 mention 漏掉。工具是這些 client 唯一共同的載體。
"""

from pathlib import Path

from chatroom_mcp import server as srv
from chatroom_mcp.guide import GUIDE

# repo 根目錄：bridge/tests/test_guide.py → 上溯兩層
_DOC = Path(__file__).resolve().parents[2] / "docs" / "CHATROOM.md"


def test_guide_returns_the_manual():
    result = srv.chatroom_guide()
    assert result["ok"] is True
    assert result["guide"] == GUIDE


def test_guide_covers_the_things_that_fail_silently():
    """手冊的價值在於「猜錯又不會報錯」的那幾件事，缺一件就等於沒寫。"""
    for topic in (
        "chatroom_wait",          # 等待不要用輪詢
        "unresolved_mentions",    # 對著空氣說話
        "回覆本身就等於 mention",  # reply = mention
        "room_is_private",        # 私人房進不去不是壞掉
        "need_rejoin",            # 身分失效的處置
        "pinned_only",            # 釘選是給未來的讀者看的
        "chatroom_ask_human",     # 卡住要問人，不要自己猜
    ):
        assert topic in GUIDE, f"手冊沒有涵蓋：{topic}"


def test_guide_is_not_in_every_tool_listing():
    """手冊本體不該塞進 docstring——那會佔用每一次對話的上下文。"""
    assert len(srv.chatroom_guide.__doc__ or "") < 400
    assert len(GUIDE) > 2000


def test_doc_matches_the_packaged_guide():
    """docs/CHATROOM.md 是 GUIDE 的逐字副本，不能漂移。

    兩份存在的理由不同：bridge 是獨立安裝的套件，執行時讀不到 repo 的
    docs/，所以必須帶著自己的副本；而人要讀、要拿去包成 skill 的是檔案。
    真相在 guide.py——改了那裡就要把 GUIDE 寫回 docs/CHATROOM.md。

    不比對就會出現最糟的那種情況：兩份都看起來像官方說明，內容卻不一樣，
    而沒有任何地方會告訴你該信哪一份。
    """
    assert _DOC.is_file(), f"找不到 {_DOC}"
    assert _DOC.read_text(encoding="utf-8") == GUIDE, (
        "docs/CHATROOM.md 與 guide.py 的 GUIDE 不一致。"
        "改 guide.py 之後要把 GUIDE 原樣寫回 docs/CHATROOM.md。"
    )


def test_doc_is_a_bare_manual():
    """那份檔案要能直接被包成 skill，所以不放任何前言或產生器註解。"""
    assert _DOC.read_text(encoding="utf-8").startswith("# Chatroom 使用手冊")
