"""Phase 1 測試：WebSocket 即時通道、presence sweeper 閒置移除與自動封存。"""

import asyncio

import pytest
from fastapi.testclient import TestClient
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config


# ---------- WebSocket（同步 TestClient，因 httpx ASGITransport 不支援 WS） ----------

def test_ws_subscribe_receives_messages(tmp_path):
    app = create_app(Config(db_path=str(tmp_path / "ws.db"), api_token=""))
    with TestClient(app) as client:
        room_id = client.post("/api/rooms", json={"name": "WS房"}).json()["id"]
        joined = client.post(
            f"/api/rooms/{room_id}/join",
            json={"kind": "claude", "session_key": "s1", "preferred_name": "Nova"},
        ).json()

        with client.websocket_connect("/ws") as ws:
            ws.send_json({"type": "ping"})
            assert ws.receive_json() == {"type": "pong"}

            ws.send_json({"type": "subscribe", "room_id": room_id, "after_seq": 0})
            # 訂閱時應先收到既有訊息（join 系統訊息）
            evt = ws.receive_json()
            assert evt["type"] == "messages" and evt["room_id"] == room_id
            assert evt["messages"][-1]["kind"] == "system"
            last_seq = evt["messages"][-1]["seq"]

            # 新訊息即時推播
            client.post(
                f"/api/rooms/{room_id}/messages",
                json={"content": "即時測試"},
                headers={"X-Participant-Id": joined["participant_id"]},
            )
            evt = ws.receive_json()
            assert evt["messages"][-1]["seq"] == last_seq + 1
            assert evt["messages"][-1]["content"] == "即時測試"


def test_ws_rejects_bad_token(tmp_path):
    app = create_app(Config(db_path=str(tmp_path / "tok.db"), api_token="secret"))
    with TestClient(app) as client:
        with pytest.raises(Exception):
            with client.websocket_connect("/ws?token=wrong") as ws:
                ws.receive_json()


# ---------- Presence sweeper ----------

@pytest.mark.asyncio
async def test_sweeper_removes_idle_agent_and_archives(tmp_path):
    cfg = Config(
        db_path=str(tmp_path / "sweep.db"), api_token="",
        idle_timeout=0.1, sweep_interval=0.05, archive_grace=0.05,
    )
    app = create_app(cfg)
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        async with app.router.lifespan_context(app):
            room_id = (
                await client.post("/api/rooms", json={"name": "閒置房"})
            ).json()["id"]
            await client.post(
                f"/api/rooms/{room_id}/join",
                json={"kind": "claude", "session_key": "s1", "preferred_name": "Idle"},
            )
            # 等 sweeper 跑過：閒置逾時 → 移出 → 房內無 agent → 封存
            for _ in range(40):
                await asyncio.sleep(0.05)
                detail = (await client.get(f"/api/rooms/{room_id}")).json()
                if detail["room"]["status"] == "archived":
                    break
            assert detail["room"]["status"] == "archived"
            assert detail["participants"][0]["status"] == "removed"

            msgs = (await client.get(f"/api/rooms/{room_id}/messages")).json()["messages"]
            assert any("因閒置逾時被移出" in m["content"] for m in msgs)


@pytest.mark.asyncio
async def test_sweeper_keeps_active_agent(tmp_path):
    cfg = Config(
        db_path=str(tmp_path / "alive.db"), api_token="",
        idle_timeout=10.0, sweep_interval=0.05,
    )
    app = create_app(cfg)
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        async with app.router.lifespan_context(app):
            room_id = (
                await client.post("/api/rooms", json={"name": "活躍房"})
            ).json()["id"]
            joined = (
                await client.post(
                    f"/api/rooms/{room_id}/join",
                    json={"kind": "claude", "session_key": "s1"},
                )
            ).json()
            await asyncio.sleep(0.2)  # sweeper 至少跑過一輪
            await client.post(
                f"/api/rooms/{room_id}/heartbeat",
                headers={"X-Participant-Id": joined["participant_id"]},
            )
            detail = (await client.get(f"/api/rooms/{room_id}")).json()
            assert detail["room"]["status"] == "active"
            assert detail["participants"][0]["status"] == "active"


@pytest.mark.asyncio
async def test_never_visited_room_not_archived(tmp_path):
    """從未有 agent 加入過的房間不該被封存（等人進來）。"""
    cfg = Config(
        db_path=str(tmp_path / "fresh.db"), api_token="",
        idle_timeout=0.05, sweep_interval=0.05,
    )
    app = create_app(cfg)
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        async with app.router.lifespan_context(app):
            room_id = (
                await client.post("/api/rooms", json={"name": "新房"})
            ).json()["id"]
            await asyncio.sleep(0.2)
            detail = (await client.get(f"/api/rooms/{room_id}")).json()
            assert detail["room"]["status"] == "active"
