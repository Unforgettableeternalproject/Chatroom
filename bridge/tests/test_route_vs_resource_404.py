"""端點不存在 ≠ 資源不存在——兩種 404 要講成兩件事。

## 缺陷（既有，非 Board V2 造成）

v2 的工具打到還沒升級的 Hub 時：

    chatroom_boards()  →  ok:false  「Hub 找不到對應資源（Not Found）。」

不是靜默失效——它有報錯，這點是對的。**但歸因錯了，而歸因決定 agent 的
下一步**：

===================  ==========================================
它聽到的             它會做的
===================  ==========================================
找不到對應資源       查 id、重試、換 id ⇒ **永遠不會成功**
這個 Hub 沒有這個端點 改走 room_id，或回報要升級 ⇒ 有出路
===================  ==========================================

## 兩種 404 本來就分得出來

同一台 Hub 實測（@測試Novia 2026-09-02）::

    端點不存在  404  {"detail": "Not Found"}                 ← 路由層，純字串、無 code
    資源不存在  404  {"detail": {"code": "room_not_found"}}   ← Hub 自己的，帶 code

`hub.py` 檔頭的契約已經寫明「以 code 為準，字串比對是對舊版 Hub 的退路」。
**資訊是夠的，只是 404 的 fallback 沒用上。**

⚠️ 判準要**同時**滿足「無 code」與「detail 恰好是 FastAPI 那句 Not Found」。
只看無 code 的話，舊版 Hub 回純字串的資源錯誤會被誤判成端點不存在——
那是把一個錯誤的歸因換成另一個。
"""

import pytest

from chatroom_mcp.hub import translate_status


def _reason(detail) -> str:
    return translate_status(404, detail, "http://hub.test").reason


def test_route_level_404_says_the_endpoint_is_missing():
    """FastAPI 路由層的 404：純字串 "Not Found"，沒有 code。"""
    reason = _reason("Not Found")
    assert "端點" in reason or "版本" in reason or "升級" in reason, (
        f"端點不存在被講成資源不存在，agent 會去查 id 而不是去升級：{reason!r}"
    )


def test_resource_404_still_says_resource(  ):
    """帶 code 的資源 404 不受影響——修這條不能誤傷那條。"""
    reason = _reason({"code": "room_not_found", "message": "找不到房間"})
    assert "聊天室" in reason


@pytest.mark.parametrize("detail", [
    {"code": "board_not_found", "message": "找不到板"},
    "board not found",
])
def test_unknown_resource_404_is_not_mistaken_for_a_missing_endpoint(detail):
    """舊版 Hub 的純字串資源錯誤**不是**路由層 404。

    只用「沒有 code」當判準的話這條會紅——那等於把誤判從一邊換到另一邊。
    """
    reason = _reason(detail)
    assert "端點" not in reason, (
        f"資源不存在被誤判成端點不存在：{reason!r}"
    )
