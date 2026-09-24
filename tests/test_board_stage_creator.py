"""階段創建者：記下是誰建的、是不是人類，派工的 agent 要問問題時問他。

艾斯維爾 2026-09-24：「派工 agent 要問問題時，知道該對『階段創建者』那位
人類提出」。三件事在這裡守：

- 建階段時記下創建者的**種類**（名字與 actor_key 早就有）。
- 存量階段的種類從記錄過的事實回推（板成員列、建立當下的 participant），
  兩邊都查不到的**留空**——猜成 human 會讓 agent 去問一個 agent。
- 領單時 Hub 給 stage／ticket run 一串依序的提問對象：階段創建者 → 板
  owner → 派工者，**只列人類**。創建者是 agent 就從下一位開始。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server import db as dbmod
from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"


async def _client(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT)
    app = create_app(cfg)
    client = AsyncClient(transport=ASGITransport(app=app),
                         base_url="http://test",
                         headers={"Authorization": f"Bearer {ROOT}"})
    return app, client


async def _join(client, rid, key, name, role="agent"):
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "human" if role == "human" else "claude", "role": role,
        "session_key": key, "preferred_name": name})
    assert r.status_code == 200, r.text
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": key}


async def _stage(client, rid, owner, creator, title="階段"):
    """owner 先建週期（他因此成為板 owner），creator 在底下建階段。"""
    oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                             json={"title": "週期"}, headers=owner)).json()["id"]
    r = await client.post(f"/api/board/objectives/{oid}/checklists",
                          json={"title": title}, headers=creator)
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def _checklist(client, rid, hdr, cid):
    board = (await client.get(f"/api/rooms/{rid}/board?full=1",
                              headers=hdr)).json()
    return [c for c in board["checklists"] if c["id"] == cid][0]


# ── 記錄 ─────────────────────────────────────────────────────────────

async def test_the_stage_remembers_its_creator_and_whether_they_are_human(
        tmp_path):
    app, client = await _client(tmp_path, "record")
    async with app.router.lifespan_context(app), client:
        rid = (await client.post("/api/rooms", json={
            "name": "房", "session_key": "human-a"})).json()["id"]
        human = await _join(client, rid, "human-a", "艾斯維爾", role="human")
        agent = await _join(client, rid, "agent-b", "諾薇亞")
        by_human = await _stage(client, rid, human, human, "人建的")
        oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                                 json={"title": "週期二"},
                                 headers=human)).json()["id"]
        by_agent = (await client.post(
            f"/api/board/objectives/{oid}/checklists",
            json={"title": "agent 建的"}, headers=agent)).json()["id"]

        c = await _checklist(client, rid, human, by_human)
        assert (c["created_by_name"], c["created_by_kind"]) == \
            ("艾斯維爾", "human")
        c = await _checklist(client, rid, human, by_agent)
        assert (c["created_by_name"], c["created_by_kind"]) == \
            ("諾薇亞", "claude")


async def test_existing_stages_get_their_kind_from_recorded_facts_only(
        tmp_path):
    """回推只用紀錄過的事實；查不到來源的留空，不猜。"""
    app, client = await _client(tmp_path, "backfill")
    async with app.router.lifespan_context(app), client:
        rid = (await client.post("/api/rooms", json={
            "name": "房", "session_key": "human-a"})).json()["id"]
        human = await _join(client, rid, "human-a", "艾斯維爾", role="human")
        known = await _stage(client, rid, human, human, "查得到")
        oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                                 json={"title": "週期二"},
                                 headers=human)).json()["id"]
        unknown = (await client.post(
            f"/api/board/objectives/{oid}/checklists",
            json={"title": "查不到"}, headers=human)).json()["id"]
        db = app.state.db
        # 模擬升級前的存量：種類欄位是空的；其中一筆連來源都沒有
        await db.execute("UPDATE board_checklist SET created_by_kind=''")
        await db.execute(
            "UPDATE board_checklist SET created_by=NULL,"
            " created_by_actor_key='ghost' WHERE id=?", (unknown,))
        await db.execute("PRAGMA user_version=6")
        await db.commit()

        await dbmod._migrate_data(db)
        await db.commit()

        rows = {r["id"]: r["created_by_kind"] for r in await (await db.execute(
            "SELECT id, created_by_kind FROM board_checklist"
            " WHERE id IN (?, ?)", (known, unknown))).fetchall()}
        assert rows[known] == "human"
        assert rows[unknown] == "", "查不到來源卻被填了值"


# ── 派工：問誰 ────────────────────────────────────────────────────────

async def _ops_room(client, app):
    rid = (await client.post("/api/rooms", json={
        "name": "工作房", "kind": "ops", "session_key": "human-a"})).json()["id"]
    await app.state.db.execute(
        "UPDATE room SET workspace_key='ai-website' WHERE id=?", (rid,))
    await app.state.db.commit()
    return rid


async def _runner(client):
    r = await client.post("/api/runners/register", json={
        "host": "pc", "label": "ex1", "projects": ["ai-website"],
        "max_parallel": 3, "version": "0.1"})
    assert r.status_code == 200, r.text
    return r.json()["runner"]["id"], {"X-Runner-Token":
                                      r.json()["runner_token"]}


async def _dispatch_and_claim(client, rid, hdr, kind, ref):
    # 執行器要先上線：沒有人服務這個專案的話派工是 409 `project_not_served`
    runner, rh = await _runner(client)
    r = await client.post(f"/api/rooms/{rid}/runs", json={
        "kind": kind, "project": "ai-website", "ref": ref, "brief": "做"},
        headers=hdr)
    assert r.status_code == 200, r.text
    r = await client.post(f"/api/runners/{runner}/claim", headers=rh)
    assert r.status_code == 200, r.text
    return r.json()["run"]


async def test_a_stage_run_is_told_to_ask_the_human_who_made_the_stage(
        tmp_path):
    app, client = await _client(tmp_path, "ask-creator")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client, app)
        owner = await _join(client, rid, "human-a", "艾斯維爾", role="human")
        maker = await _join(client, rid, "human-b", "戴爾", role="human")
        cid = await _stage(client, rid, owner, maker)

        run = await _dispatch_and_claim(client, rid, owner, "stage", cid)
        ask = run["ask_human"]
        assert ask["stage_creator"]["name"] == "戴爾"
        assert ask["stage_creator"]["kind"] == "human"
        assert [(t["name"], t["source"]) for t in ask["targets"]] == [
            ("戴爾", "stage_creator"), ("艾斯維爾", "board_owner")]
        assert all(t["in_room"] for t in ask["targets"])


async def test_a_ticket_run_follows_its_card_up_to_the_stage(tmp_path):
    app, client = await _client(tmp_path, "ask-ticket")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client, app)
        owner = await _join(client, rid, "human-a", "艾斯維爾", role="human")
        maker = await _join(client, rid, "human-b", "戴爾", role="human")
        cid = await _stage(client, rid, owner, maker)
        tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                                 json={"title": "卡"},
                                 headers=owner)).json()["id"]

        run = await _dispatch_and_claim(client, rid, owner, "ticket", tid)
        assert run["ask_human"]["targets"][0]["name"] == "戴爾"


async def test_an_agent_made_stage_sends_questions_to_a_human_instead(
        tmp_path):
    """創建者是 agent：它不在候選裡，第一位是板 owner。"""
    app, client = await _client(tmp_path, "ask-agent")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client, app)
        owner = await _join(client, rid, "human-a", "艾斯維爾", role="human")
        agent = await _join(client, rid, "agent-b", "諾薇亞")
        cid = await _stage(client, rid, owner, agent)

        run = await _dispatch_and_claim(client, rid, owner, "stage", cid)
        ask = run["ask_human"]
        assert ask["stage_creator"]["kind"] == "claude"
        names = [t["name"] for t in ask["targets"]]
        assert names == ["艾斯維爾"], names


async def test_an_agent_made_stage_asks_the_dispatcher_before_the_owner(
        tmp_path):
    """艾斯維爾 09-24 裁決：創建者是 agent 時先問派工者，再問板 owner。

    派工者是按下這一筆的人，對這一輪要做什麼最清楚；板 owner 管的是整塊板。
    """
    app, client = await _client(tmp_path, "ask-agent-dispatcher")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client, app)
        owner = await _join(client, rid, "human-a", "艾斯維爾", role="human")
        sender = await _join(client, rid, "human-c", "米勒", role="human")
        agent = await _join(client, rid, "agent-b", "諾薇亞")
        cid = await _stage(client, rid, owner, agent)

        run = await _dispatch_and_claim(client, rid, sender, "stage", cid)
        got = [(t["name"], t["source"]) for t in run["ask_human"]["targets"]]
        assert got == [("米勒", "requester"), ("艾斯維爾", "board_owner")], got


async def test_a_human_made_stage_keeps_creator_owner_dispatcher(tmp_path):
    app, client = await _client(tmp_path, "ask-human-order")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client, app)
        owner = await _join(client, rid, "human-a", "艾斯維爾", role="human")
        maker = await _join(client, rid, "human-b", "戴爾", role="human")
        sender = await _join(client, rid, "human-c", "米勒", role="human")
        cid = await _stage(client, rid, owner, maker)

        run = await _dispatch_and_claim(client, rid, sender, "stage", cid)
        assert [t["source"] for t in run["ask_human"]["targets"]] == [
            "stage_creator", "board_owner", "requester"]


async def test_a_stage_without_creator_record_falls_back_to_the_owner(
        tmp_path):
    """存量階段沒有創建者紀錄：不假造，從板 owner 開始。"""
    app, client = await _client(tmp_path, "ask-legacy")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client, app)
        owner = await _join(client, rid, "human-a", "艾斯維爾", role="human")
        cid = await _stage(client, rid, owner, owner)
        await app.state.db.execute(
            "UPDATE board_checklist SET created_by=NULL, created_by_name='',"
            " created_by_actor_key='', created_by_kind='' WHERE id=?", (cid,))
        await app.state.db.commit()

        run = await _dispatch_and_claim(client, rid, owner, "stage", cid)
        ask = run["ask_human"]
        assert ask["stage_creator"] == {"name": "", "kind": "",
                                        "stage_title": "階段"}
        assert [(t["name"], t["source"]) for t in ask["targets"]] == [
            ("艾斯維爾", "board_owner")]
