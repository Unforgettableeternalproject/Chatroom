"""指派候選清單要濾掉已經在房裡的人。

指派的意思是「請一個還沒在場的人進來」。把已經在場的人列進候選，使用者
只會指派他一次然後得到一個什麼都沒發生的結果——join 是冪等的，Hub 不會
報錯，UI 也不會。**清單本身不表態的話，那個錯誤要等到指派送出去才發現。**
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


async def _join(client, rid, session_key, name):
    return await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "claude", "role": "agent", "session_key": session_key,
        "preferred_name": name})


async def _keys(client, **params) -> set[str]:
    q = "&".join(f"{k}={v}" for k, v in params.items())
    r = await client.get(f"/api/sessions?{q}" if q else "/api/sessions")
    return {s["session_key"] for s in r.json()["sessions"]}


async def test_members_of_that_room_are_not_candidates(tmp_path):
    app, client = await _client(tmp_path, "exclude")
    async with app.router.lifespan_context(app), client:
        rid = (await client.post("/api/rooms", json={
            "name": "房", "session_key": "owner"})).json()["id"]
        await _join(client, rid, "agent-in", "已在房內")
        # 讓 Hub 認得另一把 key（查詢指派時會 upsert session 名錄）
        await client.get("/api/assignments?session_key=agent-out&kind=claude")

        assert "agent-in" in await _keys(client)
        assert await _keys(client, exclude_room=rid) == {"agent-out"}


async def test_leaving_puts_them_back_in_the_list(tmp_path):
    """離開之後就該重新指派得到——排除的是「現在在場」不是「來過」。"""
    app, client = await _client(tmp_path, "rejoin")
    async with app.router.lifespan_context(app), client:
        rid = (await client.post("/api/rooms", json={
            "name": "房", "session_key": "owner"})).json()["id"]
        pid = (await _join(client, rid, "agent-1", "Novia")).json()["participant_id"]
        assert await _keys(client, exclude_room=rid) == set()

        await client.post(f"/api/rooms/{rid}/leave",
                          headers={"X-Participant-Id": pid})
        assert "agent-1" in await _keys(client, exclude_room=rid)


async def test_other_rooms_are_unaffected(tmp_path):
    """在別的房裡不算「已經在場」——同一個 agent 可以同時待在多個房。"""
    app, client = await _client(tmp_path, "other")
    async with app.router.lifespan_context(app), client:
        a = (await client.post("/api/rooms", json={
            "name": "A", "session_key": "owner"})).json()["id"]
        b = (await client.post("/api/rooms", json={
            "name": "B", "session_key": "owner"})).json()["id"]
        await _join(client, a, "agent-1", "Novia")
        assert await _keys(client, exclude_room=a) == set()
        assert "agent-1" in await _keys(client, exclude_room=b)


async def test_no_param_keeps_the_old_behaviour(tmp_path):
    """舊 client 不帶參數時行為完全不變。"""
    app, client = await _client(tmp_path, "compat")
    async with app.router.lifespan_context(app), client:
        rid = (await client.post("/api/rooms", json={
            "name": "房", "session_key": "owner"})).json()["id"]
        await _join(client, rid, "agent-1", "Novia")
        assert "agent-1" in await _keys(client)
