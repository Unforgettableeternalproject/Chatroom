"""排隊等 repo 鎖的派工：房裡講「排隊中」，真的開始才講「開始執行」。

單一寫入者的房間裡，後送的派工領單後會卡在執行器的 repo 鎖上，並先回報
`running`（reason=repo_lock_wait，讓它不要停在 claimed 看起來像掛了）。
那一筆**還沒開始跑**：不能講「開始執行」，`started_at` 也不能算，等拿到鎖
才用 `lock_acquired` 起算。
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


async def _setup(client):
    """建房、派一筆工並領走，停在 claimed。"""
    r = await client.post("/api/rooms", json={"name": "工作房", "kind": "ops",
                                              "session_key": "human-a"})
    rid = r.json()["id"]
    j = await client.post(f"/api/rooms/{rid}/join",
                          json={"kind": "human", "role": "human",
                                "session_key": "human-a",
                                "preferred_name": "艾斯維爾"})
    hdr = {"X-Participant-Id": j.json()["participant_id"]}
    reg = await client.post("/api/runners/register",
                            json={"host": "esvel-pc", "label": "ex1",
                                  "projects": ["ai-website"],
                                  "max_parallel": 3, "version": "0.1"})
    runner = reg.json()["runner"]["id"]
    rhdr = {"X-Runner-Token": reg.json()["runner_token"]}
    assert (await client.post(
        f"/api/rooms/{rid}/workspace",
        json={"workspace_key": "ai-website"},
        headers={"X-Session-Key": "human-a"})).status_code == 200
    run_id = (await client.post(
        f"/api/rooms/{rid}/runs",
        json={"kind": "ticket", "project": "ai-website", "ref": "JSAI-2",
              "brief": "做一下"}, headers=hdr)).json()["run"]["id"]
    await client.post(f"/api/runners/{runner}/claim", headers=rhdr)
    return rid, hdr, runner, rhdr, run_id


async def _events(client, rid, hdr):
    r = await client.get(f"/api/rooms/{rid}/messages", headers=hdr)
    assert r.status_code == 200, r.text
    return [(m["system_event"], m["content"]) for m in r.json()["messages"]
            if m["system_event"]]


async def test_waiting_for_the_lock_is_announced_as_queued(tmp_path):
    """repo_lock_wait：房裡一則排隊說明，沒有「開始執行」，started_at 留空。"""
    app, client = await _client(tmp_path, "wait")
    async with app.router.lifespan_context(app), client:
        rid, hdr, runner, rhdr, run_id = await _setup(client)
        r = await client.post(
            f"/api/runs/{run_id}/report",
            json={"status": "running", "runner_id": runner,
                  "reason": "repo_lock_wait",
                  "result": "等待同一 repo 的 run abc12345 完成。"},
            headers=rhdr)
        assert r.status_code == 200, r.text
        assert r.json()["run"]["status"] == "running"
        assert r.json()["run"]["started_at"] is None, \
            "還在排隊，不能開始算執行時間"

        events = await _events(client, rid, hdr)
        waiting = [c for e, c in events if e == "run_waiting"]
        assert waiting == ["派工 ticket／JSAI-2 排隊中，等前一個派工完成後開始。"]
        assert not [e for e, _ in events if e == "run_running"], \
            "排隊中不能講開始執行"


async def test_lock_acquired_starts_the_clock_and_announces_once(tmp_path):
    """拿到鎖：started_at 起算、一則「開始執行」，重送是 409。"""
    app, client = await _client(tmp_path, "acquired")
    async with app.router.lifespan_context(app), client:
        rid, hdr, runner, rhdr, run_id = await _setup(client)
        await client.post(f"/api/runs/{run_id}/report",
                          json={"status": "running", "runner_id": runner,
                                "reason": "repo_lock_wait"}, headers=rhdr)

        r = await client.post(f"/api/runs/{run_id}/report",
                              json={"status": "running", "runner_id": runner,
                                    "reason": "lock_acquired"}, headers=rhdr)
        assert r.status_code == 200, r.text
        assert r.json()["run"]["started_at"], "拿到鎖才開始算"
        assert r.json()["run"]["reason"] == "spawn"

        events = await _events(client, rid, hdr)
        assert [c for e, c in events if e == "run_running"] == [
            "派工 ticket／JSAI-2 開始執行。"]
        assert len([e for e, _ in events if e == "run_waiting"]) == 1

        again = await client.post(f"/api/runs/{run_id}/report",
                                  json={"status": "running",
                                        "runner_id": runner,
                                        "reason": "lock_acquired"},
                                  headers=rhdr)
        assert again.status_code == 409, "重送不能再發一次開始訊息"
        assert len([e for e, _ in await _events(client, rid, hdr)
                    if e == "run_running"]) == 1


async def test_lock_acquired_without_a_wait_is_rejected(tmp_path):
    """沒排過隊的 run 不收 lock_acquired：不讓它變成改寫 started_at 的後門。"""
    app, client = await _client(tmp_path, "nowait")
    async with app.router.lifespan_context(app), client:
        rid, hdr, runner, rhdr, run_id = await _setup(client)
        await client.post(f"/api/runs/{run_id}/report",
                          json={"status": "running", "runner_id": runner,
                                "reason": "spawn"}, headers=rhdr)
        started = (await client.get(f"/api/runs/{run_id}",
                                    headers=hdr)).json()["run"]["started_at"]
        r = await client.post(f"/api/runs/{run_id}/report",
                              json={"status": "running", "runner_id": runner,
                                    "reason": "lock_acquired"}, headers=rhdr)
        assert r.status_code == 409
        assert (await client.get(f"/api/runs/{run_id}", headers=hdr)
                ).json()["run"]["started_at"] == started
        events = await _events(client, rid, hdr)
        assert [e for e, _ in events].count("run_running") == 1
        assert not [e for e, _ in events if e == "run_waiting"]
