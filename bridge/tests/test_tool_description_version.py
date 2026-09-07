"""每一支工具的描述都要說得出自己是哪一版 bridge。

2026-09-07 測試端的實錄：他憑記憶斷定自己手上的 kit 是舊版，害開發端差點
白打一包——而他當下**沒有任何辦法**知道自己讀的工具描述是哪一份。版本在
`initialize` 交握裡有、在 `/api/health` 有，但那兩個地方都不是 agent 讀描述
的那一刻看得到的。

三個判準（測試端定的，因為受害者是他）：

1. **版本要在描述本身**——不是回應欄位、不是 health。agent 讀描述時不會
   先去打一支 API。
2. **標的是 bridge 的 build，不是 Hub 的**——兩者天天不一樣（那天 bridge
   `c4c4960`、測試 Hub `8e3933c`）。搞混等於這張卡沒做。
3. **每一支都要帶**——放一支「版本查詢工具」不算：要靠呼叫另一支才知道，
   問題原封不動。

順帶收掉「版號證明不了進程重啟」那個老坑：MCP client 在 bridge 啟動時載入
並快取描述，所以描述裡的版本天然就是**這個進程實際載入的那一份**。
"""

from __future__ import annotations

import asyncio

from chatroom_mcp import server as srv
from chatroom_mcp.version import build_info, version_string


def _tools():
    return asyncio.run(srv.mcp.list_tools())


def test_there_are_tools_to_check():
    """先證明樣本存在。

    底下兩條都是「對每一支工具」的全稱斷言——清單空的時候它們一樣會綠，
    而那種綠什麼都沒保證。
    """
    assert len(_tools()) >= 30


def test_every_tool_description_carries_the_bridge_version():
    version = version_string()
    missing = [t.name for t in _tools() if version not in (t.description or "")]
    assert missing == [], f"這些工具的描述沒有版本：{missing}"


def test_the_version_is_the_bridges_own_build():
    """釘住「標的是 bridge」——不是 Hub、也不是寫死的字串。"""
    info = build_info()
    line = srv.VERSION_LINE
    assert info["version"] in line
    if info["commit"]:
        assert info["commit"] in line
    assert info["source"] in line


def test_the_original_docstring_survives():
    """版本是附加上去的，不是取代描述。

    工具描述是 agent 唯一的說明書，為了塞版本把它洗掉的話，這張卡會用一個
    更大的問題換掉一個小的。
    """
    by_name = {t.name: t for t in _tools()}
    read = by_name["chatroom_read"]
    assert "游標" in (read.description or "")
    assert srv.VERSION_LINE in read.description
