"""T-07：Supervisor。

三個要害：

1. **設定的當下對方多半還沒進房**——那正是要用指派把它叫進來的情形。
   所以退場判定只能接在離場路徑上，做成定期檢查的話設定完的下一輪掃描
   就會把它自己清掉，而且清得完全合乎規則。
2. **退場是標記不是清空**。清空連名字都不留，畫面上與「從來沒有指定過」
   一模一樣——連「本來有人在看」這件事都消失了。
3. **摘要不逐筆**。supervisor 也是一個會被塞滿的 agent。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"


async def _client(tmp_path, name, **kw):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT, **kw)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


async def _join(client, rid, session_key, name, role="agent"):
    kind = "human" if role == "human" else "claude"
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": kind, "role": role, "session_key": session_key,
        "preferred_name": name})
    return {"X-Participant-Id": r.json()["participant_id"]}


async def _room(client):
    rid = (await client.post("/api/rooms", json={
        "name": "板子房", "session_key": "human-1"})).json()["id"]
    owner = await _join(client, rid, "human-1", "Bernie", role="human")
    return rid, owner


async def _events(client, rid, hdr, event):
    msgs = (await client.get(f"/api/rooms/{rid}/messages",
                             headers=hdr)).json()["messages"]
    return [m for m in msgs if m["system_event"] == event]


async def test_can_appoint_someone_not_in_the_room_yet(tmp_path):
    """被指定的對象在設定當下多半還沒進房——那正是要指派它進來的情形。"""
    app, client = await _client(tmp_path, "not-yet")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        r = await client.post(f"/api/rooms/{rid}/board/supervisor",
                              json={"session_key": "claude-not-here-yet"},
                              headers=owner)
        assert r.status_code == 200, r.text
        assert r.json()["in_room"] is False
        board = (await client.get(f"/api/rooms/{rid}/board",
                                  headers=owner)).json()
        assert board["supervisor"] == "claude-not-here-yet"


async def test_only_the_creator_can_appoint(tmp_path):
    app, client = await _client(tmp_path, "perm")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        other = await _join(client, rid, "agent-1", "Novia")
        r = await client.post(f"/api/rooms/{rid}/board/supervisor",
                              json={"session_key": "agent-1"}, headers=other)
        assert r.status_code == 403
        assert r.json()["detail"]["code"] == "not_admin"


async def test_departure_marks_and_announces_but_does_not_erase(tmp_path):
    """清空會讓畫面與「從來沒有指定過」一模一樣，那是同一個病更嚴重的版本。"""
    app, client = await _client(tmp_path, "left")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        sup = await _join(client, rid, "agent-sup", "Nova")
        await client.post(f"/api/rooms/{rid}/board/supervisor",
                          json={"session_key": "agent-sup"}, headers=owner)

        await client.post(f"/api/rooms/{rid}/leave", headers=sup)

        board = (await client.get(f"/api/rooms/{rid}/board",
                                  headers=owner)).json()
        assert board["supervisor"] == "agent-sup", "名字不能被抹掉"
        (msg,) = await _events(client, rid, owner, "board_supervisor_left")
        assert "Nova" in msg["content"]
        assert "重新指定" in msg["content"]


async def test_departure_is_announced_once_not_every_time(tmp_path):
    """已經標記過就不再公告——否則每次有人離開都會再喊一次同一件事。"""
    app, client = await _client(tmp_path, "once")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        sup = await _join(client, rid, "agent-sup", "Nova")
        other = await _join(client, rid, "agent-2", "Miller")
        await client.post(f"/api/rooms/{rid}/board/supervisor",
                          json={"session_key": "agent-sup"}, headers=owner)
        await client.post(f"/api/rooms/{rid}/leave", headers=sup)
        await client.post(f"/api/rooms/{rid}/leave", headers=other)
        assert len(await _events(client, rid, owner,
                                 "board_supervisor_left")) == 1


async def test_appointment_survives_a_restart_of_the_agent(tmp_path):
    """supervisor 是角色不是身分：換一個 participant 回來，角色還在。"""
    app, client = await _client(tmp_path, "role")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        sup = await _join(client, rid, "agent-sup", "Nova")
        await client.post(f"/api/rooms/{rid}/board/supervisor",
                          json={"session_key": "agent-sup"}, headers=owner)
        await client.post(f"/api/rooms/{rid}/leave", headers=sup)
        again = await _join(client, rid, "agent-sup", "Nova")
        board = (await client.get(f"/api/rooms/{rid}/board",
                                  headers=again)).json()
        assert board["supervisor"] == "agent-sup"


async def test_cancelling_leaves_a_record(tmp_path):
    app, client = await _client(tmp_path, "cancel")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        await client.post(f"/api/rooms/{rid}/board/supervisor",
                          json={"session_key": "agent-sup"}, headers=owner)
        r = await client.post(f"/api/rooms/{rid}/board/supervisor",
                              json={"session_key": ""}, headers=owner)
        assert r.status_code == 200
        assert r.json()["supervisor"] is None
        board = (await client.get(f"/api/rooms/{rid}/board",
                                  headers=owner)).json()
        assert board["supervisor"] is None
        assert len(await _events(client, rid, owner,
                                 "board_supervisor_set")) == 2


async def test_digest_batches_changes_and_mentions_only_the_supervisor(tmp_path):
    """摘要不逐筆——supervisor 也是一個會被塞滿的 agent。"""
    app, client = await _client(tmp_path, "digest",
                                board_digest_interval=0.0, sweep_interval=3600)
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        sup = await _join(client, rid, "agent-sup", "Nova")
        await client.post(f"/api/rooms/{rid}/board/supervisor",
                          json={"session_key": "agent-sup"}, headers=owner)

        for i in range(3):
            await client.post(f"/api/rooms/{rid}/board/objectives",
                              json={"title": f"週期{i}"}, headers=owner)

        await app.state.sweep_once()

        digests = await _events(client, rid, owner, "board_digest")
        assert len(digests) == 1, "三次變動應該收成一則"
        assert digests[0]["mentions"] == ["Nova"], "只叫醒 supervisor"
        assert "週期 3 項" in digests[0]["content"]


async def test_digest_does_not_repeat_what_it_already_reported(tmp_path):
    app, client = await _client(tmp_path, "digest-cursor",
                                board_digest_interval=0.0, sweep_interval=3600)
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        await _join(client, rid, "agent-sup", "Nova")
        await client.post(f"/api/rooms/{rid}/board/supervisor",
                          json={"session_key": "agent-sup"}, headers=owner)
        await client.post(f"/api/rooms/{rid}/board/objectives",
                          json={"title": "週期一"}, headers=owner)
        await app.state.sweep_once()
        await app.state.sweep_once()      # 沒有新變動 → 不該再發
        assert len(await _events(client, rid, owner, "board_digest")) == 1


async def test_no_supervisor_means_no_digest(tmp_path):
    app, client = await _client(tmp_path, "no-sup",
                                board_digest_interval=0.0, sweep_interval=3600)
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        await client.post(f"/api/rooms/{rid}/board/objectives",
                          json={"title": "週期一"}, headers=owner)
        await app.state.sweep_once()
        assert await _events(client, rid, owner, "board_digest") == []


async def test_a_departed_supervisor_stops_receiving_digests(tmp_path):
    """已經不在房內的人不該繼續被 mention——那個 mention 不會有人收到。"""
    app, client = await _client(tmp_path, "sup-gone",
                                board_digest_interval=0.0, sweep_interval=3600)
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        sup = await _join(client, rid, "agent-sup", "Nova")
        await client.post(f"/api/rooms/{rid}/board/supervisor",
                          json={"session_key": "agent-sup"}, headers=owner)
        await client.post(f"/api/rooms/{rid}/leave", headers=sup)
        await client.post(f"/api/rooms/{rid}/board/objectives",
                          json={"title": "週期一"}, headers=owner)
        await app.state.sweep_once()
        assert await _events(client, rid, owner, "board_digest") == []
