"""刪除訊息的權限邊界（票 D1 的 server 半邊）。

`DELETE /api/messages/{id}` 原本只驗 API token 不驗身分——任何拿得到 token
的人都能刪掉任何人的訊息，包含別的房間的。token 是這個系統的信任邊界沒錯，
但「誰能抹掉誰說過的話」是房內的事，不該由 token 一刀決定。

刪除的權限模型**只涵蓋刪除**：本人或房間建立者。編輯（D2）是另一條界線，
不共用這裡的判定——刪掉看得出來，改掉看不出來。
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


async def _join(client, room_id, session_key, name=None, kind="claude"):
    r = await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": kind, "session_key": session_key, "preferred_name": name},
    )
    assert r.status_code == 200, r.text
    return r.json()


async def _say(client, room_id, participant_id, content):
    r = await client.post(
        f"/api/rooms/{room_id}/messages",
        json={"content": content},
        headers={"X-Participant-Id": participant_id},
    )
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def test_sender_can_delete_own_message(tmp_path):
    """發送者刪自己的話——最基本的那條，必須通。"""
    app, client = await _make_client(tmp_path, "del-own")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post(
                "/api/rooms",
                json={"name": "房", "session_key": "owner-key"})).json()["id"]
            a = await _join(client, room_id, "s-a", "Alpha")
            mid = await _say(client, room_id, a["participant_id"], "我說的")

            r = await client.delete(
                f"/api/messages/{mid}",
                headers={"X-Participant-Id": a["participant_id"]},
            )
            assert r.status_code == 200, r.text


async def test_other_member_cannot_delete(tmp_path):
    """房內另一個成員不能刪別人的訊息——這是原本的洞。"""
    app, client = await _make_client(tmp_path, "del-other")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post(
                "/api/rooms",
                json={"name": "房", "session_key": "owner-key"})).json()["id"]
            a = await _join(client, room_id, "s-a", "Alpha")
            b = await _join(client, room_id, "s-b", "Beta")
            mid = await _say(client, room_id, a["participant_id"], "Alpha 說的")

            r = await client.delete(
                f"/api/messages/{mid}",
                headers={"X-Participant-Id": b["participant_id"]},
            )
            assert r.status_code == 403, r.text
            assert r.json()["detail"]["code"] == "not_message_owner"

            # 而且真的沒被刪
            msgs = (await client.get(
                f"/api/rooms/{room_id}/messages",
                headers={"X-Participant-Id": a["participant_id"]},
            )).json()["messages"]
            assert [m for m in msgs if m["id"] == mid][0]["deleted"] is False


async def test_admin_can_delete_anyones_message(tmp_path):
    """房間建立者是管控者，刪得掉任何人的訊息（人類管控本來就是這端點的用途）。"""
    app, client = await _make_client(tmp_path, "del-admin")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post(
                "/api/rooms",
                json={"name": "房", "session_key": "owner-key"})).json()["id"]
            a = await _join(client, room_id, "s-a", "Alpha")
            mid = await _say(client, room_id, a["participant_id"], "Alpha 說的")

            # 建立者還沒 join 自己的房，只能自報 session key——與 _admin_or_403
            # 其他呼叫點一致
            r = await client.delete(
                f"/api/messages/{mid}",
                headers={"X-Session-Key": "owner-key"},
            )
            assert r.status_code == 200, r.text


async def test_no_identity_is_401_not_403(tmp_path):
    """沒帶身分與不是本人必須是兩句不同的話——處置完全不同。"""
    app, client = await _make_client(tmp_path, "del-anon")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post(
                "/api/rooms",
                json={"name": "房", "session_key": "owner-key"})).json()["id"]
            a = await _join(client, room_id, "s-a", "Alpha")
            mid = await _say(client, room_id, a["participant_id"], "Alpha 說的")

            r = await client.delete(f"/api/messages/{mid}")
            assert r.status_code == 401, r.text
            assert r.json()["detail"]["code"] == "participant_header_required"


async def test_cross_room_participant_cannot_delete(tmp_path):
    """拿 B 房的身分刪 A 房的訊息——跨房隔離在這裡也要成立。"""
    app, client = await _make_client(tmp_path, "del-cross")
    async with client:
        async with app.router.lifespan_context(app):
            room_a = (await client.post(
                "/api/rooms",
                json={"name": "A", "session_key": "owner-a"})).json()["id"]
            room_b = (await client.post(
                "/api/rooms",
                json={"name": "B", "session_key": "owner-b"})).json()["id"]
            a = await _join(client, room_a, "s-a", "Alpha")
            b = await _join(client, room_b, "s-b", "Beta")
            mid = await _say(client, room_a, a["participant_id"], "A 房的話")

            r = await client.delete(
                f"/api/messages/{mid}",
                headers={"X-Participant-Id": b["participant_id"]},
            )
            assert r.status_code == 403, r.text


async def test_subagent_message_deletable_by_parent(tmp_path):
    """子代理發的話，父層刪得掉——子代理是父層的一部分，不是另一個人。"""
    app, client = await _make_client(tmp_path, "del-subagent")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post(
                "/api/rooms",
                json={"name": "房", "session_key": "owner-key"})).json()["id"]
            parent = await _join(client, room_id, "s-parent", "Parent")
            r = await client.post(
                f"/api/rooms/{room_id}/join",
                json={"kind": "claude",
                      "session_key": "s-parent#tester-a1b2c3d4",
                      "preferred_name": "Child",
                      "parent_participant_id": parent["participant_id"]},
            )
            assert r.status_code == 200, r.text
            child_pid = r.json()["participant_id"]
            mid = await _say(client, room_id, child_pid, "子代理說的")

            r = await client.delete(
                f"/api/messages/{mid}",
                headers={"X-Participant-Id": parent["participant_id"]},
            )
            assert r.status_code == 200, r.text
