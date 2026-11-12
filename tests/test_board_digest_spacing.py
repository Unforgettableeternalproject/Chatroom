"""Supervisor 摘要的間隔從第一筆未送的變動起算。

舊規則從上次摘要起算：安靜一段時間後，下一筆零星變動會在一輪 sweep 內
單獨送出，摘要就變成一兩筆一則，等於洗版。
"""

from datetime import timedelta

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"


async def _setup(tmp_path, name, **kw):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT,
                 sweep_interval=3600, **kw)
    app = create_app(cfg)
    client = AsyncClient(transport=ASGITransport(app=app), base_url="http://test",
                         headers={"Authorization": f"Bearer {ROOT}"})
    return app, client


async def _room_with_supervisor(client):
    rid = (await client.post("/api/rooms", json={
        "name": "板子房", "session_key": "human-1"})).json()["id"]
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "human", "role": "human", "session_key": "human-1",
        "preferred_name": "Bernie"})
    owner = {"X-Participant-Id": r.json()["participant_id"]}
    await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "claude", "role": "agent", "session_key": "agent-sup",
        "preferred_name": "Nova"})
    await client.post(f"/api/rooms/{rid}/board/supervisor",
                      json={"session_key": "agent-sup"}, headers=owner)
    return rid, owner


async def _digests(client, rid, hdr):
    msgs = (await client.get(f"/api/rooms/{rid}/messages",
                             headers=hdr)).json()["messages"]
    return [m for m in msgs if m["system_event"] == "board_digest"]


async def test_lone_change_waits_instead_of_sending_at_once(tmp_path):
    app, client = await _setup(tmp_path, "lone", board_digest_interval=900.0)
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room_with_supervisor(client)
        # 上次摘要是一小時前：安靜很久之後的第一筆變動
        db = app.state.db
        await db.execute("UPDATE room SET board_digest_at=? WHERE id=?",
                         ("2000-01-01T00:00:00+00:00", rid))
        await db.commit()
        await client.post(f"/api/rooms/{rid}/board/objectives",
                          json={"title": "週期一"}, headers=owner)
        # 舊規則從上次摘要起算，這裡會單獨送出一則
        await app.state.sweep_once()
        assert await _digests(client, rid, owner) == []

        await client.post(f"/api/rooms/{rid}/board/objectives",
                          json={"title": "週期二"}, headers=owner)
        # 第一筆未送的變動已等滿間隔 → 兩筆收成一則
        pending = app.state.board_digest_pending_since
        pending[rid] = pending[rid] - timedelta(seconds=901)
        await app.state.sweep_once()
        (digest,) = await _digests(client, rid, owner)
        assert "週期 2 項" in digest["content"]
        assert rid not in pending


async def test_full_batch_sends_without_waiting(tmp_path):
    app, client = await _setup(tmp_path, "full", board_digest_interval=900.0,
                               board_digest_max=3)
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room_with_supervisor(client)
        for i in range(3):
            await client.post(f"/api/rooms/{rid}/board/objectives",
                              json={"title": f"週期{i}"}, headers=owner)
        await app.state.sweep_once()
        assert len(await _digests(client, rid, owner)) == 1
