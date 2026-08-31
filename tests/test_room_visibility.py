"""對話鎖定：私人房不出現在別人的列表，也不能不請自來。

擋的是「逛到」與「自己走進來」，不是有心人——拿得到 token 的人本來就能對
任何房建立指派（token 是信任邊界，房間不是）。測試守的是前者。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config


async def _make(tmp_path, name, **kw):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token="", **kw)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def _room(client, name="房", visibility="public", session_key="admin"):
    r = await client.post(
        "/api/rooms",
        json={"name": name, "session_key": session_key, "visibility": visibility},
    )
    assert r.status_code == 200, r.text
    return r.json()


async def _join(client, room_id, session_key, name=None, **body):
    return await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": "claude", "session_key": session_key,
              "preferred_name": name, **body},
    )


async def _room_ids(client, session_key=None):
    params = {"session_key": session_key} if session_key else {}
    r = await client.get("/api/rooms", params=params)
    assert r.status_code == 200, r.text
    return [x["id"] for x in r.json()["rooms"]]


async def _invite(client, room_id, session_key, note=""):
    r = await client.post(
        f"/api/rooms/{room_id}/assignments",
        json={"target_session_key": session_key, "note": note},
    )
    assert r.status_code == 200, r.text
    return r.json()


@pytest.mark.asyncio
async def test_room_defaults_to_public(tmp_path):
    app, client = await _make(tmp_path, "vis_default")
    async with client:
        async with app.router.lifespan_context(app):
            room = await _room(client)
            assert room["visibility"] == "public"
            assert room["id"] in await _room_ids(client, "someone-else")


@pytest.mark.asyncio
async def test_private_room_is_hidden_from_outsiders(tmp_path):
    app, client = await _make(tmp_path, "vis_hidden")
    async with client:
        async with app.router.lifespan_context(app):
            public = await _room(client, "公開房")
            private = await _room(client, "私人房", visibility="private")

            outsider = await _room_ids(client, "outsider")
            assert public["id"] in outsider
            assert private["id"] not in outsider

            # 沒帶 session_key 的匿名列表也看不到——無從證明自己有份
            assert private["id"] not in await _room_ids(client)

            # 建立者看得到自己的房
            assert private["id"] in await _room_ids(client, "admin")


@pytest.mark.asyncio
async def test_invited_and_member_sessions_see_the_private_room(tmp_path):
    app, client = await _make(tmp_path, "vis_invited")
    async with client:
        async with app.router.lifespan_context(app):
            private = await _room(client, "私人房", visibility="private")
            rid = private["id"]

            await _invite(client, rid, "sess-guest", "來討論 API")
            assert rid in await _room_ids(client, "sess-guest")

            r = await _join(client, rid, "sess-guest", "Guest")
            assert r.status_code == 200, r.text
            # 加入後指派被標記完成，仍然看得到（這次是靠成員身分）
            assert rid in await _room_ids(client, "sess-guest")

            # 離開之後還看得到：他當時在場過，房間不該從列表上憑空消失
            await client.post(
                f"/api/rooms/{rid}/leave",
                headers={"X-Participant-Id": r.json()["participant_id"]},
            )
            assert rid in await _room_ids(client, "sess-guest")


@pytest.mark.asyncio
async def test_joining_a_private_room_without_invitation_is_refused(tmp_path):
    app, client = await _make(tmp_path, "vis_join")
    async with client:
        async with app.router.lifespan_context(app):
            private = await _room(client, "私人房", visibility="private")
            r = await _join(client, private["id"], "sess-stranger", "Stranger")
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "room_is_private"

            # 建立者本人不需要邀請
            r = await _join(client, private["id"], "admin", "Admin")
            assert r.status_code == 200, r.text


@pytest.mark.asyncio
async def test_invitation_allows_joining(tmp_path):
    app, client = await _make(tmp_path, "vis_join_ok")
    async with client:
        async with app.router.lifespan_context(app):
            private = await _room(client, "私人房", visibility="private")
            await _invite(client, private["id"], "sess-guest")
            r = await _join(client, private["id"], "sess-guest", "Guest")
            assert r.status_code == 200, r.text


@pytest.mark.asyncio
async def test_kicked_session_cannot_re_enter_a_private_room(tmp_path):
    app, client = await _make(tmp_path, "vis_kick")
    async with client:
        async with app.router.lifespan_context(app):
            private = await _room(client, "私人房", visibility="private")
            rid = private["id"]
            admin = (await _join(client, rid, "admin", "Admin")).json()
            await _invite(client, rid, "sess-guest")
            guest = (await _join(client, rid, "sess-guest", "Guest")).json()

            r = await client.post(
                f"/api/rooms/{rid}/participants/{guest['participant_id']}/kick",
                headers={"X-Participant-Id": admin["participant_id"]},
            )
            assert r.status_code == 200, r.text

            # 被踢＝那筆指派也被撤銷，列表上不再出現，也回不去
            assert rid not in await _room_ids(client, "sess-guest")
            r = await _join(client, rid, "sess-guest", "Guest")
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "kicked"


@pytest.mark.asyncio
async def test_admin_can_lock_and_unlock(tmp_path):
    app, client = await _make(tmp_path, "vis_toggle")
    async with client:
        async with app.router.lifespan_context(app):
            room = await _room(client, "房")
            rid = room["id"]
            r = await client.post(
                f"/api/rooms/{rid}/visibility",
                json={"visibility": "private"},
                headers={"X-Session-Key": "admin"},
            )
            assert r.status_code == 200, r.text
            assert r.json() == {"ok": True, "visibility": "private", "changed": True}
            assert rid not in await _room_ids(client, "outsider")

            # 同一個值再設一次是 no-op，不重複廣播
            r = await client.post(
                f"/api/rooms/{rid}/visibility",
                json={"visibility": "private"},
                headers={"X-Session-Key": "admin"},
            )
            assert r.json()["changed"] is False

            r = await client.post(
                f"/api/rooms/{rid}/visibility",
                json={"visibility": "public"},
                headers={"X-Session-Key": "admin"},
            )
            assert r.status_code == 200, r.text
            assert rid in await _room_ids(client, "outsider")


@pytest.mark.asyncio
async def test_visibility_change_is_announced_in_the_room(tmp_path):
    app, client = await _make(tmp_path, "vis_announce")
    async with client:
        async with app.router.lifespan_context(app):
            room = await _room(client, "房")
            rid = room["id"]
            admin = (await _join(client, rid, "admin", "Admin")).json()
            await client.post(
                f"/api/rooms/{rid}/visibility",
                json={"visibility": "private"},
                headers={"X-Session-Key": "admin"},
            )
            r = await client.get(
                f"/api/rooms/{rid}/messages",
                headers={"X-Participant-Id": admin["participant_id"]},
            )
            last = r.json()["messages"][-1]
            assert last["system_event"] == "visibility"
            assert "私人" in last["content"]


@pytest.mark.asyncio
async def test_non_admin_cannot_change_visibility(tmp_path):
    app, client = await _make(tmp_path, "vis_not_admin")
    async with client:
        async with app.router.lifespan_context(app):
            room = await _room(client, "房")
            rid = room["id"]
            other = (await _join(client, rid, "sess-other", "Other")).json()
            r = await client.post(
                f"/api/rooms/{rid}/visibility",
                json={"visibility": "private"},
                headers={"X-Participant-Id": other["participant_id"]},
            )
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "not_admin"


@pytest.mark.asyncio
async def test_admin_can_use_participant_header(tmp_path):
    """建立者已經加入房間時，用房內身分也該過得了管理員門檻。"""
    app, client = await _make(tmp_path, "vis_admin_pid")
    async with client:
        async with app.router.lifespan_context(app):
            room = await _room(client, "房")
            rid = room["id"]
            admin = (await _join(client, rid, "admin", "Admin")).json()
            r = await client.post(
                f"/api/rooms/{rid}/visibility",
                json={"visibility": "private"},
                headers={"X-Participant-Id": admin["participant_id"]},
            )
            assert r.status_code == 200, r.text


@pytest.mark.asyncio
async def test_room_without_creator_has_no_admin(tmp_path):
    app, client = await _make(tmp_path, "vis_no_admin")
    async with client:
        async with app.router.lifespan_context(app):
            r = await client.post("/api/rooms", json={"name": "無主房"})
            rid = r.json()["id"]
            r = await client.post(
                f"/api/rooms/{rid}/visibility",
                json={"visibility": "private"},
                headers={"X-Session-Key": "whoever"},
            )
            assert r.status_code == 409
            assert r.json()["detail"]["code"] == "room_has_no_admin"


@pytest.mark.asyncio
async def test_archived_private_room_stays_hidden(tmp_path):
    app, client = await _make(tmp_path, "vis_archived")
    async with client:
        async with app.router.lifespan_context(app):
            private = await _room(client, "私人房", visibility="private")
            rid = private["id"]
            await client.post(f"/api/rooms/{rid}/archive", headers={"X-Session-Key": "admin"})
            r = await client.get(
                "/api/rooms", params={"status": "archived", "session_key": "outsider"}
            )
            assert rid not in [x["id"] for x in r.json()["rooms"]]
            r = await client.get(
                "/api/rooms", params={"status": "archived", "session_key": "admin"}
            )
            assert rid in [x["id"] for x in r.json()["rooms"]]
