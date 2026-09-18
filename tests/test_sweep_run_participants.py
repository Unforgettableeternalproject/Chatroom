"""派工進行中的成員不歸閒置掃描管。

run 帶進房的身分只靠心跳撐著，而 agent 想一件事想久一點就會停止打心跳
——被掃出去的那一刻，它手上的卡變孤兒、房內身分失效，而它自己不知道。
run 中的成員有自己的離場路徑（`_depart_run_participants`），閒置掃描不該
搶在前面。收場之後才輪到掃描（而那時它本來就已經被帶走了）。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"


async def _client(tmp_path, name, **cfg_kw):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT, **cfg_kw)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


async def _ops_room(client, key="human-a"):
    r = await client.post("/api/rooms", json={"name": "工作房", "kind": "ops",
                                              "session_key": key})
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def _join_human(client, rid, key="human-a", name="艾斯維爾"):
    r = await client.post(f"/api/rooms/{rid}/join",
                          json={"kind": "human", "role": "human",
                                "session_key": key, "preferred_name": name})
    assert r.status_code == 200, r.text
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": key}


async def _join_agent(client, rid, key, name):
    r = await client.post(f"/api/rooms/{rid}/join",
                          json={"kind": "claude", "role": "agent",
                                "session_key": key, "preferred_name": name})
    assert r.status_code == 200, r.text
    return r.json()


class _Runner(str):
    token: str

    @property
    def headers(self) -> dict:
        return {"X-Runner-Token": self.token}


async def _register_runner(client, projects=("ai-website",)):
    r = await client.post("/api/runners/register",
                          json={"host": "esvel-pc", "label": "ex1",
                                "projects": list(projects),
                                "max_parallel": 3, "version": "0.1"})
    assert r.status_code == 200, r.text
    runner = _Runner(r.json()["runner"]["id"])
    runner.token = r.json()["runner_token"]
    return runner


async def _dispatch_running(client, rid, hdr, runner, ref="task-1"):
    run_id = (await client.post(
        f"/api/rooms/{rid}/runs",
        json={"kind": "investigate", "project": "ai-website", "ref": ref,
              "brief": "查一下"}, headers=hdr)).json()["run"]["id"]
    await client.post(f"/api/runners/{runner}/claim", headers=runner.headers)
    r = await client.post(f"/api/runs/{run_id}/report",
                          json={"status": "running", "runner_id": runner},
                          headers=runner.headers)
    assert r.status_code == 200, r.text
    return run_id


async def _report(client, run_id, runner, status):
    r = await client.post(f"/api/runs/{run_id}/report",
                          json={"status": status, "runner_id": runner},
                          headers=runner.headers)
    assert r.status_code == 200, r.text
    return r.json()


async def _row(app, pid):
    return await (await app.state.db.execute(
        "SELECT * FROM participant WHERE id=?", (pid,))).fetchone()


async def test_a_running_run_member_survives_the_idle_sweep(tmp_path):
    """run 還在跑，成員逾時也不掃——長時間思考不該等於離場。"""
    # idle_timeout=0：進房當下就已逾時，沒有豁免的話下一輪 sweep 必移除
    app, client = await _client(tmp_path, "sweep-running", idle_timeout=0.0)
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client)
        hdr = await _join_human(client, rid)
        runner = await _register_runner(client)
        run_id = await _dispatch_running(client, rid, hdr, runner)
        body = await _join_agent(client, rid, f"claude-run-{run_id}", "Runner")
        pid = body["participant_id"]
        assert (await _row(app, pid))["run_id"] == run_id

        await app.state.sweep_once()

        assert (await _row(app, pid))["status"] == "active", (
            "run 還在跑，成員卻被閒置掃描帶走了")
        r = await client.post(f"/api/rooms/{rid}/heartbeat",
                              headers={"X-Participant-Id": pid})
        assert r.status_code == 200, r.text


async def test_the_run_ending_is_what_takes_the_member_out(tmp_path):
    """收場之後它就不在房裡了——豁免只在 run 活著的期間成立。"""
    app, client = await _client(tmp_path, "sweep-done", idle_timeout=0.0)
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client)
        hdr = await _join_human(client, rid)
        runner = await _register_runner(client)
        run_id = await _dispatch_running(client, rid, hdr, runner)
        body = await _join_agent(client, rid, f"claude-run-{run_id}", "Runner")
        pid = body["participant_id"]

        await _report(client, run_id, runner, "done")
        await app.state.sweep_once()

        assert (await _row(app, pid))["status"] != "active"


async def test_an_ordinary_agent_is_still_swept(tmp_path):
    """豁免不能外溢：沒有 run 的 agent 逾時照樣移除。"""
    app, client = await _client(tmp_path, "sweep-plain", idle_timeout=0.0)
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client)
        await _join_human(client, rid)
        body = await _join_agent(client, rid, "worker-key", "Novia")
        pid = body["participant_id"]

        await app.state.sweep_once()

        assert (await _row(app, pid))["status"] != "active"
