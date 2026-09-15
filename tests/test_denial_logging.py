"""拒絕也要留痕（H16 的 4xx 半邊）。

2026-09-05 幫跨裝置測試端對一筆 403 的帳時發現：`hub.jsonl` 裡**什麼都沒有**。
`_err` 拋的 `HTTPException` 不落日誌（只有 401 `auth_failed` 會寫），唯一的痕跡
是 uvicorn access log 的一行「403」——而那一行說不出**誰**被拒、**為什麼**。

403 恰恰是最需要追的那種：它代表**有人以為自己有權限**。而追查的人手上通常
只有「我打了這個端點，它說我不行」。

範疇刻意只有 403 與 404：
- 401 已經有 `auth_failed`
- 422 是參數驗證，訊息本身就說得出哪個欄位錯，記了只會把日誌灌滿
- 5xx 由 H16 的 `unhandled_exception` 收
"""

import json

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"


async def _client(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT,
                 log_dir=str(tmp_path / "logs"))
    app = create_app(cfg)
    return app, cfg, AsyncClient(transport=ASGITransport(app=app),
                                 base_url="http://test",
                                 headers={"Authorization": f"Bearer {ROOT}"})


def _lines(tmp_path):
    path = tmp_path / "logs" / "hub.jsonl"
    if not path.exists():
        return []
    return [json.loads(x) for x in
            path.read_text(encoding="utf-8").splitlines() if x.strip()]


def _denials(tmp_path):
    return [r for r in _lines(tmp_path) if r.get("event") == "request_denied"]


async def test_a_404_says_who_asked_and_which_rule_refused(tmp_path):
    """404 落檔，而且帶得出「誰問的」與「哪一條判準拒絕的」。

    只記狀態碼等於沒補——追查的人本來就從 access log 知道是 404。
    """
    app, _cfg, client = await _client(tmp_path, "deny_404")
    async with client:
        async with app.router.lifespan_context(app):
            r = await client.get("/api/rooms/沒有這個房",
                                 headers={"X-Session-Key": "claude-asker"})
    assert r.status_code == 404

    hit = _denials(tmp_path)
    assert len(hit) == 1, f"日誌裡的拒絕筆數不對：{hit}"
    row = hit[0]
    assert row["status"] == 404
    # `code` 就是判準來源——它是穩定契約，比 message 可靠
    assert row["code"] == "room_not_found"
    assert row["path"] == "/api/rooms/沒有這個房"
    assert row["method"] == "GET"
    assert row["session_key"] == "claude-asker"


async def test_a_403_lands_with_the_rule_that_refused_it(tmp_path):
    """403 是最需要留痕的：它代表有人**以為**自己有權限。"""
    app, _cfg, client = await _client(tmp_path, "deny_403")
    async with client:
        async with app.router.lifespan_context(app):
            key = {"X-Session-Key": "claude-owner"}
            bid = (await client.post("/api/boards", json={"name": "別人的板"},
                                     headers=key)).json()["id"]
            # 局外人讀一塊他沒份的板
            r = await client.get(f"/api/boards/{bid}",
                                 headers={"X-Session-Key": "claude-outsider"})
    assert r.status_code == 403

    hit = _denials(tmp_path)
    assert len(hit) == 1, f"日誌裡的拒絕筆數不對：{hit}"
    row = hit[0]
    assert row["status"] == 403
    assert row["code"] == "not_board_member"
    assert row["session_key"] == "claude-outsider"


async def test_the_response_itself_is_unchanged(tmp_path):
    """落檔不能改回應——`detail` 的形狀是 client 依賴的契約。"""
    app, _cfg, client = await _client(tmp_path, "deny_shape")
    async with client:
        async with app.router.lifespan_context(app):
            r = await client.get("/api/rooms/沒有這個房")
    assert r.status_code == 404
    detail = r.json()["detail"]
    assert detail["code"] == "room_not_found"
    assert detail["message"]


async def test_validation_errors_are_not_logged(tmp_path):
    """422 不記——它自證（訊息裡就有哪個欄位錯），記了只會把日誌灌滿。"""
    app, _cfg, client = await _client(tmp_path, "deny_422")
    async with client:
        async with app.router.lifespan_context(app):
            r = await client.post("/api/rooms", json={})
    assert r.status_code == 422
    assert _denials(tmp_path) == []
