"""session 的主機名：指派候選要分得出「這是我這台機器上的 agent 嗎」。

指派是私人房的入場券（見 `_invited_to_private`），把別人機器上的 agent
指派進來等於把房裡的內容送出去。這組測試守的是名錄有沒有把 host 記對、
以及舊 bridge 不自報時不會把已知的值洗掉。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config


async def _make(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token="")
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def _sessions(client):
    r = await client.get("/api/sessions")
    assert r.status_code == 200, r.text
    return {s["session_key"]: s for s in r.json()["sessions"]}


@pytest.mark.asyncio
async def test_host_is_recorded_from_the_room_list_ping(tmp_path):
    app, client = await _make(tmp_path, "host_rooms")
    async with client:
        async with app.router.lifespan_context(app):
            await client.get(
                "/api/rooms",
                params={"session_key": "claude-a", "kind": "claude",
                        "host": "BERNIE-PC"},
            )
            assert (await _sessions(client))["claude-a"]["host"] == "BERNIE-PC"


@pytest.mark.asyncio
async def test_host_is_recorded_from_join_and_assignment_poll(tmp_path):
    """三條上報通道都要記——watcher 只打 assignments，bridge 只打 join。"""
    app, client = await _make(tmp_path, "host_join")
    async with client:
        async with app.router.lifespan_context(app):
            room = (
                await client.post("/api/rooms", json={"name": "房"})
            ).json()
            await client.post(
                f"/api/rooms/{room['id']}/join",
                json={"kind": "claude", "session_key": "claude-b",
                      "host": "BERNIE-PC"},
            )
            await client.get(
                "/api/assignments",
                params={"session_key": "claude-c", "kind": "claude",
                        "host": "OTHER-PC"},
            )
            rows = await _sessions(client)
            assert rows["claude-b"]["host"] == "BERNIE-PC"
            assert rows["claude-c"]["host"] == "OTHER-PC"


@pytest.mark.asyncio
async def test_old_bridge_does_not_wipe_a_known_host(tmp_path):
    """舊 bridge 不自報 host，不能因為它呼叫了一次就把已知的主機名洗掉。

    kind／label 早就是這個規則，host 跟上——否則同一個 session 只要被舊版
    client 碰過一次，就會從指派清單的「本機」掉進「未知裝置」。
    """
    app, client = await _make(tmp_path, "host_keep")
    async with client:
        async with app.router.lifespan_context(app):
            await client.get(
                "/api/rooms",
                params={"session_key": "claude-d", "kind": "claude",
                        "host": "BERNIE-PC"},
            )
            # 舊 bridge：完全不帶 host
            await client.get(
                "/api/rooms", params={"session_key": "claude-d", "kind": "claude"}
            )
            assert (await _sessions(client))["claude-d"]["host"] == "BERNIE-PC"


@pytest.mark.asyncio
async def test_unreported_host_is_empty_not_guessed(tmp_path):
    """沒報就是空字串。空值在 UI 上是「未知裝置」，不能被當成本機。"""
    app, client = await _make(tmp_path, "host_absent")
    async with client:
        async with app.router.lifespan_context(app):
            await client.get(
                "/api/rooms", params={"session_key": "claude-e", "kind": "claude"}
            )
            assert (await _sessions(client))["claude-e"]["host"] == ""
