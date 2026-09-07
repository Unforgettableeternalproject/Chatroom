"""Hub 啟動時偵測重複路由（09/07 卡 7e022378）。

09/07 三次事故的框架層防護。**FastAPI 對重複路由不報錯，先註冊的贏**——
我照裁決加了 `DELETE /api/boards/{id}` 與 `PATCH /api/boards/{id}`，兩支都與
既有端點撞同一條路由，於是既有實作連同它的權限判斷、事件紀錄、通知路徑被
靜默替換掉。

**而全套測試照樣綠**：既有測試打的是同一條路徑，只是接的人換了。發現它的
方式是一條不相干的稽核串測試紅了（它期待 `board_updated`，拿到
`board_renamed`）——那時已經走很遠。

所以這條防的不是「多寫了一支端點」（那只是浪費），是**替換本身**。
"""

import pytest

from chatroom_server.app import assert_no_duplicate_routes, create_app
from chatroom_server.config import Config


def test_the_hub_itself_has_no_duplicate_routes(tmp_path):
    """真正的防護在 `create_app` 裡——這條只是讓失敗訊息指得回這裡。"""
    create_app(Config(db_path=str(tmp_path / "routes.db"), api_token="x"))


def test_a_duplicate_route_is_refused_at_startup(tmp_path):
    """把重複造出來，確認它真的會炸。

    ⚠️ 不用 `create_app` 造重複（那要先寫一支重複端點進正式程式碼）。這裡
    直接對一個裝了兩支同路由的 app 呼叫檢查——驗的是檢查本身。
    """
    from fastapi import FastAPI

    app = FastAPI()

    @app.get("/api/thing")
    async def _first():
        return {}

    @app.get("/api/thing")
    async def _second():
        return {}

    with pytest.raises(RuntimeError) as err:
        assert_no_duplicate_routes(app)
    msg = str(err.value)
    # **訊息要指得出是誰撞誰**：只說「有重複」的話，一支 400 行的
    # `create_app` 裡要自己找兩支同名路由
    assert "GET /api/thing" in msg
    assert "_first" in msg and "_second" in msg


def test_different_methods_on_the_same_path_are_fine(tmp_path):
    """同一條路徑上的不同動詞是正常設計，不能被這道檢查擋下。"""
    from fastapi import FastAPI

    app = FastAPI()

    @app.get("/api/thing")
    async def _read():
        return {}

    @app.delete("/api/thing")
    async def _remove():
        return {}

    assert_no_duplicate_routes(app)
