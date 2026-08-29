"""踢出之後，管理員要能把人重新邀回來——但當事人不能自己爬回來。

原本的規則是「被踢的 session 一律不得重新加入」，理由正當：client 的斷線
自癒（身分失效即自動 rejoin）會在被踢的下一秒把人加回來，等於踢不掉。

但那條規則同時把管理員自己也鎖在門外——重新指派也進不來，踢出成了不可逆
的死鎖。分界線刻意**不是**「人類 vs agent」：agent 的自癒同樣會繞過，對
agent 一律放行等於踢 agent 完全失效。真正的分界是「自己回來 vs 被重新邀請」。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio


async def _make(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token="")
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def _join(client, room_id, session_key, name, assignment_id=None):
    body = {"kind": "claude", "session_key": session_key, "preferred_name": name}
    if assignment_id:
        body["assignment_id"] = assignment_id
    return await client.post(f"/api/rooms/{room_id}/join", json=body)


async def _setup_kicked(client, tag):
    """建房、加入 admin 與一個 agent、把 agent 踢掉。回傳 (room_id, admin)。"""
    room_id = (
        await client.post("/api/rooms", json={"name": tag, "session_key": "admin-key"})
    ).json()["id"]
    admin = (await _join(client, room_id, "admin-key", "Xavier")).json()
    target = (await _join(client, room_id, "agent-key", "Novia")).json()
    r = await client.post(
        f"/api/rooms/{room_id}/participants/{target['participant_id']}/kick",
        headers={"X-Participant-Id": admin["participant_id"]},
    )
    assert r.status_code == 200, r.text
    return room_id, admin


async def _assign(client, room_id, name="Novia"):
    return (
        await client.post(
            f"/api/rooms/{room_id}/assignments",
            json={"target_session_key": "agent-key", "note": "回來幫忙",
                  "assigned_name": name},
        )
    ).json()["id"]


async def test_kicked_cannot_rejoin_by_itself(tmp_path):
    app, client = await _make(tmp_path, "self")
    async with client:
        async with app.router.lifespan_context(app):
            room_id, _ = await _setup_kicked(client, "房")
            r = await _join(client, room_id, "agent-key", "Novia")
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "kicked"


async def test_admin_can_reinvite_by_new_assignment(tmp_path):
    app, client = await _make(tmp_path, "reinvite")
    async with client:
        async with app.router.lifespan_context(app):
            room_id, _ = await _setup_kicked(client, "房")
            aid = await _assign(client, room_id, name="Novia-2")

            r = await _join(client, room_id, "agent-key", "自取的名字",
                            assignment_id=aid)
            assert r.status_code == 200, r.text
            data = r.json()
            assert data["rejoined"] is False
            # 指派者取的名字優先於自取名
            assert data["display_name"] == "Novia-2"
            # 重新進來是全新的加入，該有加入訊息讓房內其他人知道
            assert data["join_message_id"]

            detail = (await client.get(f"/api/rooms/{room_id}")).json()
            mine = [p for p in detail["participants"] if p["display_name"] == "Novia-2"]
            assert len(mine) == 1
            assert mine[0]["status"] == "active"


async def test_kick_revokes_the_old_assignment(tmp_path):
    """否則被踢的 agent 拿踢出**之前**那筆指派就能自己繞回來。"""
    app, client = await _make(tmp_path, "revoke")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (
                await client.post(
                    "/api/rooms", json={"name": "房", "session_key": "admin-key"}
                )
            ).json()["id"]
            admin = (await _join(client, room_id, "admin-key", "Xavier")).json()
            # 先指派、加入，再踢掉——舊指派此時是 accepted
            old_aid = await _assign(client, room_id)
            joined = (
                await _join(client, room_id, "agent-key", "Novia",
                            assignment_id=old_aid)
            ).json()
            await client.post(
                f"/api/rooms/{room_id}/participants/{joined['participant_id']}/kick",
                headers={"X-Participant-Id": admin["participant_id"]},
            )

            r = await _join(client, room_id, "agent-key", "Novia",
                            assignment_id=old_aid)
            assert r.status_code != 200, "踢出之前的指派不得成為繞過的後門"

            rows = (
                await client.get(f"/api/rooms/{room_id}/assignments")
            ).json()["assignments"]
            assert [a["status"] for a in rows if a["id"] == old_aid] == ["revoked"]
