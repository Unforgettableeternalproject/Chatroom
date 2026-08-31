"""封存與收回邀請的身分門檻（審核用Codex 的 F2 / F6）。

同一條原則的第五、六次套用：**token 管的是「能不能連進來」，房內的事由房
內判**。今天已經在刪除、編輯、指派回應、指派收回上各套過一次。

F2：``archive`` / ``unarchive`` 完全不驗身分——任何持 token 者可以封存或解封
**任意房間**。封存讓整個房變成唯讀，而房裡的人可能正在工作。

F6：``cancel_assignment`` 自稱是房內的管理動作，卻沿用 ``_creator_or_member``
→ ``_member_or_403``，而後者**刻意放行歷史成員**（讀取邊界）。於是離開過的
人仍能撤回這個房的邀請。

兩者的修法是同一個：**寫入/管理動作要求此刻的成員資格**，讀取維持現狀。
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


async def _join(client, room_id, session_key, name, role="human"):
    r = await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": "human" if role == "human" else "claude", "role": role,
              "session_key": session_key, "preferred_name": name},
    )
    assert r.status_code == 200, r.text
    return r.json()


async def _room(client, owner="owner"):
    return (await client.post(
        "/api/rooms", json={"name": "房", "session_key": owner})).json()["id"]


# ---------- F2：封存 ----------

async def test_outsider_cannot_archive(tmp_path):
    """房外的人不能把別人的房關掉——封存讓整個房唯讀，而裡面的人在工作。"""
    app, client = await _make_client(tmp_path, "arch-outsider")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            r = await client.post(f"/api/rooms/{room_id}/archive",
                                  headers={"X-Session-Key": "nobody"})
            assert r.status_code in (401, 403), r.text
            det = (await client.get(f"/api/rooms/{room_id}",
                   headers={"X-Session-Key": "owner"})).json()
            assert det["room"]["status"] == "active"


async def test_creator_can_archive(tmp_path):
    """建立者可以——他還沒 join 自己的房時只有 session key 可自報。"""
    app, client = await _make_client(tmp_path, "arch-creator")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            r = await client.post(f"/api/rooms/{room_id}/archive",
                                  headers={"X-Session-Key": "owner"})
            assert r.status_code == 200, r.text


async def test_outsider_cannot_unarchive(tmp_path):
    """解封同理。封存與解封是同一道門的兩面，只擋一邊等於沒擋。"""
    app, client = await _make_client(tmp_path, "unarch-outsider")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            await client.post(f"/api/rooms/{room_id}/archive",
                              headers={"X-Session-Key": "owner"})
            r = await client.post(f"/api/rooms/{room_id}/unarchive",
                                  headers={"X-Session-Key": "nobody"})
            assert r.status_code in (401, 403), r.text


async def test_member_can_archive(tmp_path):
    """房內成員算數——封存是房內的管理動作，不是建立者的私產。

    與 cancel 同一條界線；若最終裁定收緊到只有建立者，這條要跟著改，但兩個
    端點必須一致，不能一個寬一個嚴。
    """
    app, client = await _make_client(tmp_path, "arch-member")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            me = await _join(client, room_id, "s-a", "Alpha")
            r = await client.post(
                f"/api/rooms/{room_id}/archive",
                headers={"X-Participant-Id": me["participant_id"]})
            assert r.status_code == 200, r.text


# ---------- F6：收回邀請 ----------

async def _pending_assignment(client, room_id, target="target-key"):
    return (await client.post(
        f"/api/rooms/{room_id}/assignments",
        json={"target_session_key": target, "note": "來幫忙"},
        headers={"X-Session-Key": "owner"},
    )).json()["id"]


async def test_a_member_who_left_cannot_cancel(tmp_path):
    """離開過的人不能再撤回這個房的邀請。

    ``_member_or_403`` 刻意放行歷史成員——**那個寬鬆是給讀取的**。收回邀請
    是管理動作，要求的是此刻的成員資格。
    """
    app, client = await _make_client(tmp_path, "cancel-left")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            me = await _join(client, room_id, "s-a", "Alpha")
            pid = me["participant_id"]
            aid = await _pending_assignment(client, room_id)
            await client.post(f"/api/rooms/{room_id}/leave",
                              headers={"X-Participant-Id": pid})

            r = await client.delete(f"/api/assignments/{aid}",
                                    headers={"X-Participant-Id": pid})
            assert r.status_code in (401, 403), r.text


async def test_an_active_member_can_still_cancel(tmp_path):
    """對照組：還在房裡的成員照樣做得到。收緊不可以把正當路徑一起關掉。"""
    app, client = await _make_client(tmp_path, "cancel-active")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            me = await _join(client, room_id, "s-a", "Alpha")
            aid = await _pending_assignment(client, room_id)
            r = await client.delete(
                f"/api/assignments/{aid}",
                headers={"X-Participant-Id": me["participant_id"]})
            assert r.status_code == 200, r.text


async def test_creator_can_cancel_without_joining(tmp_path):
    """建立者不必先進房——指派 UI 正開在那個空窗上（房主邀人時還沒進去）。"""
    app, client = await _make_client(tmp_path, "cancel-creator")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            aid = await _pending_assignment(client, room_id)
            r = await client.delete(f"/api/assignments/{aid}",
                                    headers={"X-Session-Key": "owner"})
            assert r.status_code == 200, r.text


async def test_reading_assignment_history_stays_open_to_past_members(tmp_path):
    """反向守衛：收緊 cancel 不可以連帶收掉**讀取**指派歷史。

    離開過的人回頭看「當時誰被邀請進來」是正當的，與讀訊息歷史同一條界線。
    修 F6 時最容易順手把這個也收掉。
    """
    app, client = await _make_client(tmp_path, "cancel-read")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            me = await _join(client, room_id, "s-a", "Alpha")
            pid = me["participant_id"]
            await _pending_assignment(client, room_id)
            await client.post(f"/api/rooms/{room_id}/leave",
                              headers={"X-Participant-Id": pid})

            r = await client.get(f"/api/rooms/{room_id}/assignments",
                                 headers={"X-Participant-Id": pid})
            assert r.status_code == 200, r.text
            assert len(r.json()["assignments"]) == 1


# ---------- F5 server 半：重複撤回 ----------

async def test_deleting_an_already_deleted_message_is_rejected(tmp_path):
    """重複撤回要擋。

    不擋的話它會再推進一次 ``update_seq``，讓那則訊息重新入流——而 watcher
    看到一則「現在是 deleted」的訊息，於是再發一次撤回事件。**同一件事被
    通知兩次，而第二次什麼都沒發生。**
    """
    app, client = await _make_client(tmp_path, "double-delete")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            me = await _join(client, room_id, "s-a", "Alpha")
            pid = me["participant_id"]
            mid = (await client.post(
                f"/api/rooms/{room_id}/messages", json={"content": "話"},
                headers={"X-Participant-Id": pid})).json()["id"]

            first = await client.delete(f"/api/messages/{mid}",
                                        headers={"X-Participant-Id": pid})
            assert first.status_code == 200, first.text
            second = await client.delete(f"/api/messages/{mid}",
                                         headers={"X-Participant-Id": pid})
            assert second.status_code == 422, second.text
            assert second.json()["detail"]["code"] == "message_deleted"


# ---------- 反向守衛：收緊寫入不得連帶收掉讀取 ----------

async def test_leaving_does_not_destroy_read_access(tmp_path):
    """反向守衛：收緊**寫入**不可以連帶收掉讀取。

    `_member_or_403` 刻意允許已離開者回頭讀歷史——要求 active 會讓
    「離開房間」變成「銷毀自己的紀錄」，那不是離開的意思。修寫入路徑時
    很容易順手把讀取也一起收掉，這條就是為了讓那件事會紅。
    """
    app, client = await _make_client(tmp_path, "left-read")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post(
                "/api/rooms", json={"name": "房", "session_key": "owner"})
            ).json()["id"]
            me = await _join(client, room_id, "s-a", "Alpha")
            pid = me["participant_id"]
            await client.post(f"/api/rooms/{room_id}/messages",
                              json={"content": "留下的話"},
                              headers={"X-Participant-Id": pid})
            await client.post(f"/api/rooms/{room_id}/leave",
                              headers={"X-Participant-Id": pid})

            r = await client.get(f"/api/rooms/{room_id}/messages",
                                 headers={"X-Participant-Id": pid})
            assert r.status_code == 200, r.text
            assert any(m["content"] == "留下的話"
                       for m in r.json()["messages"])
