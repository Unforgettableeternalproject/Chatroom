"""`GET /api/ops/active-runs`：停 Hub 之前的「還有沒有進行中的 run」。

守的不變式：只算 agent_run 的 queued／claimed／running／limited；收場狀態與
handoff（那一棒已結束）不能混進來，否則 Hub 永遠被判忙碌；沒有憑證要拒絕。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"


async def _client(tmp_path):
    app = create_app(Config(db_path=str(tmp_path / "t.db"), api_token=ROOT))
    client = AsyncClient(transport=ASGITransport(app=app),
                         base_url="http://test",
                         headers={"Authorization": f"Bearer {ROOT}"})
    client.hub_app = app
    return app, client


async def _seed(client, room_id, statuses):
    db = client.hub_app.state.db
    for i, st in enumerate(statuses):
        await db.execute(
            "INSERT INTO agent_run (id, room_id, kind, ref, status,"
            " created_at, updated_at) VALUES (?,?,?,?,?,?,?)",
            (f"run-{st}-{i}", room_id, "investigate", f"t{i}", st,
             "2026-01-01T00:00:0%d" % i, "2026-01-01"))
    await db.commit()


async def test_counts_only_in_progress_statuses(tmp_path):
    app, client = await _client(tmp_path)
    async with client:
        async with app.router.lifespan_context(app):
            rid = (await client.post("/api/rooms", json={
                "name": "r", "session_key": "k"})).json()["id"]
            await _seed(client, rid, [
                "queued", "claimed", "running", "limited",
                "done", "failed", "cancelled", "handoff"])
            r = await client.get("/api/ops/active-runs")
            assert r.status_code == 200, r.text
            body = r.json()
            assert body["count"] == 4
            assert body["counts"] == {"queued": 1, "claimed": 1,
                                      "running": 1, "limited": 1}
            assert {x["status"] for x in body["runs"]} == {
                "queued", "claimed", "running", "limited"}
            assert all(x["room_id"] == rid for x in body["runs"])


async def test_empty_when_nothing_in_progress(tmp_path):
    app, client = await _client(tmp_path)
    async with client:
        async with app.router.lifespan_context(app):
            rid = (await client.post("/api/rooms", json={
                "name": "r", "session_key": "k"})).json()["id"]
            await _seed(client, rid, ["done", "handoff"])
            body = (await client.get("/api/ops/active-runs")).json()
            assert body["count"] == 0 and body["runs"] == []


async def test_spans_all_rooms_including_private(tmp_path):
    app, client = await _client(tmp_path)
    async with client:
        async with app.router.lifespan_context(app):
            a = (await client.post("/api/rooms", json={
                "name": "a", "session_key": "k1"})).json()["id"]
            b = (await client.post("/api/rooms", json={
                "name": "b", "session_key": "k2",
                "visibility": "private"})).json()["id"]
            await _seed(client, a, ["running"])
            await _seed(client, b, ["queued"])
            body = (await client.get("/api/ops/active-runs")).json()
            assert body["count"] == 2
            assert {x["room_id"] for x in body["runs"]} == {a, b}


async def test_unauthenticated_is_rejected(tmp_path):
    app, client = await _client(tmp_path)
    async with client:
        async with app.router.lifespan_context(app):
            r = await client.get("/api/ops/active-runs",
                                 headers={"Authorization": "Bearer nope"})
            assert r.status_code == 401
            r = await AsyncClient(
                transport=ASGITransport(app=app), base_url="http://test"
            ).get("/api/ops/active-runs")
            assert r.status_code == 401
