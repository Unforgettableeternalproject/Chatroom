"""bridge 永遠不送 `X-Host-View`（09/07 卡 d1141898，決策裁 #16-2）。

Hub 那一側已經只認人類憑證，所以這裡擋的不是權限，是**形狀**：bridge 沒有
任何理由要求主持人視角，而「沒有人寫過送它的程式碼」與「它不可能被送出去」
是兩件事——前者靠的是每個改 header 的人都記得，後者靠這條測試。

（agent 借主持人身分提權的實際風險見 `tests/test_human_agent_tokens.py`。）
"""

import os
from unittest import mock

from chatroom_mcp.hub import HubClient


def _all_headers(client: HubClient) -> dict[str, str]:
    """把 `_headers` 的每一條分支都走一遍，合起來看。"""
    merged: dict[str, str] = {}
    for pid, key in ((None, None), ("p-1", None), (None, "claude-1"),
                     ("p-1", "claude-1")):
        merged.update(client._headers(pid, key))
    return merged


def test_the_bridge_never_asks_for_host_view():
    client = HubClient(base_url="http://hub", token="agent-token")
    assert not any(h.lower() == "x-host-view" for h in _all_headers(client))


def test_the_environment_cannot_inject_it_either():
    """設定一律走環境變數，所以「環境裡放得進去」是這個專案真實的形狀。

    ⚠️ 這條**不是**在測 httpx——它釘的是「bridge 讀環境變數的清單裡沒有
    主持人視角這一項」。哪天有人加了一個 pass-through 的 header 機制，
    這裡會先紅。
    """
    with mock.patch.dict(os.environ, {
            "CHATROOM_HOST_VIEW": "1", "X_HOST_VIEW": "1",
            "CHATROOM_HEADERS": "X-Host-View: 1"}):
        client = HubClient(base_url="http://hub", token="agent-token")
        assert not any(h.lower() == "x-host-view" for h in _all_headers(client))
