"""任務板設定頁的貢獻紀錄與板層設定（艾斯維爾 2026-09-24）。

- `GET /api/boards/{id}/contributions`：誰建了週期／階段／卡、誰完成了卡與
  階段、誰送審／確認／完成／打回週期、誰上板。**不另立事件表**——來源是
  `board_event`，補上稽核串補齊之前、只留在卡片欄位上的那一段。
- 改名與描述（`description`）只有板 owner；其他成員唯讀。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"


async def _client(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


async def _join(client, rid, key, name, role="agent"):
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "human" if role == "human" else "claude", "role": role,
        "session_key": key, "preferred_name": name})
    assert r.status_code == 200, r.text
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": key}


async def _setup(client):
    """人類 owner 建週期與階段，agent 建卡並做完。"""
    rid = (await client.post("/api/rooms", json={
        "name": "房", "session_key": "human-a"})).json()["id"]
    owner = await _join(client, rid, "human-a", "艾斯維爾", role="human")
    agent = await _join(client, rid, "agent-b", "諾薇亞")
    oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                             json={"title": "週期"},
                             headers=owner)).json()["id"]
    cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                             json={"title": "階段"},
                             headers=owner)).json()["id"]
    tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                             json={"title": "卡"},
                             headers=agent)).json()["id"]
    await client.post(f"/api/board/tasks/{tid}/claim", headers=agent)
    for step in ("in_progress", "done"):
        r = await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": step}, headers=agent)
        assert r.status_code == 200, r.text
    bid = (await client.get(f"/api/rooms/{rid}/board",
                            headers=owner)).json()["board_id"]
    return rid, bid, owner, agent, {"objective": oid, "checklist": cid,
                                    "task": tid}


async def _contrib(client, bid, hdr, **params):
    r = await client.get(f"/api/boards/{bid}/contributions",
                         params=params, headers=hdr)
    assert r.status_code == 200, r.text
    return r.json()


async def test_the_log_lists_who_did_what_newest_first(tmp_path):
    app, client = await _client(tmp_path, "log")
    async with app.router.lifespan_context(app), client:
        _, bid, owner, _, ids = await _setup(client)
        body = await _contrib(client, bid, owner)
        got = [(e["action"], e["actor_name"], e["title"])
               for e in body["entries"]]
        assert got == [
            ("task_done", "諾薇亞", "卡"),
            ("task_created", "諾薇亞", "卡"),
            ("checklist_created", "艾斯維爾", "階段"),
            ("objective_created", "艾斯維爾", "週期"),
        ], got
        assert not any(e["derived"] for e in body["entries"])
        # 認領、推 in_progress 不是貢獻
        assert {e["action"] for e in body["entries"]}.isdisjoint(
            {"task_claimed", "task_status"})


async def test_stats_count_per_person_over_the_whole_log(tmp_path):
    app, client = await _client(tmp_path, "stats")
    async with app.router.lifespan_context(app), client:
        _, bid, owner, _, _ = await _setup(client)
        body = await _contrib(client, bid, owner, limit=1)
        assert len(body["entries"]) == 1 and body["has_more"] is True
        assert body["total"] == 4
        stats = {s["actor_name"]: s for s in body["stats"]}
        assert stats["艾斯維爾"]["total"] == 2
        assert stats["艾斯維爾"]["actor_kind"] == "human"
        assert stats["諾薇亞"]["counts"] == {"task_created": 1,
                                            "task_done": 1}
        assert stats["諾薇亞"]["actor_kind"] == "claude"


async def test_history_before_the_audit_trail_is_derived_from_the_cards(
        tmp_path):
    """稽核串補齊之前的事只留在卡片欄位上：推得出來的標 derived。"""
    app, client = await _client(tmp_path, "derived")
    async with app.router.lifespan_context(app), client:
        _, bid, owner, _, ids = await _setup(client)
        await app.state.db.execute(
            "DELETE FROM board_event WHERE board_id=?", (bid,))
        await app.state.db.commit()
        body = await _contrib(client, bid, owner)
        got = {(e["action"], e["actor_name"], e["derived"])
               for e in body["entries"]}
        assert got == {
            ("objective_created", "艾斯維爾", True),
            ("checklist_created", "艾斯維爾", True),
            ("task_created", "諾薇亞", True),
            ("task_done", "諾薇亞", True),
        }, got


async def test_closing_a_stage_and_the_cycle_gates_count(tmp_path):
    app, client = await _client(tmp_path, "closing")
    async with app.router.lifespan_context(app), client:
        _, bid, owner, _, ids = await _setup(client)
        r = await client.post(
            f"/api/board/checklists/{ids['checklist']}/status",
            json={"status": "done"}, headers=owner)
        assert r.status_code == 200, r.text
        r = await client.post(
            f"/api/board/objectives/{ids['objective']}/review",
            headers=owner)
        assert r.status_code == 200, r.text
        body = await _contrib(client, bid, owner)
        actions = [e["action"] for e in body["entries"]]
        assert actions[:2] == ["objective_review", "checklist_done"], actions


async def test_only_board_members_can_read_the_log(tmp_path):
    app, client = await _client(tmp_path, "members")
    async with app.router.lifespan_context(app), client:
        _, bid, _, _, _ = await _setup(client)
        other = (await client.post("/api/rooms", json={
            "name": "別房", "session_key": "stranger"})).json()["id"]
        stranger = await _join(client, other, "stranger", "路人")
        r = await client.get(f"/api/boards/{bid}/contributions",
                             headers=stranger)
        assert r.status_code == 403
        assert r.json()["detail"]["code"] == "not_board_member"


async def test_settings_meta_and_owner_only_topic(tmp_path):
    """設定頁的「描述」就是板的 description；只有 owner 改得動，其他人照樣讀得到。"""
    app, client = await _client(tmp_path, "topic")
    async with app.router.lifespan_context(app), client:
        _, bid, owner, agent, _ = await _setup(client)
        r = await client.patch(f"/api/boards/{bid}",
                               json={"description": "路人改的"}, headers=agent)
        assert r.status_code == 403
        assert r.json()["detail"]["code"] == "not_board_owner"

        r = await client.patch(f"/api/boards/{bid}",
                               json={"name": "新板名", "description": "新描述"},
                               headers=owner)
        assert r.status_code == 200, r.text

        meta = (await _contrib(client, bid, agent))["board"]
        assert (meta["name"], meta["description"]) == ("新板名", "新描述")
        assert meta["my_role"] != "owner"
        assert meta["owner_name"] == "艾斯維爾"
        assert (await _contrib(client, bid, owner))["board"]["my_role"] \
            == "owner"
