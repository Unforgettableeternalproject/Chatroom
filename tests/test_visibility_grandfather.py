"""房間改成私人時，**當時已經在裡面的人不會被關在門外**。

`test_room_visibility` 蓋住了兩半，但沒蓋住中間那一半：
- 「私人房的成員看得到它」——房是**建立時**就私人
- 「改可見度」——只驗了 outsider 看不看得到

中間漏掉的是**時序**：public 房先有成員，之後才鎖起來。那些人當時在場，
房間不該從他們的列表上憑空消失——而這正是 N-1「既有成員列入白名單、
保留存取直到被踢」要保證的東西。

保證目前來自 `list_rooms` 那句
`EXISTS (participant WHERE session_key=? AND status!='kicked')`，
與 `visibility` 是 OR 關係，所以鎖房不影響既有成員。**沒有測試釘著它**：
哪天有人把那句改成 AND、或在私人房分支裡漏掉它，症狀是「某些人的房間
不見了」，而那看起來像 client 的 bug。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio


async def _make(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token="")
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test")


async def _room_ids(client, session_key):
    r = await client.get("/api/rooms", params={"session_key": session_key})
    assert r.status_code == 200, r.text
    return [x["id"] for x in r.json()["rooms"]]


async def _lock(client, rid, visibility="private"):
    r = await client.post(f"/api/rooms/{rid}/visibility",
                          json={"visibility": visibility},
                          headers={"X-Session-Key": "admin"})
    assert r.status_code == 200, r.text
    return r.json()


async def test_member_keeps_access_after_the_room_is_locked(tmp_path):
    """先加入、後鎖房——他當時在場，房間不該從列表上消失。"""
    app, client = await _make(tmp_path, "gf_member")
    async with client, app.router.lifespan_context(app):
        rid = (await client.post("/api/rooms", json={
            "name": "房", "session_key": "admin", "visibility": "public"
        })).json()["id"]

        joined = await client.post(f"/api/rooms/{rid}/join", json={
            "kind": "claude", "session_key": "sess-member",
            "preferred_name": "既有成員"})
        assert joined.status_code == 200, joined.text

        assert rid in await _room_ids(client, "sess-member")
        assert rid in await _room_ids(client, "sess-outsider"), "鎖之前公開房人人看得到"

        await _lock(client, rid)

        assert rid in await _room_ids(client, "sess-member"), (
            "鎖房把既有成員一起關在門外了——白名單失效"
        )
        assert rid not in await _room_ids(client, "sess-outsider")


async def test_member_who_left_still_keeps_access_after_locking(tmp_path):
    """離開不等於被踢：他在場過，鎖房之後仍看得見。"""
    app, client = await _make(tmp_path, "gf_left")
    async with client, app.router.lifespan_context(app):
        rid = (await client.post("/api/rooms", json={
            "name": "房", "session_key": "admin", "visibility": "public"
        })).json()["id"]
        pid = (await client.post(f"/api/rooms/{rid}/join", json={
            "kind": "claude", "session_key": "sess-left",
            "preferred_name": "走了的人"})).json()["participant_id"]

        await client.post(f"/api/rooms/{rid}/leave",
                          headers={"X-Participant-Id": pid})
        await _lock(client, rid)

        assert rid in await _room_ids(client, "sess-left")


async def test_kick_is_the_one_thing_that_removes_access(tmp_path):
    """白名單的出口只有一個：被踢。"""
    app, client = await _make(tmp_path, "gf_kick")
    async with client, app.router.lifespan_context(app):
        rid = (await client.post("/api/rooms", json={
            "name": "房", "session_key": "admin", "visibility": "public"
        })).json()["id"]
        # 踢人走 X-Participant-Id，所以管理員得先自己進房
        admin_pid = (await client.post(f"/api/rooms/{rid}/join", json={
            "kind": "human", "session_key": "admin", "role": "human",
            "preferred_name": "Xavier"})).json()["participant_id"]
        pid = (await client.post(f"/api/rooms/{rid}/join", json={
            "kind": "claude", "session_key": "sess-kicked",
            "preferred_name": "會被踢的人"})).json()["participant_id"]

        await _lock(client, rid)
        assert rid in await _room_ids(client, "sess-kicked")

        r = await client.post(
            f"/api/rooms/{rid}/participants/{pid}/kick",
            headers={"X-Participant-Id": admin_pid})
        assert r.status_code == 200, r.text

        assert rid not in await _room_ids(client, "sess-kicked"), (
            "被踢之後仍看得到私人房——白名單沒有出口"
        )
