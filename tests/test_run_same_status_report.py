"""同狀態回報：停滯與恢復進訊息流（REMOTE-OPS-PLAN §12 待辦 4）。

`running → running` 不是狀態轉移，所以狀態機擋著它——而那條路被擋死的
後果是：一筆卡住十分鐘的 run，只有去開儀表板的人看得到。房裡的人要自己
想到去看，才看得到一件本來該來找他的事。

這裡守的是那條窄路：**帶 reason 才收**，收下也不動 run 的任何一欄。
"""

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
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


async def _setup(client):
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
    # 工作房要先綁工作區才派得了工（Hub 契約）
    assert (await client.post(
        f"/api/rooms/{rid}/workspace",
        json={"workspace_key": "ai-website"},
        headers={"X-Session-Key": "human-a"})).status_code == 200
    run_id = (await client.post(
        f"/api/rooms/{rid}/runs",
        json={"kind": "ticket", "project": "ai-website", "ref": "JSAI-1",
              "brief": "做一下"}, headers=hdr)).json()["run"]["id"]
    await client.post(f"/api/runners/{runner}/claim", headers=rhdr)
    await client.post(f"/api/runs/{run_id}/report",
                      json={"status": "running", "runner_id": runner},
                      headers=rhdr)
    return rid, hdr, runner, rhdr, run_id


async def _messages(client, rid, hdr):
    r = await client.get(f"/api/rooms/{rid}/messages", headers=hdr)
    assert r.status_code == 200, r.text
    return r.json()["messages"]


async def test_stalled_and_resumed_reach_the_room(tmp_path):
    """帶 reason 的同狀態回報：一則 system 訊息 + 一筆事件，run 不動。"""
    app, client = await _client(tmp_path, "stall")
    async with app.router.lifespan_context(app), client:
        rid, hdr, runner, rhdr, run_id = await _setup(client)
        started = (await client.get(f"/api/runs/{run_id}",
                                    headers=hdr)).json()["run"]["started_at"]
        assert started

        r = await client.post(f"/api/runs/{run_id}/report",
                              json={"status": "running", "runner_id": runner,
                                    "reason": "stalled",
                                    "stalled_seconds": 612}, headers=rhdr)
        assert r.status_code == 200, r.text
        assert r.json()["run"]["status"] == "running"
        # 不做狀態轉移就不該動 started_at——它答的是「這輪什麼時候開始」，
        # 不是「最後一次有動靜」
        assert r.json()["run"]["started_at"] == started

        msgs = await _messages(client, rid, hdr)
        stalled = [m for m in msgs if m["system_event"] == "run_stalled"]
        assert len(stalled) == 1, msgs
        assert "612 秒" in stalled[0]["content"]

        ok = await client.post(f"/api/runs/{run_id}/report",
                               json={"status": "running", "runner_id": runner,
                                     "reason": "resumed"}, headers=rhdr)
        assert ok.status_code == 200, ok.text
        resumed = [m for m in await _messages(client, rid, hdr)
                   if m["system_event"] == "run_resumed"]
        assert len(resumed) == 1

        # 稽核串：from == to，秒數留在 detail_json
        events = (await client.get(f"/api/runs/{run_id}",
                                   headers=hdr)).json()["events"]
        same = [e for e in events if e["reason"] in ("stalled", "resumed")]
        assert [e["reason"] for e in same] == ["stalled", "resumed"]
        assert all(e["from_status"] == "running" == e["to_status"]
                   for e in same)
        assert json.loads(same[0]["detail_json"])["stalled_seconds"] == 612

        # run 之後照樣走得完：同狀態回報沒有把狀態機弄壞
        done = await client.post(f"/api/runs/{run_id}/report",
                                 json={"status": "done", "runner_id": runner,
                                       "result": "好了"}, headers=rhdr)
        assert done.status_code == 200, done.text


async def test_same_status_without_reason_is_still_rejected(tmp_path):
    """沒帶 reason 的 `running → running` 維持 409。

    全收的話，一個回報遲到或重送的執行器會拿到「成功」——而 Hub 那端什麼
    都沒發生，重試邏輯就此永遠不知道自己在空轉。
    """
    app, client = await _client(tmp_path, "noreason")
    async with app.router.lifespan_context(app), client:
        _rid, _hdr, runner, rhdr, run_id = await _setup(client)
        for body in ({"status": "running", "runner_id": runner},
                     {"status": "running", "runner_id": runner,
                      "reason": "還在跑"}):
            r = await client.post(f"/api/runs/{run_id}/report", json=body,
                                  headers=rhdr)
            assert r.status_code == 409, r.text
            assert r.json()["detail"]["code"] == "run_bad_transition"
