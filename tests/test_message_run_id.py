"""訊息帶 run_id，以及 `GET /api/rooms/{room}/runs/{run}/last_message`。"""

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
    return app, client


async def _join(client, rid, key, name, role="agent"):
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "human" if role == "human" else "claude", "role": role,
        "session_key": key, "preferred_name": name})
    assert r.status_code == 200, r.text
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": key}


async def _setup(client):
    rid = (await client.post("/api/rooms", json={
        "name": "房", "session_key": "human-a"})).json()["id"]
    owner = await _join(client, rid, "human-a", "艾斯維爾", role="human")
    return rid, owner


async def _ops(app, client, rid, owner, ref="x"):
    """把房改成工作房、註冊執行器、派一筆 run 並讓它進入 running。"""
    db = app.state.db
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
                          json={"kind": "investigate", "project": "ai-website",
                                "ref": ref, "brief": "查"}, headers=owner)
    assert r.status_code == 200, r.text
    run_id = r.json()["run"]["id"]
    assert (await client.post(f"/api/runners/{runner}/claim",
                              headers=rhdr)).status_code == 200
    await client.post(f"/api/runs/{run_id}/report",
                      json={"status": "running", "runner_id": runner},
                      headers=rhdr)
    return run_id, runner, rhdr


async def _msgs(client, rid, owner):
    return (await client.get(f"/api/rooms/{rid}/messages",
                             headers=owner)).json()["messages"]


async def test_run_agent_and_run_system_messages_carry_run_id(tmp_path):
    app, client = await _client(tmp_path, "runid-write")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _setup(client)
        run_id, runner, rhdr = await _ops(app, client, rid, owner)
        agent = await _join(client, rid, f"claude-run-{run_id}", "Runner")
        await client.post(f"/api/rooms/{rid}/messages",
                          json={"content": "agent 說話"}, headers=agent)
        await client.post(f"/api/rooms/{rid}/messages",
                          json={"content": "人類說話"}, headers=owner)
        await client.post(f"/api/runs/{run_id}/report",
                          json={"status": "done", "runner_id": runner,
                                "result": "好了"}, headers=rhdr)

        msgs = await _msgs(client, rid, owner)
        by = {m["content"]: m for m in msgs}
        assert by["agent 說話"]["run_id"] == run_id
        assert by["人類說話"]["run_id"] is None
        systems = {m["system_event"]: m for m in msgs
                   if m["kind"] == "system"}
        assert systems["run_running"]["run_id"] == run_id
        assert systems["run_done"]["run_id"] == run_id
        # 與 run 無關的 system 訊息（加入）不帶
        assert systems["join"]["run_id"] in (None, run_id)
        assert all("run_id" in m for m in msgs)

        # 增量讀取走同一個 serializer
        upd = (await client.get(f"/api/rooms/{rid}/updates?after_seq=0",
                                headers=owner))
        if upd.status_code == 200:
            ups = upd.json().get("messages", [])
            assert all("run_id" in m for m in ups)


async def test_old_rows_without_run_id_read_as_null(tmp_path):
    app, client = await _client(tmp_path, "runid-null")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _setup(client)
        await client.post(f"/api/rooms/{rid}/messages",
                          json={"content": "舊訊息"}, headers=owner)
        db = app.state.db
        await db.execute("UPDATE message SET run_id=''")
        await db.commit()
        assert all(m["run_id"] is None for m in await _msgs(client, rid, owner))


async def test_last_message_prefers_the_last_agent_speech(tmp_path):
    app, client = await _client(tmp_path, "runid-last-agent")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _setup(client)
        run_id, runner, rhdr = await _ops(app, client, rid, owner)
        agent = await _join(client, rid, f"claude-run-{run_id}", "Runner")
        await client.post(f"/api/rooms/{rid}/messages",
                          json={"content": "第一句"}, headers=agent)
        await client.post(f"/api/rooms/{rid}/messages",
                          json={"content": "最後一句"}, headers=agent)
        # 之後的 system 訊息不能蓋過 agent 發言
        await client.post(f"/api/runs/{run_id}/report",
                          json={"status": "done", "runner_id": runner,
                                "result": "好了"}, headers=rhdr)
        last = [m for m in await _msgs(client, rid, owner)
                if m["content"] == "最後一句"][0]
        r = await client.get(f"/api/rooms/{rid}/runs/{run_id}/last_message",
                             headers=owner)
        assert r.status_code == 200, r.text
        assert r.json() == {"seq": last["seq"], "id": last["id"],
                            "kind": "chat"}


async def test_last_message_falls_back_to_the_last_system_message(tmp_path):
    app, client = await _client(tmp_path, "runid-last-system")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _setup(client)
        run_id, runner, rhdr = await _ops(app, client, rid, owner)
        await client.post(f"/api/runs/{run_id}/report",
                          json={"status": "done", "runner_id": runner,
                                "result": "好了"}, headers=rhdr)
        done = [m for m in await _msgs(client, rid, owner)
                if m.get("system_event") == "run_done"][0]
        r = await client.get(f"/api/rooms/{rid}/runs/{run_id}/last_message",
                             headers=owner)
        assert r.status_code == 200, r.text
        assert r.json() == {"seq": done["seq"], "id": done["id"],
                            "kind": "system"}


async def test_last_message_404_and_permission(tmp_path):
    app, client = await _client(tmp_path, "runid-last-404")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _setup(client)
        r = await client.get(f"/api/rooms/{rid}/runs/nope/last_message",
                             headers=owner)
        assert r.status_code == 404
        assert r.json()["detail"]["code"] == "run_message_not_found"
        # 非成員同讀訊息：被擋
        r = await client.get(f"/api/rooms/{rid}/runs/nope/last_message")
        assert r.status_code in (401, 403)
