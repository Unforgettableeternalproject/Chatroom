"""hold 標記：agent 跑長工作時自行掛起，時限內不因閒置被 sweeper 移除。

heartbeat 得中途反覆打，長測試／長編譯期間 agent 根本不會回來打——hold
掛一次就撐過整段安靜期，做完再呼叫一次解除。時限上限擋的是掛著 hold 就
crash 的 agent：沒有人會來解除，無上限等於永遠掃不掉的殘影。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config


async def _make(tmp_path, name, **kw):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token="", **kw)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def _join(client, room_id, session_key, name, **extra):
    r = await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": "claude", "session_key": session_key,
              "preferred_name": name, "role": "agent", **extra},
    )
    assert r.status_code == 200, r.text
    return r.json()


async def _new_room(client, name="房"):
    r = await client.post(
        "/api/rooms", json={"name": name, "session_key": "admin-key"}
    )
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def _hold(client, room_id, participant_id):
    r = await client.post(
        f"/api/rooms/{room_id}/hold",
        headers={"X-Participant-Id": participant_id},
    )
    assert r.status_code == 200, r.text
    return r.json()


@pytest.mark.asyncio
async def test_held_agent_survives_idle_sweep(tmp_path):
    """掛著 hold 的 agent 就算 last_seen_at 早已逾時也不能被移除。"""
    # idle_timeout=0：join 當下就已逾時，沒有 hold 的話下一輪 sweep 必移除
    app, client = await _make(tmp_path, "held", idle_timeout=0.0)
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _new_room(client)
            p = await _join(client, room_id, "worker-key", "Novia")

            body = await _hold(client, room_id, p["participant_id"])
            assert body["held"] is True
            assert body["hold_until"] is not None

            await app.state.sweep_once()
            r = await client.post(
                f"/api/rooms/{room_id}/heartbeat",
                headers={"X-Participant-Id": p["participant_id"]},
            )
            assert r.status_code == 200


@pytest.mark.asyncio
async def test_second_call_releases_hold(tmp_path):
    """再呼叫一次就是解除——解除後閒置移除照常運作。"""
    app, client = await _make(tmp_path, "toggle", idle_timeout=0.0)
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _new_room(client)
            p = await _join(client, room_id, "worker-key", "Novia")

            assert (await _hold(client, room_id, p["participant_id"]))["held"] is True
            off = await _hold(client, room_id, p["participant_id"])
            assert off["held"] is False
            assert off["hold_until"] is None

            await app.state.sweep_once()
            r = await client.post(
                f"/api/rooms/{room_id}/heartbeat",
                headers={"X-Participant-Id": p["participant_id"]},
            )
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "participant_removed_idle"


@pytest.mark.asyncio
async def test_expired_hold_no_longer_protects(tmp_path):
    """hold 過了時限就形同沒有——掛著 hold crash 的 agent 不能永遠留在成員列上。"""
    # hold_max=0：掛上的瞬間就過期
    app, client = await _make(tmp_path, "expired", idle_timeout=0.0, hold_max=0.0)
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _new_room(client)
            p = await _join(client, room_id, "worker-key", "Novia")

            assert (await _hold(client, room_id, p["participant_id"]))["held"] is True

            await app.state.sweep_once()
            r = await client.post(
                f"/api/rooms/{room_id}/heartbeat",
                headers={"X-Participant-Id": p["participant_id"]},
            )
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "participant_removed_idle"


@pytest.mark.asyncio
async def test_held_subagent_survives_short_ttl_sweep(tmp_path):
    """subagent 的短時限同樣要認得 hold——長工作前掛上就不會被回收。"""
    # subagent_timeout=0：登記當下就已逾時
    app, client = await _make(tmp_path, "subhold", subagent_timeout=0.0)
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _new_room(client)
            parent = await _join(client, room_id, "parent-key", "Novia")
            sub = await _join(
                client, room_id, "parent-key#tester-a1b2c3d4", "米勒",
                parent_participant_id=parent["participant_id"],
            )

            assert (await _hold(client, room_id, sub["participant_id"]))["held"] is True

            await app.state.sweep_once()
            r = await client.post(
                f"/api/rooms/{room_id}/heartbeat",
                headers={"X-Participant-Id": sub["participant_id"]},
            )
            assert r.status_code == 200
