"""指派的回應與收回的權限邊界。

與 `test_delete_permission` 同一條原則：**token 管的是「能不能連進來」，
房內的事由房內判**。原本這兩個端點都只驗 API token：

- `POST /api/assignments/{id}/resolve`——任何持 token 者可以替別人 accept
  或 decline。被指派方甚至不會知道有人代他婉拒了
- `DELETE /api/assignments/{id}`——任何持 token 者可以收回**別的房間**的邀請

resolve 的門檻是「本人」（`X-Session-Key` 對上 `target_session_key`），
cancel 的門檻是「這個房的人」（建立者或成員）——收回邀請是房內的管理動作，
不是被指派方的事，兩者不共用判定。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio


async def _make_client(tmp_path, name, **cfg_kw):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token="", **cfg_kw)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def _room(client, name="房", owner="owner-key"):
    r = await client.post("/api/rooms", json={"name": name, "session_key": owner})
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def _assign(client, room_id, target, owner="owner-key"):
    r = await client.post(
        f"/api/rooms/{room_id}/assignments",
        json={"target_session_key": target, "note": "來幫忙"},
        headers={"X-Session-Key": owner},
    )
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def _status(client, room_id, aid, owner="owner-key"):
    rows = (await client.get(
        f"/api/rooms/{room_id}/assignments",
        headers={"X-Session-Key": owner},
    )).json()["assignments"]
    return [a for a in rows if a["id"] == aid][0]["status"]


async def test_target_can_resolve_own_assignment(tmp_path):
    """被指派的人回應自己的邀請——基本路徑。"""
    app, client = await _make_client(tmp_path, "as-own")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            aid = await _assign(client, room_id, "target-key")

            r = await client.post(
                f"/api/assignments/{aid}/resolve",
                json={"status": "declined"},
                headers={"X-Session-Key": "target-key"},
            )
            assert r.status_code == 200, r.text
            assert await _status(client, room_id, aid) == "declined"


async def test_someone_else_cannot_resolve(tmp_path):
    """別人不能替你婉拒——這是原本的洞。"""
    app, client = await _make_client(tmp_path, "as-other")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            aid = await _assign(client, room_id, "target-key")

            r = await client.post(
                f"/api/assignments/{aid}/resolve",
                json={"status": "declined"},
                headers={"X-Session-Key": "someone-else"},
            )
            assert r.status_code == 403, r.text
            assert r.json()["detail"]["code"] == "not_assignment_target"
            # 沒被動到
            assert await _status(client, room_id, aid) == "pending"


async def test_resolve_without_identity_is_401(tmp_path):
    """沒說自己是誰 → 401，與「你不是被指派的人」分開講。"""
    app, client = await _make_client(tmp_path, "as-anon")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            aid = await _assign(client, room_id, "target-key")

            r = await client.post(
                f"/api/assignments/{aid}/resolve", json={"status": "accepted"}
            )
            assert r.status_code == 401, r.text
            assert r.json()["detail"]["code"] == "session_key_header_required"


async def test_creator_can_cancel(tmp_path):
    """房主收回自己發的邀請——基本路徑（指派 UI 正開在這個位置）。"""
    app, client = await _make_client(tmp_path, "as-cancel")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            aid = await _assign(client, room_id, "target-key")

            r = await client.delete(
                f"/api/assignments/{aid}",
                headers={"X-Session-Key": "owner-key"},
            )
            assert r.status_code == 200, r.text
            assert await _status(client, room_id, aid) == "cancelled"


async def test_outsider_cannot_cancel(tmp_path):
    """房外的人不能收回這個房的邀請。"""
    app, client = await _make_client(tmp_path, "as-outsider")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            aid = await _assign(client, room_id, "target-key")

            r = await client.delete(
                f"/api/assignments/{aid}",
                headers={"X-Session-Key": "nobody"},
            )
            assert r.status_code in (401, 403), r.text
            assert await _status(client, room_id, aid) == "pending"


async def test_member_can_cancel(tmp_path):
    """房內成員也算數——邀請是房內的協作行為，不是房主的私產。"""
    app, client = await _make_client(tmp_path, "as-member")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            me = (await client.post(
                f"/api/rooms/{room_id}/join",
                json={"kind": "claude", "session_key": "s-a",
                      "preferred_name": "Alpha"},
            )).json()
            aid = await _assign(client, room_id, "target-key")

            r = await client.delete(
                f"/api/assignments/{aid}",
                headers={"X-Participant-Id": me["participant_id"]},
            )
            assert r.status_code == 200, r.text
