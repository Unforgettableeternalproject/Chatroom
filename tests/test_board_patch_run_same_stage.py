"""派工 agent 可以改**同階段**他人建立的卡（艾斯維爾 2026-11-09）。

`_board_can_edit` 只認 owner／supervisor／建立者三軸，執行器派出的 run
agent 三者皆非，改別人卡的 description 會拿到 `not_board_editor`。
規則：run 的 ref 落在哪個階段（階段本身，或卡所屬的階段），那個階段裡
**仍在其中**的卡，run 進行中的 agent 改得動；其餘權限不放寬。
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
    """人類建週期、兩個階段；另一個 agent 在階段 A 建一張卡。"""
    rid = (await client.post("/api/rooms", json={
        "name": "房", "session_key": "human-a"})).json()["id"]
    owner = await _join(client, rid, "human-a", "艾斯維爾", role="human")
    maker = await _join(client, rid, "agent-b", "諾薇亞")
    oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                             json={"title": "週期"},
                             headers=owner)).json()["id"]
    stage_a = (await client.post(f"/api/board/objectives/{oid}/checklists",
                                 json={"title": "階段A"},
                                 headers=owner)).json()["id"]
    stage_b = (await client.post(f"/api/board/objectives/{oid}/checklists",
                                 json={"title": "階段B"},
                                 headers=owner)).json()["id"]
    card = (await client.post(f"/api/board/checklists/{stage_a}/tasks",
                              json={"title": "卡"},
                              headers=maker)).json()["id"]
    return rid, owner, maker, stage_a, stage_b, card


async def _run_agent(client, rid, owner, ref, kind="stage"):
    """執行器領單、run agent 以 `claude-run-<run_id>` 進房。"""
    db = client.hub_app.state.db
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
                          json={"kind": kind, "project": "ai-website",
                                "ref": ref, "brief": "做這個階段"},
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
    return run_id, {"X-Participant-Id": j.json()["participant_id"],
                    "X-Session-Key": key}


async def _desc(client, card, hdr, text="run 補的敘述"):
    return await client.patch(f"/api/board/tasks/{card}",
                              json={"description": text}, headers=hdr)


async def test_run_agent_can_edit_a_card_in_its_own_stage(tmp_path):
    """🔴 原失敗情境：run agent 改他人建在本階段的卡 ⇒ 403 not_board_editor。"""
    app, client = await _client(tmp_path, "same-stage")
    client.hub_app = app
    async with app.router.lifespan_context(app), client:
        rid, owner, _, stage_a, _, card = await _setup(client)
        _, run_hdr = await _run_agent(client, rid, owner, stage_a)
        r = await _desc(client, card, run_hdr)
        assert r.status_code == 200, r.text


async def test_run_dispatched_on_a_card_covers_that_cards_stage(tmp_path):
    """ref 是卡 id（ticket）時，範圍是那張卡所屬的階段。"""
    app, client = await _client(tmp_path, "ticket-ref")
    client.hub_app = app
    async with app.router.lifespan_context(app), client:
        rid, owner, _, stage_a, _, card = await _setup(client)
        other = (await client.post(f"/api/board/checklists/{stage_a}/tasks",
                                   json={"title": "同階段的另一張"},
                                   headers=owner)).json()["id"]
        _, run_hdr = await _run_agent(client, rid, owner, card, kind="ticket")
        r = await _desc(client, other, run_hdr)
        assert r.status_code == 200, r.text


async def test_run_agent_cannot_edit_a_card_in_another_stage(tmp_path):
    app, client = await _client(tmp_path, "other-stage")
    client.hub_app = app
    async with app.router.lifespan_context(app), client:
        rid, owner, _, stage_a, stage_b, card = await _setup(client)
        _, run_hdr = await _run_agent(client, rid, owner, stage_b)
        r = await _desc(client, card, run_hdr)
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "not_board_editor"


async def test_a_card_moved_out_of_the_stage_is_out_of_reach(tmp_path):
    """「仍在同一個階段」：卡被移走後，判斷看的是**現在**的階段。"""
    app, client = await _client(tmp_path, "moved")
    client.hub_app = app
    async with app.router.lifespan_context(app), client:
        rid, owner, _, stage_a, stage_b, card = await _setup(client)
        _, run_hdr = await _run_agent(client, rid, owner, stage_a)
        assert (await _desc(client, card, run_hdr)).status_code == 200
        db = app.state.db
        await db.execute("UPDATE board_task SET checklist_id=? WHERE id=?",
                         (stage_b, card))
        await db.commit()
        r = await _desc(client, card, run_hdr, "移走後")
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "not_board_editor"


async def test_a_finished_run_loses_the_right(tmp_path):
    app, client = await _client(tmp_path, "finished")
    client.hub_app = app
    async with app.router.lifespan_context(app), client:
        rid, owner, _, stage_a, _, card = await _setup(client)
        run_id, run_hdr = await _run_agent(client, rid, owner, stage_a)
        db = app.state.db
        await db.execute("UPDATE agent_run SET status='done' WHERE id=?",
                         (run_id,))
        await db.commit()
        r = await _desc(client, card, run_hdr)
        assert r.status_code == 403, r.text


async def test_a_plain_agent_in_the_same_stage_is_still_refused(tmp_path):
    """放寬只給 run agent；同階段的一般成員仍然是路人。"""
    app, client = await _client(tmp_path, "plain")
    client.hub_app = app
    async with app.router.lifespan_context(app), client:
        rid, owner, _, stage_a, _, card = await _setup(client)
        await _run_agent(client, rid, owner, stage_a)
        stranger = await _join(client, rid, "stranger", "路人")
        r = await _desc(client, card, stranger)
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "not_board_editor"


async def test_the_exemption_is_for_cards_not_stages(tmp_path):
    """範圍只到卡：階段本身不放寬。"""
    app, client = await _client(tmp_path, "cards-only")
    client.hub_app = app
    async with app.router.lifespan_context(app), client:
        rid, owner, _, stage_a, _, _ = await _setup(client)
        _, run_hdr = await _run_agent(client, rid, owner, stage_a)
        r = await client.patch(f"/api/board/checklists/{stage_a}",
                               json={"title": "run 改階段"}, headers=run_hdr)
        assert r.status_code == 403, r.text
