"""週期（objective）重排：母體含非 active 的週期時的行為。

`_assert_reorder_writable` 曾對 kind=objective 的每個週期用自己的 status
檢查，板上只要有一個週期不是 active（review、done...），整批週期重排就 409。
Flutter 的 `_reorderPartial` 送的是完整母體，一定會撞到。
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
    """建房、加入 agent，板上 3 個週期；第一個帶完成的階段與卡，可送審。"""
    rid = (await client.post("/api/rooms", json={
        "name": "房", "session_key": "agent-1"})).json()["id"]
    j = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "claude", "role": "agent", "session_key": "agent-1",
        "preferred_name": "A"})
    hdr = {"X-Participant-Id": j.json()["participant_id"]}
    oids = [(await client.post(f"/api/rooms/{rid}/board/objectives",
                               json={"title": f"週期{n}"},
                               headers=hdr)).json()["id"] for n in (1, 2, 3)]
    bid = (await client.get(f"/api/rooms/{rid}/board",
                            headers=hdr)).json()["board_id"]
    cid = (await client.post(f"/api/board/objectives/{oids[0]}/checklists",
                             json={"title": "階段"}, headers=hdr)).json()["id"]
    tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                             json={"title": "卡"}, headers=hdr)).json()["id"]
    for st in ("in_progress", "done"):
        r = await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": st}, headers=hdr)
        assert r.status_code == 200, r.text
    r = await client.post(f"/api/board/checklists/{cid}/status",
                          json={"status": "done"}, headers=hdr)
    assert r.status_code == 200, r.text
    return rid, bid, oids, hdr


def _items(ids):
    return {"kind": "objective",
            "items": [{"id": i, "order_index": n} for n, i in enumerate(ids)]}


def _paths(rid, bid):
    return (f"/api/rooms/{rid}/board/reorder", f"/api/boards/{bid}/reorder")


async def test_all_active_objectives_reorder_ok(tmp_path):
    """對照組：全 active 時重排成功（沒有這條，「一律拒絕」也會讓下面通過）。"""
    app, client = await _client(tmp_path, "allactive")
    async with app.router.lifespan_context(app), client:
        rid, bid, oids, hdr = await _setup(client)
        for path in _paths(rid, bid):
            r = await client.post(path, json=_items(list(reversed(oids))),
                                  headers=hdr)
            assert r.status_code == 200, (path, r.status_code, r.text)


@pytest.mark.parametrize("which", [0, 1])
async def test_full_objective_reorder_with_a_review_objective(tmp_path, which):
    """3 個週期、其中一個在 review，送含全部 3 個的重排——期望成功。"""
    app, client = await _client(tmp_path, f"review{which}")
    async with app.router.lifespan_context(app), client:
        rid, bid, oids, hdr = await _setup(client)
        r = await client.post(f"/api/board/objectives/{oids[0]}/review",
                              headers=hdr)
        assert r.status_code == 200, r.text
        obj = [o for o in (await client.get(
            f"/api/rooms/{rid}/board", headers=hdr)).json()["objectives"]
            if o["id"] == oids[0]][0]
        assert obj["status"] == "review"

        path = _paths(rid, bid)[which]
        r = await client.post(path, json=_items(list(reversed(oids))),
                              headers=hdr)
        assert r.status_code == 200, (path, r.status_code, r.text)
        order = sorted((await client.get(
            f"/api/rooms/{rid}/board", headers=hdr)).json()["objectives"],
            key=lambda o: o["order_index"])
        assert [o["id"] for o in order] == list(reversed(oids))
