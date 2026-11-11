"""階段搬到其他週期：`POST /api/board/checklists/{id}/move`。"""

import json

import pytest
from httpx import ASGITransport, AsyncClient

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
    client.hub_app = app
    return app, client


async def _join(client, rid, key, name, role="agent"):
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "human" if role == "human" else "claude", "role": role,
        "session_key": key, "preferred_name": name})
    assert r.status_code == 200, r.text
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": key}


async def _setup(client):
    """人類建兩個週期；o1 有階段 c1（兩張卡＋一份素材），o2 有 c2。"""
    rid = (await client.post("/api/rooms", json={
        "name": "房", "session_key": "human-a"})).json()["id"]
    owner = await _join(client, rid, "human-a", "艾斯維爾", role="human")
    o1 = (await client.post(f"/api/rooms/{rid}/board/objectives",
                            json={"title": "週期一"},
                            headers=owner)).json()["id"]
    o2 = (await client.post(f"/api/rooms/{rid}/board/objectives",
                            json={"title": "週期二"},
                            headers=owner)).json()["id"]
    c1 = (await client.post(f"/api/board/objectives/{o1}/checklists",
                            json={"title": "階段一"},
                            headers=owner)).json()["id"]
    c2 = (await client.post(f"/api/board/objectives/{o2}/checklists",
                            json={"title": "階段二"},
                            headers=owner)).json()["id"]
    await client.patch(f"/api/board/checklists/{c2}",
                       json={"order_index": 5}, headers=owner)
    t1 = (await client.post(f"/api/board/checklists/{c1}/tasks",
                            json={"title": "卡一"},
                            headers=owner)).json()["id"]
    t2 = (await client.post(f"/api/board/checklists/{c1}/tasks",
                            json={"title": "卡二"},
                            headers=owner)).json()["id"]
    bid = (await client.get(f"/api/rooms/{rid}/board",
                            headers=owner)).json()["board_id"]
    up = await client.post(
        f"/api/rooms/{rid}/attachments",
        files={"file": ("a.png", b"shot", "image/png")},
        headers={"X-Participant-Id": owner["X-Participant-Id"]})
    assert up.status_code == 200, up.text
    r = await client.post(f"/api/boards/{bid}/checklists/{c1}/files",
                          json={"attachment_id": up.json()["id"],
                                "note": "素材"}, headers=owner)
    assert r.status_code == 200, r.text
    return rid, bid, owner, o1, o2, c1, c2, [t1, t2]


async def _move(client, cid, oid, hdr):
    return await client.post(f"/api/board/checklists/{cid}/move",
                             json={"objective_id": oid}, headers=hdr)


async def _board(client, rid, hdr):
    return (await client.get(f"/api/rooms/{rid}/board", headers=hdr)).json()


async def test_move_carries_tasks_and_files_and_lands_last(tmp_path):
    app, client = await _client(tmp_path, "move-ok")
    async with app.router.lifespan_context(app), client:
        rid, bid, owner, o1, o2, c1, c2, tasks = await _setup(client)
        before = (await _board(client, rid, owner))["board_seq"]
        r = await _move(client, c1, o2, owner)
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["id"] == c1 and body["objective_id"] == o2
        assert body["order_index"] == 6          # 目標下最大 5 ＋ 1
        assert [f["note"] for f in body["files"]] == ["素材"]
        assert "board_id" not in body and body["deleted"] is False

        board = await _board(client, rid, owner)
        got = {c["id"]: c for c in board["checklists"]}
        assert got[c1]["objective_id"] == o2
        assert got[c1]["board_seq"] == body["board_seq"] > before
        assert board["board_seq"] == body["board_seq"]
        assert [f["note"] for f in got[c1]["files"]] == ["素材"]
        # 任務沒動，仍掛在這個階段底下
        under = {t["id"] for t in board["tasks"] if t["checklist_id"] == c1}
        assert under == set(tasks)

        events = (await client.get(f"/api/boards/{bid}/events",
                                   headers=owner)).json()["events"]
        moved = [e for e in events if e["event_type"] == "checklist_moved"]
        assert len(moved) == 1
        assert moved[0]["board_seq"] == body["board_seq"]
        assert moved[0]["item_id"] == c1
        pl = moved[0].get("payload") or moved[0].get("payload_json")
        if isinstance(pl, str):
            pl = json.loads(pl)
        assert pl == {"from_objective_id": o1, "to_objective_id": o2}

        # 不發 system 訊息
        msgs = (await client.get(f"/api/rooms/{rid}/messages",
                                 headers=owner)).json()["messages"]
        assert not [m for m in msgs
                    if m["kind"] == "system" and "階段一" in m["content"]
                    and "搬" in m["content"]]


async def test_move_into_an_empty_objective_starts_at_zero(tmp_path):
    app, client = await _client(tmp_path, "move-empty")
    async with app.router.lifespan_context(app), client:
        rid, bid, owner, o1, o2, c1, c2, _ = await _setup(client)
        o3 = (await client.post(f"/api/rooms/{rid}/board/objectives",
                                json={"title": "空的"},
                                headers=owner)).json()["id"]
        r = await _move(client, c1, o3, owner)
        assert r.status_code == 200, r.text
        assert r.json()["order_index"] == 0


async def test_same_objective_is_400(tmp_path):
    app, client = await _client(tmp_path, "move-same")
    async with app.router.lifespan_context(app), client:
        rid, bid, owner, o1, o2, c1, c2, _ = await _setup(client)
        r = await _move(client, c1, o1, owner)
        assert r.status_code == 400
        assert r.json()["detail"]["code"] == "move_same_objective"


async def test_uncategorised_stage_cannot_move(tmp_path):
    app, client = await _client(tmp_path, "move-uncat")
    async with app.router.lifespan_context(app), client:
        rid, bid, owner, o1, o2, c1, c2, _ = await _setup(client)
        await client.post(f"/api/rooms/{rid}/board/tasks",
                          json={"title": "隨手記"}, headers=owner)
        board = await _board(client, rid, owner)
        uncat = [c for c in board["checklists"] if c["title"] == "未分類"][0]
        r = await _move(client, uncat["id"], o1, owner)
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "checklist_uncategorised_immovable"


async def test_cross_board_is_409(tmp_path):
    app, client = await _client(tmp_path, "move-cross")
    async with app.router.lifespan_context(app), client:
        rid, bid, owner, o1, o2, c1, c2, _ = await _setup(client)
        key = {"X-Session-Key": "human-a"}
        other = (await client.post("/api/boards", json={"name": "別塊"},
                                   headers=key)).json()["id"]
        foreign = (await client.post(f"/api/boards/{other}/objectives",
                                     json={"title": "別板週期"},
                                     headers=key)).json()["id"]
        r = await _move(client, c1, foreign, owner)
        assert r.status_code == 409, r.text
        assert r.json()["detail"]["code"] == "move_cross_board"


async def test_non_editor_is_403(tmp_path):
    app, client = await _client(tmp_path, "move-perm")
    async with app.router.lifespan_context(app), client:
        rid, bid, owner, o1, o2, c1, c2, _ = await _setup(client)
        stranger = await _join(client, rid, "stranger", "路人")
        r = await _move(client, c1, o2, stranger)
        assert r.status_code == 403
        assert r.json()["detail"]["code"] == "not_board_editor"
        got = {c["id"]: c for c in (await _board(client, rid, owner))[
            "checklists"]}
        assert got[c1]["objective_id"] == o1


@pytest.mark.parametrize("which", ["source", "target"])
async def test_frozen_objective_is_409(tmp_path, which):
    app, client = await _client(tmp_path, f"move-frozen-{which}")
    async with app.router.lifespan_context(app), client:
        rid, bid, owner, o1, o2, c1, c2, _ = await _setup(client)
        frozen = o1 if which == "source" else o2
        db = app.state.db
        await db.execute("UPDATE board_objective SET status='review'"
                         " WHERE id=?", (frozen,))
        await db.commit()
        r = await _move(client, c1, o2, owner)
        assert r.status_code == 409, r.text
        assert r.json()["detail"]["code"] == "objective_closed"


async def _dispatch(client, rid, owner, ref, kind):
    db = client.hub_app.state.db
    await db.execute("UPDATE room SET kind='ops', workspace_key=? WHERE id=?",
                     ("ai-website", rid))
    await db.commit()
    r = await client.post("/api/runners/register",
                          json={"host": "esvel-pc", "label": "ex1",
                                "projects": ["ai-website"],
                                "max_parallel": 3, "version": "0.1"})
    assert r.status_code == 200, r.text
    r = await client.post(f"/api/rooms/{rid}/runs",
                          json={"kind": kind, "project": "ai-website",
                                "ref": ref, "brief": "做"}, headers=owner)
    assert r.status_code == 200, r.text
    return r.json()["run"]["id"]


@pytest.mark.parametrize("via", ["stage", "task"])
async def test_active_run_blocks_the_move(tmp_path, via):
    app, client = await _client(tmp_path, f"move-run-{via}")
    async with app.router.lifespan_context(app), client:
        rid, bid, owner, o1, o2, c1, c2, tasks = await _setup(client)
        if via == "stage":
            run_id = await _dispatch(client, rid, owner, c1, "stage")
        else:
            run_id = await _dispatch(client, rid, owner, tasks[0], "ticket")
        r = await _move(client, c1, o2, owner)
        assert r.status_code == 409, r.text
        assert r.json()["detail"]["code"] == "checklist_has_active_run"

        # 結束之後就能搬
        db = app.state.db
        await db.execute("UPDATE agent_run SET status='done' WHERE id=?",
                         (run_id,))
        await db.commit()
        r = await _move(client, c1, o2, owner)
        assert r.status_code == 200, r.text
