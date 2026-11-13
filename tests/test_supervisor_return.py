"""supervisor 離場即卸任（艾斯維爾 2026-11-12，取代「標記不清空、同 key 回來恢復」）。

離開的正是 supervisor 的 session_key 且房內已無同 key 的 active 成員時，
supervisor 欄位直接清空；同 key 重進不恢復，一律重新指定；他人離場不影響
「已指定、尚未進房」的 supervisor。
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
                          json={"kind": "human", "role": "human", "session_key": "owner-key",
                                "preferred_name": "Bernie"})
    return room, pid, r.json()["participant_id"]


async def _supervisor(client, room, me):
    r = await client.get(f"/api/rooms/{room}/board",
                         headers={"X-Participant-Id": me})
    assert r.status_code == 200, r.text
    return r.json()["supervisor"]


async def _supervisor(client, room, me):
    r = await client.get(f"/api/rooms/{room}/board",
                         headers={"X-Participant-Id": me})
    assert r.status_code == 200, r.text
    return r.json()["supervisor"]


async def _messages(client, room, me):
    r = await client.get(f"/api/rooms/{room}/messages",
                         params={"after_seq": 0},
                         headers={"X-Participant-Id": me})
    return r.json()["messages"]


async def _join_agent(client, room, key, name):
    r = await client.post(f"/api/rooms/{room}/join",
                          json={"kind": "codex", "session_key": key,
                                "preferred_name": name})
    assert r.status_code == 200, r.text
    return r.json()["participant_id"]


async def test_leaving_unseats_the_supervisor_and_mentions_humans(client):
    room, pid, me = await _setup(client)
    assert (await _supervisor(client, room, me))["actor_key"] == "agent-key"

    r = await client.post(f"/api/rooms/{room}/leave",
                          headers={"X-Participant-Id": pid})
    assert r.status_code == 200, r.text
    assert await _supervisor(client, room, me) is None, "欄位要清空"

    (msg,) = [m for m in await _messages(client, room, me)
              if m["system_event"] == "board_supervisor_left"]
    assert "Codex" in msg["content"]
    assert "已卸任" in msg["content"] and "重新指定" in msg["content"]
    assert "Bernie" in (msg["mentions"] or []), "要 mention 房內人類"


async def test_same_key_rejoining_does_not_restore(client):
    room, pid, me = await _setup(client)
    await client.post(f"/api/rooms/{room}/leave",
                      headers={"X-Participant-Id": pid})
    await _join_agent(client, room, "agent-key", "Codex")
    assert await _supervisor(client, room, me) is None
    events = [m["system_event"] for m in await _messages(client, room, me)]
    assert "board_supervisor_left" in events
    assert "board_supervisor_returned" not in events


async def test_a_different_key_is_not_the_supervisor(client):
    room, pid, me = await _setup(client)
    await client.post(f"/api/rooms/{room}/leave",
                      headers={"X-Participant-Id": pid})
    await _join_agent(client, room, "agent-key-2", "Codex")
    assert await _supervisor(client, room, me) is None


async def test_reappointing_restores_the_supervisor(client):
    room, pid, me = await _setup(client)
    await client.post(f"/api/rooms/{room}/leave",
                      headers={"X-Participant-Id": pid})
    back = await _join_agent(client, room, "agent-key", "Codex")
    r = await client.post(f"/api/rooms/{room}/board/supervisor",
                          json={"participant_id": back},
                          headers={"X-Session-Key": "owner-key"})
    assert r.status_code == 200, r.text
    sup = await _supervisor(client, room, me)
    assert sup["actor_key"] == "agent-key" and sup["departed"] is False


async def test_others_leaving_does_not_unseat_an_absent_supervisor(client):
    """先指定、人還沒進房：他人離場不得把它卸任（舊版會誤標）。"""
    room, pid, me = await _setup(client)
    await client.post(f"/api/rooms/{room}/leave",
                      headers={"X-Participant-Id": pid})
    r = await client.post(f"/api/rooms/{room}/board/supervisor",
                          json={"session_key": "ghost-key"},
                          headers={"X-Session-Key": "owner-key"})
    assert r.status_code == 200, r.text
    other = await _join_agent(client, room, "other-key", "路人")
    await client.post(f"/api/rooms/{room}/leave",
                      headers={"X-Participant-Id": other})
    sup = await _supervisor(client, room, me)
    assert sup is not None and sup["actor_key"] == "ghost-key"
    events = [m["system_event"] for m in await _messages(client, room, me)]
    assert events.count("board_supervisor_left") == 1, "只有第一次離場那則"


async def _legacy_db(tmp_path, name):
    from chatroom_server.db import open_db

    db_path = str(tmp_path / name)
    db = await open_db(db_path)
    for rid, left in (("r1", "2026-09-01T00:00:00Z"), ("r2", None)):
        await db.execute(
            "INSERT INTO room (id, name, topic, status, created_at, next_seq,"
            " board_supervisor_session_key, board_supervisor_name,"
            " board_supervisor_kind, board_supervisor_set_at,"
            " board_supervisor_left_at) VALUES"
            " (?,'房','','active','2026-09-01T00:00:00Z',1,"
            "  'agent-key','Codex','codex','2026-09-01T00:00:00Z',?)",
            (rid, left))
    await db.execute("PRAGMA user_version=12")
    await db.commit()
    await db.close()
    return db_path


async def test_migration_clears_supervisors_that_had_left(tmp_path):
    from chatroom_server.db import open_db

    db_path = await _legacy_db(tmp_path, "legacy.db")
    for _ in range(2):                  # 重跑（冪等）
        db = await open_db(db_path)
        rows = {r["id"]: r for r in await (await db.execute(
            "SELECT id, board_supervisor_session_key AS k,"
            " board_supervisor_name AS n, board_supervisor_left_at AS l"
            " FROM room")).fetchall()}
        assert rows["r1"]["k"] == "" and rows["r1"]["n"] == ""
        assert rows["r1"]["l"] is None
        assert rows["r2"]["k"] == "agent-key", "沒離開的不動"
        await db.close()


async def _setup_subagent_supervisor(client):
    """supervisor 是某個 agent 旗下的 subagent（set_board_supervisor 允許）。"""
    r = await client.post("/api/rooms",
                          json={"name": "房", "session_key": "owner-key"})
    room = r.json()["id"]
    r = await client.post(f"/api/rooms/{room}/join",
                          json={"kind": "human", "role": "human",
                                "session_key": "owner-key",
                                "preferred_name": "Bernie"})
    me = r.json()["participant_id"]
    parent = await _join_agent(client, room, "parent-key", "Parent")
    r = await client.post(f"/api/rooms/{room}/join",
                          json={"kind": "claude", "session_key": "parent-key#Sub-abc123",
                                "preferred_name": "Sub",
                                "parent_participant_id": parent})
    assert r.status_code == 200, r.text
    sub = r.json()["participant_id"]
    r = await client.post(f"/api/rooms/{room}/board/supervisor",
                          json={"participant_id": sub},
                          headers={"X-Session-Key": "owner-key"})
    assert r.status_code == 200, r.text
    assert (await _supervisor(client, room, me))["actor_key"] == "parent-key#Sub-abc123"
    return room, parent, me


async def test_parent_leaving_unseats_a_subagent_supervisor(client):
    room, parent, me = await _setup_subagent_supervisor(client)
    r = await client.post(f"/api/rooms/{room}/leave",
                          headers={"X-Participant-Id": parent})
    assert r.status_code == 200, r.text
    assert await _supervisor(client, room, me) is None, "subagent 已隨父層離開"
    events = [m["system_event"] for m in await _messages(client, room, me)]
    assert "board_supervisor_left" in events


async def test_parent_kicked_unseats_a_subagent_supervisor(client):
    room, parent, me = await _setup_subagent_supervisor(client)
    r = await client.post(f"/api/rooms/{room}/participants/{parent}/kick",
                          headers={"X-Participant-Id": me})
    assert r.status_code == 200, r.text
    assert await _supervisor(client, room, me) is None
