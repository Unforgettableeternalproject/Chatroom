"""未攔截例外的處置（H16）。

存在的理由是一次真實的追查成本：2026-09-03 追 D9（零掛接房建卡 500）時，
走 HTTP 只看得到「500」三個字，`hub.jsonl` 裡什麼都沒有——traceback 只有
在 in-process、且 `raise_app_exceptions=True` 的測試環境才拿得到。同一天
這個形狀擋了三次。

所以未攔截例外要做兩件事：

1. **落檔**：帶 traceback 與 `error_id` 寫進 `hub.jsonl`
2. **回應帶得走**：500 的 body 要有那個 `error_id`

`error_id` 是這兩者之間唯一的橋。回報的人只要抄一個短字串，追查的人就能
直接 grep 到那一則——不必問「你幾點打的」「打的是哪個端點」。
"""

import json

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"


async def _client(tmp_path, name):
    """⚠️ `raise_app_exceptions=False`——要驗的正是「HTTP 那一端看到什麼」。

    預設值 True 會讓例外穿過 transport 直接炸在測試裡，那量到的是測試環境
    的特權，不是回報問題的人手上的東西。
    """
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT,
                 log_dir=str(tmp_path / "logs"))
    app = create_app(cfg)

    @app.get("/api/_boom")
    async def _boom():
        raise ZeroDivisionError("測試用：這裡故意炸")

    return app, cfg, AsyncClient(
        transport=ASGITransport(app=app, raise_app_exceptions=False),
        base_url="http://test", headers={"Authorization": f"Bearer {ROOT}"})


async def test_an_unhandled_exception_answers_with_a_traceable_error_id(tmp_path):
    """未攔截例外回 500 `internal_error`，body 帶 `error_id`。"""
    app, _cfg, client = await _client(tmp_path, "boom_body")
    async with client:
        async with app.router.lifespan_context(app):
            r = await client.get("/api/_boom")

    assert r.status_code == 500
    detail = r.json()["detail"]
    assert detail["code"] == "internal_error"
    # 訊息給人看，但要說得出「拿這個 id 去找」，否則回報者不知道該抄什麼
    assert detail["error_id"]
    # 🚨 例外內容不外流：訊息裡可能有路徑、SQL、參數值
    assert "ZeroDivisionError" not in r.text
    assert "故意炸" not in r.text


async def test_the_traceback_lands_in_the_log_under_that_same_error_id(tmp_path):
    """同一個 `error_id` 在 `hub.jsonl` 裡查得到，而且帶 traceback。

    這條才是 H16 真正要買的東西——回應帶得走一個 id，日誌那頭找得回現場。
    """
    app, cfg, client = await _client(tmp_path, "boom_log")
    async with client:
        async with app.router.lifespan_context(app):
            r = await client.get("/api/_boom")
    error_id = r.json()["detail"]["error_id"]

    lines = (tmp_path / "logs" / "hub.jsonl").read_text(encoding="utf-8").splitlines()
    hit = [json.loads(x) for x in lines if error_id in x]
    assert len(hit) == 1, f"error_id {error_id} 在日誌裡找不到（或不只一筆）"
    row = hit[0]
    assert row["level"] == "ERROR"
    assert row["event"] == "unhandled_exception"
    assert row["path"] == "/api/_boom"
    assert row["method"] == "GET"
    assert "ZeroDivisionError" in row["exception"]


async def test_a_deliberate_http_error_is_not_touched(tmp_path):
    """明確拒絕（`_err`）不走這條路——它的 `code` 是契約，不能被蓋成
    `internal_error`。"""
    app, _cfg, client = await _client(tmp_path, "boom_4xx")
    async with client:
        async with app.router.lifespan_context(app):
            r = await client.get("/api/rooms/沒有這個房")

    assert r.status_code == 404
    assert r.json()["detail"]["code"] != "internal_error"
