"""回歸測試：解封存活、跨房身分隔離、封存房唯讀語意。

對應 TASKS.md 的 P1-03 / P1-05 / P1-04（戴爾 code-reading 撿到的三個問題）。
"""

import asyncio

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio


async def _make_client(tmp_path, name, **cfg_kw):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token="", **cfg_kw)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def _join(client, room_id, session_key, name=None, kind="claude"):
    r = await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": kind, "session_key": session_key, "preferred_name": name},
    )
    assert r.status_code == 200, r.text
    return r.json()


async def test_unarchive_survives_sweeper(tmp_path):
    """P1-03：解封後房內沒有 active agent，不該被 sweeper 立刻封回去。"""
    app, client = await _make_client(
        tmp_path, "unarchive", idle_timeout=0.05, sweep_interval=0.05,
        archive_grace=0.05,
    )
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post("/api/rooms",
                              json={"name": "房", "session_key": "owner-key"})).json()["id"]
            await _join(client, room_id, "s1")
            # 等 agent 閒置 → 自動封存
            for _ in range(40):
                await asyncio.sleep(0.05)
                if (await client.get(f"/api/rooms/{room_id}",
                              headers={"X-Session-Key": "owner-key"})).json()["room"][
                    "status"
                ] == "archived":
                    break
            assert (await client.get(f"/api/rooms/{room_id}",
                              headers={"X-Session-Key": "owner-key"})).json()["room"][
                "status"
            ] == "archived"

            # 人類解封 → 多輪 sweeper 後仍應維持 active
            await client.post(f"/api/rooms/{room_id}/unarchive")
            await asyncio.sleep(0.3)
            assert (await client.get(f"/api/rooms/{room_id}",
                              headers={"X-Session-Key": "owner-key"})).json()["room"][
                "status"
            ] == "active"

            # 新 agent 加入又閒置 → 才會再次封存
            await _join(client, room_id, "s2")
            for _ in range(40):
                await asyncio.sleep(0.05)
                if (await client.get(f"/api/rooms/{room_id}",
                              headers={"X-Session-Key": "owner-key"})).json()["room"][
                    "status"
                ] == "archived":
                    break
            assert (await client.get(f"/api/rooms/{room_id}",
                              headers={"X-Session-Key": "owner-key"})).json()["room"][
                "status"
            ] == "archived"


async def test_cross_room_identity_rejected(tmp_path):
    """P1-05：A 房的 participant id 不可拿去 B 房發言/離開/釘選。"""
    app, client = await _make_client(tmp_path, "xroom")
    async with client:
        async with app.router.lifespan_context(app):
            room_a = (await client.post("/api/rooms", json={"name": "A"})).json()["id"]
            room_b = (await client.post("/api/rooms", json={"name": "B"})).json()["id"]
            pa = await _join(client, room_a, "sa", "Alpha")
            pb = await _join(client, room_b, "sb", "Beta")
            headers_a = {"X-Participant-Id": pa["participant_id"]}

            r = await client.post(
                f"/api/rooms/{room_b}/messages", json={"content": "入侵"}, headers=headers_a
            )
            assert r.status_code == 403
            r = await client.post(f"/api/rooms/{room_b}/leave", headers=headers_a)
            assert r.status_code == 403
            r = await client.post(f"/api/rooms/{room_b}/heartbeat", headers=headers_a)
            assert r.status_code == 403

            # B 房的訊息不可被 A 房身分釘選
            mid = (
                await client.post(
                    f"/api/rooms/{room_b}/messages",
                    json={"content": "B 房訊息"},
                    headers={"X-Participant-Id": pb["participant_id"]},
                )
            ).json()["id"]
            r = await client.post(f"/api/messages/{mid}/pin", headers=headers_a)
            assert r.status_code == 403


async def test_archived_room_semantics(tmp_path):
    """P1-04：封存房唯讀——禁發言/釘選/取消釘選；允許離開與人類軟刪除。"""
    app, client = await _make_client(tmp_path, "archived")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post("/api/rooms",
                              json={"name": "房", "session_key": "owner-key"})).json()["id"]
            p = await _join(client, room_id, "s1", "Solo")
            headers = {"X-Participant-Id": p["participant_id"]}
            mid = (
                await client.post(
                    f"/api/rooms/{room_id}/messages",
                    json={"content": "封存前"},
                    headers=headers,
                )
            ).json()["id"]
            await client.post(f"/api/messages/{mid}/pin", headers=headers)
            await client.post(f"/api/rooms/{room_id}/archive")

            r = await client.post(
                f"/api/rooms/{room_id}/messages", json={"content": "x"}, headers=headers
            )
            assert r.status_code == 409
            r = await client.post(f"/api/messages/{mid}/pin", headers=headers)
            assert r.status_code == 409
            r = await client.delete(f"/api/messages/{mid}/pin", headers=headers)
            assert r.status_code == 409

            # 人類軟刪除（管控）與成員離開仍允許
            assert (await client.delete(f"/api/messages/{mid}")).status_code == 200
            assert (
                await client.post(f"/api/rooms/{room_id}/leave", headers=headers)
            ).status_code == 200


async def test_archive_unarchive_system_messages_and_idempotency(tmp_path):
    """archive/unarchive 留下 system 時間軸標記；對 active 房解封為冪等。"""
    app, client = await _make_client(tmp_path, "sysmsg")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post("/api/rooms",
                              json={"name": "房", "session_key": "owner-key"})).json()["id"]
            s1 = await _join(client, room_id, "s1")

            r = await client.post(f"/api/rooms/{room_id}/unarchive")
            assert r.json()["already_active"] is True

            await client.post(f"/api/rooms/{room_id}/archive")
            await client.post(f"/api/rooms/{room_id}/unarchive")
            msgs = (await client.get(
                f"/api/rooms/{room_id}/messages",
                headers={"X-Participant-Id": s1["participant_id"]})).json()["messages"]
            contents = [m["content"] for m in msgs if m["kind"] == "system"]
            assert "聊天室已被手動封存" in contents
            assert "聊天室已解除封存" in contents
            # 冪等解封不會多留一則訊息
            assert contents.count("聊天室已解除封存") == 1
