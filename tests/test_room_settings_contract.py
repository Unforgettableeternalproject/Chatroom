"""房間設定頁要用到的三條 Hub 契約（2026-09-23 艾斯維爾）。

1. 主題（topic）可以改——建房之後原本沒有任何出口
2. 房主離開：有別的人類就自動交給加入順位下一位；沒有就要明說「會封存」
   才走得掉，而且封存與離開是同一件事
3. 永久刪除只對已封存的房成立——封存是刪除的緩衝，與任務板同一條規則
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio


async def _make(tmp_path, name):
    app = create_app(Config(db_path=str(tmp_path / f"{name}.db"), api_token=""))
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def _room(client, key="owner"):
    r = await client.post("/api/rooms", json={"name": "房", "session_key": key})
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def _join(client, room_id, key, name, role="human", kind="human"):
    r = await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": kind, "session_key": key,
              "preferred_name": name, "role": role},
    )
    assert r.status_code == 200, r.text
    return r.json()


def _pid(p):
    return {"X-Participant-Id": p["participant_id"]}


async def _detail(client, room_id, viewer):
    r = await client.get(f"/api/rooms/{room_id}", headers=_pid(viewer))
    assert r.status_code == 200, r.text
    return r.json()


async def _system_events(client, room_id, viewer):
    r = await client.get(f"/api/rooms/{room_id}/messages", headers=_pid(viewer))
    return [m.get("system_event") for m in r.json()["messages"]
            if m["kind"] == "system"]


# ---------- 主題 ----------

async def test_admin_can_change_the_topic(tmp_path):
    app, client = await _make(tmp_path, "topic")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        admin = await _join(client, room_id, "owner", "Xavier")

        r = await client.post(f"/api/rooms/{room_id}/topic",
                              json={"topic": "  發版前的收尾  "},
                              headers=_pid(admin))
        assert r.status_code == 200, r.text
        assert r.json()["topic"] == "發版前的收尾"
        assert r.json()["changed"] is True
        assert (await _detail(client, room_id, admin))["room"]["topic"] == \
            "發版前的收尾"
        # 改主題要留痕，與改名同一個理由
        assert "topic" in await _system_events(client, room_id, admin)

        # 同一個值不發訊息
        r = await client.post(f"/api/rooms/{room_id}/topic",
                              json={"topic": "發版前的收尾"},
                              headers=_pid(admin))
        assert r.json()["changed"] is False


async def test_topic_can_be_cleared(tmp_path):
    app, client = await _make(tmp_path, "topic_clear")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        admin = await _join(client, room_id, "owner", "Xavier")
        await client.post(f"/api/rooms/{room_id}/topic",
                          json={"topic": "x"}, headers=_pid(admin))
        r = await client.post(f"/api/rooms/{room_id}/topic",
                              json={"topic": ""}, headers=_pid(admin))
        assert r.status_code == 200, r.text
        assert (await _detail(client, room_id, admin))["room"]["topic"] == ""


async def test_only_the_admin_can_change_the_topic(tmp_path):
    app, client = await _make(tmp_path, "topic_perm")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        guest = await _join(client, room_id, "guest", "Guest")
        r = await client.post(f"/api/rooms/{room_id}/topic",
                              json={"topic": "搶"}, headers=_pid(guest))
        assert r.status_code == 403
        assert r.json()["detail"]["code"] == "not_admin"


async def test_archived_room_topic_is_read_only(tmp_path):
    app, client = await _make(tmp_path, "topic_archived")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        admin = await _join(client, room_id, "owner", "Xavier")
        await client.post(f"/api/rooms/{room_id}/archive", headers=_pid(admin))
        r = await client.post(f"/api/rooms/{room_id}/topic",
                              json={"topic": "x"}, headers=_pid(admin))
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "room_archived"


async def test_members_cannot_change_any_room_setting(tmp_path):
    """房間設定只有房主改得動，一般成員全部 403（封存則只是提案）。"""
    app, client = await _make(tmp_path, "member_readonly")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        guest = await _join(client, room_id, "guest", "Guest")
        h = _pid(guest)
        for method, path, body in (
            ("PATCH", "", {"name": "改"}),
            ("POST", "/topic", {"topic": "改"}),
            ("POST", "/style", {"style": "concise"}),
            ("POST", "/visibility", {"visibility": "private"}),
        ):
            r = await client.request(method, f"/api/rooms/{room_id}{path}",
                                     json=body, headers=h)
            assert r.status_code == 403, (path, r.text)
        r = await client.post(f"/api/rooms/{room_id}/archive", headers=h)
        assert r.status_code == 200 and r.json()["archived"] is False
        d = await _detail(client, room_id, guest)
        assert d["room"]["name"] == "房"
        assert d["room"]["status"] == "active"


# ---------- 房主離開 ----------

async def test_admin_leaving_hands_over_to_the_next_human_by_join_order(tmp_path):
    """有別的人類在：直接交給**最早加入**的那位，不再擋下。

    agent 不算——它會被 presence sweeper 以閒置移除。
    """
    app, client = await _make(tmp_path, "auto_heir")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        admin = await _join(client, room_id, "owner", "Xavier")
        await _join(client, room_id, "a1", "Novia", role="agent", kind="claude")
        first = await _join(client, room_id, "guest1", "First")
        await _join(client, room_id, "guest2", "Second")

        r = await client.post(f"/api/rooms/{room_id}/leave", headers=_pid(admin))
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["admin_transferred_to"]["participant_id"] == \
            first["participant_id"]
        assert body["archived"] is False

        members = {m["display_name"]: m
                   for m in (await _detail(client, room_id, first))["participants"]}
        assert members["First"]["is_admin"] is True
        assert members["Xavier"]["status"] == "left"
        # 新管理員真的握得住：他改得了主題
        r = await client.post(f"/api/rooms/{room_id}/topic",
                              json={"topic": "接手"}, headers=_pid(first))
        assert r.status_code == 200, r.text
        events = await _system_events(client, room_id, first)
        assert "admin_transferred" in events
        assert "leave" in events


async def test_last_human_admin_is_told_leaving_archives(tmp_path):
    """沒有別的人類：不能默默封存，要先讓 App 問過人。"""
    app, client = await _make(tmp_path, "last_warn")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        admin = await _join(client, room_id, "owner", "Xavier")
        await _join(client, room_id, "a1", "Novia", role="agent", kind="claude")

        r = await client.post(f"/api/rooms/{room_id}/leave", headers=_pid(admin))
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "leave_will_archive"
        # 什麼都沒發生：房還開著、人還在
        d = await _detail(client, room_id, admin)
        assert d["room"]["status"] == "active"
        assert {m["display_name"]: m["status"]
                for m in d["participants"]}["Xavier"] == "active"


async def test_last_human_admin_confirming_archives_and_leaves(tmp_path):
    app, client = await _make(tmp_path, "last_confirm")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        admin = await _join(client, room_id, "owner", "Xavier")
        await _join(client, room_id, "a1", "Novia", role="agent", kind="claude")

        r = await client.post(f"/api/rooms/{room_id}/leave",
                              json={"archive_if_last": True},
                              headers=_pid(admin))
        assert r.status_code == 200, r.text
        assert r.json()["archived"] is True
        assert r.json()["admin_transferred_to"] is None

        row = await (await app.state.db.execute(
            "SELECT status FROM room WHERE id=?", (room_id,))).fetchone()
        assert row["status"] == "archived"
        prow = await (await app.state.db.execute(
            "SELECT status FROM participant WHERE id=?",
            (admin["participant_id"],))).fetchone()
        assert prow["status"] == "left"


async def test_archive_flag_does_not_archive_when_a_human_is_there(tmp_path):
    """旗標只在「沒有人可以接」時生效。確認框開著的時候有人進來，
    該交給他，不該把他的房封掉。"""
    app, client = await _make(tmp_path, "flag_with_heir")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        admin = await _join(client, room_id, "owner", "Xavier")
        guest = await _join(client, room_id, "guest", "Guest")

        r = await client.post(f"/api/rooms/{room_id}/leave",
                              json={"archive_if_last": True},
                              headers=_pid(admin))
        assert r.status_code == 200, r.text
        assert r.json()["archived"] is False
        assert r.json()["admin_transferred_to"]["participant_id"] == \
            guest["participant_id"]


async def test_non_admin_leave_is_unchanged(tmp_path):
    app, client = await _make(tmp_path, "plain_leave")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        await _join(client, room_id, "owner", "Xavier")
        guest = await _join(client, room_id, "guest", "Guest")
        r = await client.post(f"/api/rooms/{room_id}/leave", headers=_pid(guest))
        assert r.status_code == 200, r.text
        assert r.json()["admin_transferred_to"] is None
        assert r.json()["archived"] is False


# ---------- 刪除只對已封存的房 ----------

async def test_active_room_cannot_be_deleted(tmp_path):
    app, client = await _make(tmp_path, "del_active")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        r = await client.delete(f"/api/rooms/{room_id}",
                                headers={"X-Session-Key": "owner"})
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "room_not_archived"
        # 房還在
        row = await (await app.state.db.execute(
            "SELECT id FROM room WHERE id=?", (room_id,))).fetchone()
        assert row is not None


async def test_archived_room_can_be_deleted(tmp_path):
    app, client = await _make(tmp_path, "del_archived")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        hdr = {"X-Session-Key": "owner"}
        assert (await client.post(f"/api/rooms/{room_id}/archive",
                                  headers=hdr)).json()["archived"] is True
        r = await client.delete(f"/api/rooms/{room_id}", headers=hdr)
        assert r.status_code == 200, r.text
        assert r.json()["deleted"]["room"] == 1
