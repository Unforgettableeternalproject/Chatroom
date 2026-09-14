"""supervisor 回來了，`departed` 要跟著解除。

`board_supervisor_left_at` 只在離場路徑被設，而**沒有任何地方在他回來時
清掉它**——`departed` 完全由這個欄位推導。於是被閒置移出過一次的
supervisor，即使重新加入，畫面上永遠寫著「已離開・需要重新指定」，
除非有人重新指定一次（2026-09-14 艾斯維爾在畫面上抓到）。

標記本身是對的（見 `_check_supervisor_departed`：標記不是清空，畫面要
說得出「本來是誰在看」）。缺的是回來時的那一半。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio


@pytest.fixture
async def client(tmp_path):
    cfg = Config(db_path=str(tmp_path / "t.db"), api_token="")
    app = create_app(cfg)
    c = AsyncClient(transport=ASGITransport(app=app), base_url="http://test")
    async with c:
        async with app.router.lifespan_context(app):
            yield c


async def _setup(client):
    r = await client.post("/api/rooms",
                          json={"name": "房", "session_key": "owner-key"})
    room = r.json()["id"]
    r = await client.post(f"/api/rooms/{room}/join",
                          json={"kind": "codex", "session_key": "agent-key",
                                "preferred_name": "Codex"})
    pid = r.json()["participant_id"]
    r = await client.post(f"/api/rooms/{room}/board/supervisor",
                          json={"participant_id": pid},
                          headers={"X-Session-Key": "owner-key"})
    assert r.status_code == 200, r.text
    # 讀板也是房內動作，要有身分
    r = await client.post(f"/api/rooms/{room}/join",
                          json={"kind": "human", "session_key": "owner-key",
                                "preferred_name": "Bernie"})
    return room, pid, r.json()["participant_id"]


async def _supervisor(client, room, me):
    r = await client.get(f"/api/rooms/{room}/board",
                         headers={"X-Participant-Id": me})
    assert r.status_code == 200, r.text
    return r.json()["supervisor"]


async def test_departed_clears_when_the_supervisor_comes_back(client):
    room, pid, me = await _setup(client)
    assert (await _supervisor(client, room, me))["departed"] is False

    r = await client.post(f"/api/rooms/{room}/leave",
                          headers={"X-Participant-Id": pid})
    assert r.status_code == 200, r.text
    assert (await _supervisor(client, room, me))["departed"] is True, "走了要標記"

    # 同一把 key 回來——supervisor 存的是 session_key 而不是 participant_id，
    # 正是為了讓「角色」跨越重啟
    r = await client.post(f"/api/rooms/{room}/join",
                          json={"kind": "codex", "session_key": "agent-key",
                                "preferred_name": "Codex"})
    assert r.status_code == 200, r.text
    assert (await _supervisor(client, room, me))["departed"] is False, \
        "回來了就不該再寫著已離開"


async def test_the_room_is_told_he_came_back(client):
    """離開會公告「需要重新指定」，回來不公告的話，看過那則的人不會知道
    它已經解決了——而畫面上那個提示也不再對得上任何東西。"""
    room, pid, me = await _setup(client)
    await client.post(f"/api/rooms/{room}/leave",
                      headers={"X-Participant-Id": pid})
    await client.post(f"/api/rooms/{room}/join",
                      json={"kind": "codex", "session_key": "agent-key",
                            "preferred_name": "Codex"})
    r = await client.get(f"/api/rooms/{room}/messages",
                         params={"after_seq": 0},
                         headers={"X-Participant-Id": me})
    events = [m["system_event"] for m in r.json()["messages"]]
    assert "board_supervisor_left" in events
    assert "board_supervisor_returned" in events


async def test_someone_else_joining_does_not_clear_it(client):
    """別人進來不算 supervisor 回來——清掉的話畫面會說「有人在看」，
    而實際上沒有。"""
    room, pid, me = await _setup(client)
    await client.post(f"/api/rooms/{room}/leave",
                      headers={"X-Participant-Id": pid})
    await client.post(f"/api/rooms/{room}/join",
                      json={"kind": "claude", "session_key": "someone-else",
                            "preferred_name": "路人"})
    assert (await _supervisor(client, room, me))["departed"] is True


async def test_stale_departed_is_cleared_on_upgrade(tmp_path):
    """行為修好了，救不了已經卡住的那些。

    join 路徑的解除只管**之後**的加入。在修好之前就已經回來的 supervisor
    身上仍掛著標記，而他不會再加入第二次——今天早上 `label_self_reported`
    踩的是同一個形狀：改預設值救不了已經加過欄的 DB。
    """
    from chatroom_server.db import open_db

    db_path = str(tmp_path / "legacy.db")
    db = await open_db(db_path)
    await db.execute(
        "INSERT INTO room (id, name, topic, status, created_at, next_seq,"
        " board_supervisor_session_key, board_supervisor_name,"
        " board_supervisor_left_at) VALUES"
        " ('r1','房','','active','2026-09-01T00:00:00Z',1,"
        "  'agent-key','Codex','2026-09-01T00:00:00Z')")
    # 他其實已經回來了
    await db.execute(
        "INSERT INTO participant (id, room_id, session_key, kind, display_name,"
        " role, status, joined_at, last_seen_at) VALUES"
        " ('p1','r1','agent-key','codex','Codex','member','active',"
        "  '2026-09-01T00:00:00Z','2026-09-01T00:00:00Z')")
    await db.execute("PRAGMA user_version=2")
    await db.commit()
    await db.close()

    db = await open_db(db_path)
    row = await (await db.execute(
        "SELECT board_supervisor_left_at FROM room WHERE id='r1'")).fetchone()
    assert row["board_supervisor_left_at"] == "", "人在房內就不該還掛著已離開"
    await db.close()


async def test_a_supervisor_who_really_left_keeps_the_mark(tmp_path):
    """真的還沒回來的維持標記——那個標記本來就是要說出
    「本來是誰在看，但他走了」。"""
    from chatroom_server.db import open_db

    db_path = str(tmp_path / "legacy2.db")
    db = await open_db(db_path)
    await db.execute(
        "INSERT INTO room (id, name, topic, status, created_at, next_seq,"
        " board_supervisor_session_key, board_supervisor_name,"
        " board_supervisor_left_at) VALUES"
        " ('r1','房','','active','2026-09-01T00:00:00Z',1,"
        "  'agent-key','Codex','2026-09-01T00:00:00Z')")
    await db.execute("PRAGMA user_version=2")
    await db.commit()
    await db.close()

    db = await open_db(db_path)
    row = await (await db.execute(
        "SELECT board_supervisor_left_at FROM room WHERE id='r1'")).fetchone()
    assert row["board_supervisor_left_at"] != ""
    await db.close()
