"""排序必須是同一層底下、完整且唯一的一份順序。

只驗「這些 id 存在」的話，三種壞掉的請求都會拿到 200
（審核用Codex-2 2026-09-03 實測；@測試Novia T18 的黑箱版同形）：

    重複 id      同一張卡被寫兩次，中間那個位置空著
    子集合      沒送到的保留舊 order_index，與新的 0、1、2 直接重疊
    混不同 parent 排序的母體是「同層 siblings」，跨 parent 的順序不完整

⚠️ 三者的共通點是**畫面上看得到、API 說成功**——那是今天講了一整天的形狀。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"


async def _client(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


async def _setup(client):
    rid = (await client.post("/api/rooms", json={
        "name": "房", "session_key": "claude-a"})).json()["id"]
    j = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "human", "role": "human", "session_key": "claude-a",
        "preferred_name": "A"})
    hdr = {"X-Participant-Id": j.json()["participant_id"],
           "X-Session-Key": "claude-a"}
    oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                             json={"title": "週期"}, headers=hdr)).json()["id"]
    bid = (await client.get(f"/api/rooms/{rid}/board",
                            headers=hdr)).json()["board_id"]
    cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                             json={"title": "階段"}, headers=hdr)).json()["id"]
    tasks = [(await client.post(f"/api/board/checklists/{cid}/tasks",
                                json={"title": f"卡{n}"},
                                headers=hdr)).json()["id"] for n in (1, 2, 3)]
    return rid, bid, cid, oid, tasks, hdr


def _items(ids):
    return {"kind": "task",
            "items": [{"id": i, "order_index": n} for n, i in enumerate(ids)]}


async def test_a_full_and_unique_order_is_accepted(tmp_path):
    """正向對照。**沒有這條的話，「一律拒絕」也會讓底下三條通過。**"""
    app, client = await _client(tmp_path, "ok")
    async with client:
        async with app.router.lifespan_context(app):
            rid, bid, cid, oid, tasks, hdr = await _setup(client)
            for path, headers in ((f"/api/boards/{bid}/reorder", hdr),
                                  (f"/api/rooms/{rid}/board/reorder", hdr)):
                r = await client.post(path, json=_items(list(reversed(tasks))),
                                      headers=headers)
                assert r.status_code == 200, r.json()


async def test_a_duplicate_id_is_refused(tmp_path):
    app, client = await _client(tmp_path, "dup")
    async with client:
        async with app.router.lifespan_context(app):
            rid, bid, cid, oid, tasks, hdr = await _setup(client)
            for path in (f"/api/boards/{bid}/reorder",
                         f"/api/rooms/{rid}/board/reorder"):
                r = await client.post(
                    path, json=_items([tasks[0], tasks[0], tasks[1]]),
                    headers=hdr)
                assert r.status_code == 400
                assert r.json()["detail"]["code"] == "reorder_duplicate_item"


async def test_a_subset_is_refused_because_the_rest_would_collide(tmp_path):
    """**這條是三者裡最容易漏的**：少送的那些保留舊的 `order_index`，與新的
    0、1、2 重疊——畫面上兩張卡搶同一個位置，而 API 回 200。
    """
    app, client = await _client(tmp_path, "subset")
    async with client:
        async with app.router.lifespan_context(app):
            rid, bid, cid, oid, tasks, hdr = await _setup(client)
            for path in (f"/api/boards/{bid}/reorder",
                         f"/api/rooms/{rid}/board/reorder"):
                r = await client.post(path, json=_items(tasks[:2]),
                                      headers=hdr)
                assert r.status_code == 409
                assert r.json()["detail"]["code"] == "reorder_incomplete"
                assert tasks[2] in r.json()["detail"]["missing"], (
                    "要說出漏了哪些，不然 client 只能整份重讀去比對")


async def test_mixing_two_parents_is_refused(tmp_path):
    """母體是「同層 siblings」：跨 parent 的一份順序在任何一邊看都不完整。"""
    app, client = await _client(tmp_path, "mixed")
    async with client:
        async with app.router.lifespan_context(app):
            rid, bid, cid, oid, tasks, hdr = await _setup(client)
            other = (await client.post(
                f"/api/board/objectives/{oid}/checklists",
                json={"title": "另一階段"}, headers=hdr)).json()["id"]
            far = (await client.post(f"/api/board/checklists/{other}/tasks",
                                     json={"title": "別層的卡"},
                                     headers=hdr)).json()["id"]
            r = await client.post(f"/api/boards/{bid}/reorder",
                                  json=_items([*tasks, far]), headers=hdr)
            assert r.status_code == 409
            assert r.json()["detail"]["code"] == "reorder_mixed_parents"


async def test_an_unknown_id_still_says_which_ones(tmp_path):
    """既有行為不能因為加了新守門就變掉——它先於另外三條被檢查。"""
    app, client = await _client(tmp_path, "unknown")
    async with client:
        async with app.router.lifespan_context(app):
            rid, bid, cid, oid, tasks, hdr = await _setup(client)
            r = await client.post(f"/api/boards/{bid}/reorder",
                                  json=_items([*tasks, "沒這張"]), headers=hdr)
            assert r.status_code == 404
            assert r.json()["detail"]["code"] == "board_item_not_found"
            assert r.json()["detail"]["missing"] == ["沒這張"]
