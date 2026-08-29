"""管理員踢人：建立者授權、被踢者不得重進、非管理員拒絕。"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio


async def _make(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token="")
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def _join(client, room_id, session_key, name, kind="human", role="human"):
    r = await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": kind, "session_key": session_key,
              "preferred_name": name, "role": role},
    )
    assert r.status_code == 200, r.text
    return r.json()


async def test_creator_kicks_and_target_cannot_rejoin(tmp_path):
    app, client = await _make(tmp_path, "kick")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (
                await client.post(
                    "/api/rooms", json={"name": "房", "session_key": "admin-key"}
                )
            ).json()["id"]
            admin = await _join(client, room_id, "admin-key", "Xavier")
            target = await _join(client, room_id, "guest-key", "Guest")

            r = await client.post(
                f"/api/rooms/{room_id}/participants/{target['participant_id']}/kick",
                headers={"X-Participant-Id": admin["participant_id"]},
            )
            assert r.status_code == 200

            detail = (
                await client.get(
                    f"/api/rooms/{room_id}",
                    headers={"X-Participant-Id": admin["participant_id"]},
                )
            ).json()
            by_name = {p["display_name"]: p["status"] for p in detail["participants"]}
            assert by_name["Guest"] == "kicked"
            # 踢人不直接封存
            assert detail["room"]["status"] == "active"

            # 被踢的 session 不得重新加入（client 的自動 rejoin 也會被擋）
            r = await client.post(
                f"/api/rooms/{room_id}/join",
                json={"kind": "human", "session_key": "guest-key",
                      "preferred_name": "Guest", "role": "human"},
            )
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "kicked"

            msgs = (await client.get(
                f"/api/rooms/{room_id}/messages",
                headers={"X-Participant-Id": admin["participant_id"]},
            )).json()["messages"]
            assert any("已被管理員移出" in m["content"] for m in msgs)


async def test_non_admin_cannot_kick(tmp_path):
    app, client = await _make(tmp_path, "nokick")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (
                await client.post(
                    "/api/rooms", json={"name": "房", "session_key": "admin-key"}
                )
            ).json()["id"]
            await _join(client, room_id, "admin-key", "Xavier")
            a = await _join(client, room_id, "a-key", "Alice")
            b = await _join(client, room_id, "b-key", "Bob")

            r = await client.post(
                f"/api/rooms/{room_id}/participants/{b['participant_id']}/kick",
                headers={"X-Participant-Id": a["participant_id"]},
            )
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "not_admin"


async def test_admin_flag_and_creatorless_room(tmp_path):
    app, client = await _make(tmp_path, "adminflag")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (
                await client.post(
                    "/api/rooms", json={"name": "房", "session_key": "admin-key"}
                )
            ).json()["id"]
            admin_view = (
                await client.get(
                    f"/api/rooms/{room_id}",
                    headers={"X-Session-Key": "admin-key"},
                )
            ).json()
            # 非建立者要看房間詳情得先是成員——房間是邊界，不是名冊
            other = await _join(client, room_id, "other-key", "Other")
            other_view = (await client.get(
                f"/api/rooms/{room_id}",
                headers={"X-Participant-Id": other["participant_id"]})).json()
            assert admin_view["you_are_admin"] is True
            assert other_view["you_are_admin"] is False
            # creator key 不可外流
            assert "creator_session_key" not in admin_view["room"]

            # 沒有建立者的房間（bridge/舊資料）：任何人都不是管理員
            legacy = (await client.post("/api/rooms", json={"name": "舊房"})).json()[
                "id"
            ]
            me = await _join(client, legacy, "x-key", "X")
            someone = await _join(client, legacy, "y-key", "Y")
            r = await client.post(
                f"/api/rooms/{legacy}/participants/{someone['participant_id']}/kick",
                headers={"X-Participant-Id": me["participant_id"]},
            )
            assert r.status_code == 403
