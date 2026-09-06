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
            await client.post(f"/api/rooms/{room_id}/unarchive", headers={"X-Session-Key": "owner-key"})
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
            room_a = (await client.post("/api/rooms", json={"session_key": "creator", "name": "A"})).json()["id"]
            room_b = (await client.post("/api/rooms", json={"session_key": "creator", "name": "B"})).json()["id"]
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
            await client.post(f"/api/rooms/{room_id}/archive", headers={"X-Session-Key": "owner-key"})

            r = await client.post(
                f"/api/rooms/{room_id}/messages", json={"content": "x"}, headers=headers
            )
            assert r.status_code == 409
            r = await client.post(f"/api/messages/{mid}/pin", headers=headers)
            assert r.status_code == 409
            r = await client.delete(f"/api/messages/{mid}/pin", headers=headers)
            assert r.status_code == 409

            # 人類軟刪除（管控）與成員離開仍允許
            # 建立者自報 session key 就刪得掉（他還沒 join 自己的房）
            assert (await client.delete(
                f"/api/messages/{mid}",
                headers={"X-Session-Key": "owner-key"})).status_code == 200
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

            r = await client.post(f"/api/rooms/{room_id}/unarchive", headers={"X-Session-Key": "owner-key"})
            assert r.json()["already_active"] is True

            await client.post(f"/api/rooms/{room_id}/archive", headers={"X-Session-Key": "owner-key"})
            await client.post(f"/api/rooms/{room_id}/unarchive", headers={"X-Session-Key": "owner-key"})
            msgs = (await client.get(
                f"/api/rooms/{room_id}/messages",
                headers={"X-Participant-Id": s1["participant_id"]})).json()["messages"]
            contents = [m["content"] for m in msgs if m["kind"] == "system"]
            assert "聊天室已被手動封存" in contents
            assert "聊天室已解除封存" in contents
            # 冪等解封不會多留一則訊息
            assert contents.count("聊天室已解除封存") == 1


# ---------------------------------------------------------------------------
# 建房一定要說出你是誰（09/06 卡 48da086a，@測試Novia 佈景時撞到）
#
# `POST /api/rooms` 的 session_key 讀的是 **request body**，而它原本是選填 ⇒
# 不帶不會有任何錯誤：回 200、房建起來、`creator_session_key` 是空字串，
# 於是**你不是自己那間房的管理者**。
#
# 難查的地方在於症狀不在因果現場：實際看到的是三步之後的
# 「建板 403 not_room_admin」，而那句話完全指不回「建房時漏了 body 欄位」。
# 撞到的人第一反應是憑證放錯位置（試 header、試 query），兩個都不是它讀的
# 地方——這個 Hub 上「你是誰」有四種傳法，建房是其中最不像的那一種。
#
# 止血：失敗要發生在建房那一刻。
# ---------------------------------------------------------------------------


async def test_creating_a_room_without_a_session_key_is_refused(tmp_path):
    """沒說你是誰就不給建——否則建出來的是一間沒有管理者的房。"""
    app, client = await _make_client(tmp_path, "room_needs_key")
    async with client, app.router.lifespan_context(app):
        r = await client.post("/api/rooms", json={"name": "沒有主人的房"})
        assert r.status_code == 422, r.text


async def test_an_empty_session_key_is_refused_too(tmp_path):
    """空字串與沒帶是同一件事——擋掉前者才擋得住這個 bug 的實際形狀。

    `creator_session_key` 存的就是空字串，所以只擋 `null` 的話，送 `""`
    照樣建得出無主房，而那條路徑看起來完全合法。
    """
    app, client = await _make_client(tmp_path, "room_empty_key")
    async with client, app.router.lifespan_context(app):
        r = await client.post("/api/rooms",
                              json={"name": "空鑰匙", "session_key": ""})
        assert r.status_code == 422, r.text


async def test_the_creator_really_becomes_the_admin(tmp_path):
    """正向那半：帶了就真的是管理者。

    ⚠️ 這條與上面兩條一起才完整。只驗「擋得住」的話，把欄位改成必填卻同時
    寫錯欄位名，兩條照樣綠——而那時每一間房都沒有管理者。
    """
    app, client = await _make_client(tmp_path, "room_admin_ok")
    async with client, app.router.lifespan_context(app):
        rid = (await client.post("/api/rooms", json={
            "name": "有主人的房", "session_key": "boss"})).json()["id"]
        await _join(client, rid, "boss", "老闆", kind="human")

        # 管理者才做得到的事：改可見性
        r = await client.post(f"/api/rooms/{rid}/visibility",
                              json={"visibility": "private"},
                              headers={"X-Session-Key": "boss"})
        assert r.status_code == 200, r.text
