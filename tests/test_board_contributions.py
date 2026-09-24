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


async def _run_agent(client, rid, owner):
    """執行器領單起的 run agent 以 `claude-run-<run_id>` 進房。"""
    db = client.hub_app.state.db
    # 派工要房間綁了工作區（Hub 契約）；綁定端點本身的契約不在這裡測
    await db.execute("UPDATE room SET kind='ops', workspace_key=? WHERE id=?",
                     ("ai-website", rid))
    await db.commit()
    r = await client.post("/api/runners/register",
                          json={"host": "esvel-pc", "label": "ex1",
                                "projects": ["ai-website"],
                                "max_parallel": 3, "version": "0.1"})
    assert r.status_code == 200, r.text
    runner = r.json()["runner"]["id"]
    rhdr = {"X-Runner-Token": r.json()["runner_token"]}
    r = await client.post(f"/api/rooms/{rid}/runs",
                          json={"kind": "investigate",
                                "project": "ai-website",
                                "ref": "task-1", "brief": "查一下"},
                          headers=owner)
    assert r.status_code == 200, r.text
    run_id = r.json()["run"]["id"]
    await client.post(f"/api/runners/{runner}/claim", headers=rhdr)
    await client.post(f"/api/runs/{run_id}/report",
                      json={"status": "running", "runner_id": runner},
                      headers=rhdr)
    key = f"claude-run-{run_id}"
    j = await client.post(f"/api/rooms/{rid}/join",
                          json={"kind": "claude", "role": "agent",
                                "session_key": key,
                                "preferred_name": "Runner"})
    assert j.status_code == 200, j.text
    return key, {"X-Participant-Id": j.json()["participant_id"],
                 "X-Session-Key": key}


async def _run_agent_makes_a_card(client, ids, run_hdr):
    tid = (await client.post(
        f"/api/board/checklists/{ids['checklist']}/tasks",
        json={"title": "run 的卡"}, headers=run_hdr)).json()["id"]
    await client.post(f"/api/board/tasks/{tid}/claim", headers=run_hdr)
    for step in ("in_progress", "done"):
        r = await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": step}, headers=run_hdr)
        assert r.status_code == 200, r.text
    return tid


def _assert_run_agent_absent(body, key):
    """run agent 不在紀錄、不在統計；一般 agent 與人類照常在。"""
    assert all(e["actor_key"] != key for e in body["entries"]),         body["entries"]
    assert all(s["actor_key"] != key for s in body["stats"]), body["stats"]
    assert "run 的卡" not in {e["title"] for e in body["entries"]}
    stats = {s["actor_name"]: s for s in body["stats"]}
    assert stats["諾薇亞"]["counts"] == {"task_created": 1, "task_done": 1}
    assert stats["艾斯維爾"]["total"] == 2
    assert body["total"] == 4
    assert sum(s["total"] for s in body["stats"]) == body["total"]


async def test_run_agents_are_never_contributors(tmp_path):
    """派工 agent 建的卡、做完的卡都不算誰的貢獻（艾斯維爾 2026-09-24）。"""
    app, client = await _client(tmp_path, "run")
    client.hub_app = app
    async with app.router.lifespan_context(app), client:
        rid, bid, owner, _, ids = await _setup(client)
        key, run_hdr = await _run_agent(client, rid, owner)
        await _run_agent_makes_a_card(client, ids, run_hdr)
        body = await _contrib(client, bid, owner)
        _assert_run_agent_absent(body, key)
        page = await _contrib(client, bid, owner, limit=4)
        assert page["has_more"] is False and len(page["entries"]) == 4


async def test_run_agents_are_excluded_from_derived_history_too(tmp_path):
    """稽核串補齊前的存量：只剩卡片欄位，而且 participant 列還沒有
    `run_id`（欄位是後來補的）——仍要靠「session_key 對得上本房一筆 run」
    認出來。"""
    app, client = await _client(tmp_path, "run-derived")
    client.hub_app = app
    async with app.router.lifespan_context(app), client:
        rid, bid, owner, _, ids = await _setup(client)
        key, run_hdr = await _run_agent(client, rid, owner)
        await _run_agent_makes_a_card(client, ids, run_hdr)
        db = app.state.db
        await db.execute("DELETE FROM board_event WHERE board_id=?", (bid,))
        await db.execute("UPDATE participant SET run_id='' WHERE session_key=?",
                         (key,))
        await db.commit()
        body = await _contrib(client, bid, owner)
        _assert_run_agent_absent(body, key)
        assert all(e["derived"] for e in body["entries"])


async def test_run_agents_stay_excluded_after_their_room_is_purged(tmp_path):
    """房間被清除後 participant 與 agent_run 都不在了，只剩板上的
    actor_key——`claude-run-` 前綴本身就足以排除（艾斯維爾 2026-09-24：
    派工 agent 是暫時身分，日誌類一律不追蹤）。"""
    app, client = await _client(tmp_path, "run-purged")
    client.hub_app = app
    async with app.router.lifespan_context(app), client:
        rid, bid, owner, _, ids = await _setup(client)
        key, run_hdr = await _run_agent(client, rid, owner)
        await _run_agent_makes_a_card(client, ids, run_hdr)
        db = app.state.db
        # 模擬 `_purge_room` 的結果：房內的 run 與成員列刪光，板上的列
        # 只留 actor_key（這裡只關心留下來的那一面，不走整套刪房流程）
        await db.commit()
        await db.execute("PRAGMA foreign_keys=OFF")
        for table in ("runner_event", "agent_run_event", "agent_run"):
            await db.execute(f"DELETE FROM {table}")
        await db.execute("DELETE FROM participant WHERE session_key=?",
                         (key,))
        await db.commit()
        await db.execute("PRAGMA foreign_keys=ON")
        _assert_run_agent_absent(await _contrib(client, bid, owner), key)
        # 稽核串補齊前的存量也一樣
        await db.execute("DELETE FROM board_event WHERE board_id=?", (bid,))
        await db.commit()
        _assert_run_agent_absent(await _contrib(client, bid, owner), key)
