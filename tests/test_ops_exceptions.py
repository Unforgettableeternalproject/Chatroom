"""監控器：跨房的派工例外彙總（`GET /api/ops/exceptions`）。

這份檔案守的幾條不變式，每一條都對應一個**安靜的失敗**：

- 例外被分類錯：面板把「已經被殺掉的 run」畫成一個會自己恢復的暫時狀態
- 一般狀態回報混進來：清單被 running／done 洗掉，真正的例外沉到看不見
- 可見性漏掉：別人私人工作房的房名與派工目標從這個端點漏出去
- 游標失效：輪詢每 10 秒把同一批例外重新通知一次
"""

from datetime import datetime, timedelta, timezone

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"


async def _client(tmp_path, name, **cfg_kw):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT, **cfg_kw)
    app = create_app(cfg)
    client = AsyncClient(transport=ASGITransport(app=app),
                         base_url="http://test",
                         headers={"Authorization": f"Bearer {ROOT}"})
    # `_bind_workspace` 要拿得到 db；換成各個呼叫點多傳一個 app 的話，
    # 漏掉一處的症狀是一條跟工作區無關的測試跑出 409
    client.hub_app = app
    return app, client


async def _bind_workspace(client, rid, workspace="ai-website"):
    # 工作房要先綁工作區才派得了工（Hub 契約）。這裡直接寫欄位而不走
    # `POST /api/rooms/{id}/workspace`：那個端點要求綁定當下已經有執行器
    # 服務這個 key，而這些測試多半是先建房、後註冊執行器。綁定端點本身的
    # 契約在 tests/test_room_workspace.py
    db = client.hub_app.state.db
    await db.execute("UPDATE room SET workspace_key=? WHERE id=?",
                     (workspace, rid))
    await db.commit()


async def _ops_room(client, key="human-a", name="工作房", visibility="public",
                    workspace="ai-website"):
    r = await client.post("/api/rooms",
                          json={"name": name, "kind": "ops",
                                "session_key": key,
                                "visibility": visibility})
    assert r.status_code == 200, r.text
    rid = r.json()["id"]
    await _bind_workspace(client, rid, workspace)
    return rid


async def _join_human(client, rid, key="human-a", name="艾斯維爾"):
    r = await client.post(f"/api/rooms/{rid}/join",
                          json={"kind": "human", "role": "human",
                                "session_key": key, "preferred_name": name})
    assert r.status_code == 200, r.text
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": key}


class _Runner(str):
    token: str

    @property
    def headers(self) -> dict:
        return {"X-Runner-Token": self.token}


async def _register_runner(client, projects=("ai-website",), label="ex1"):
    r = await client.post("/api/runners/register",
                          json={"host": "esvel-pc", "label": label,
                                "projects": list(projects),
                                "max_parallel": 3, "version": "0.1"})
    assert r.status_code == 200, r.text
    runner = _Runner(r.json()["runner"]["id"])
    runner.token = r.json()["runner_token"]
    return runner


async def _running_run(client, rid, hdr, runner, ref="task-1"):
    run_id = (await client.post(
        f"/api/rooms/{rid}/runs",
        json={"kind": "investigate", "project": "ai-website", "ref": ref,
              "brief": "查一下"}, headers=hdr)).json()["run"]["id"]
    await client.post(f"/api/runners/{runner}/claim", headers=runner.headers)
    await client.post(f"/api/runs/{run_id}/report",
                      json={"status": "running", "runner_id": runner},
                      headers=runner.headers)
    return run_id


async def _exceptions(client, key="human-a", **params):
    r = await client.get("/api/ops/exceptions", params=params,
                         headers={"X-Session-Key": key})
    assert r.status_code == 200, r.text
    return r.json()


async def test_four_kinds_are_collected_and_classified(tmp_path):
    """四類已知例外各一筆，分類與嚴重度要對得上。

    `wall_clock`／`soft_stop_timeout` 被畫成 warn 的話，面板上它與「等一下
    自己會好」的額度受限長得一樣——而那筆 run 已經被殺掉了，結果不會來。
    """
    app, client = await _client(tmp_path, "kinds")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)

            stalled = await _running_run(client, rid, hdr, runner, "task-1")
            await client.post(f"/api/runs/{stalled}/report",
                              json={"status": "running", "runner_id": runner,
                                    "reason": "stalled",
                                    "stalled_seconds": 620},
                              headers=runner.headers)
            await client.post(f"/api/runs/{stalled}/report",
                              json={"status": "running", "runner_id": runner,
                                    "reason": "resumed"},
                              headers=runner.headers)
            await client.post(f"/api/runs/{stalled}/report",
                              json={"status": "failed", "runner_id": runner,
                                    "reason": "wall_clock"},
                              headers=runner.headers)

            limited = await _running_run(client, rid, hdr, runner, "task-2")
            await client.post(f"/api/runs/{limited}/report",
                              json={"status": "limited", "runner_id": runner,
                                    "reason": "rate_limit_backoff_30m"},
                              headers=runner.headers)

            body = await _exceptions(client)
            got = {(e["kind"], e["severity"]) for e in body["exceptions"]}
            assert ("stalled", "warn") in got
            assert ("resumed", "info") in got
            assert ("timeout", "error") in got
            assert ("rate_limited", "warn") in got
            # 一般狀態轉移（running／claimed）不是例外
            assert all(e["reason"] != "report" for e in body["exceptions"])

            stalled_row = next(e for e in body["exceptions"]
                               if e["kind"] == "stalled")
            assert stalled_row["room_id"] == rid
            assert stalled_row["room_name"] == "工作房"
            assert stalled_row["run_kind"] == "investigate"
            assert stalled_row["run_ref"] == "task-1"
            assert stalled_row["runner_id"] == str(runner)
            assert stalled_row["detail"]["stalled_seconds"] == 620
            # 倒序：最後發生的那筆在最前面
            times = [e["created_at"] for e in body["exceptions"]]
            assert times == sorted(times, reverse=True)


async def test_runner_offline_and_online_are_recorded(tmp_path):
    """執行器掉線要留痕，且**不看房內那句話的節流**。

    房裡的「已離線」30 分鐘只講一則、預期中的重啟整個不講——那是為了不
    洗版。照那個節流記事件的話，監控面板會說一台重啟迴圈裡的機器只掉過
    一次線。
    """
    app, client = await _client(tmp_path, "offline", runner_offline_after=60)
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)
            await _running_run(client, rid, hdr, runner, "task-1")

            old = (datetime.now(timezone.utc)
                   - timedelta(seconds=300)).isoformat()
            await app.state.db.execute(
                "UPDATE runner SET last_seen_at=? WHERE id=?", (old, runner))
            await app.state.db.commit()
            await app.state.sweep_runners()

            body = await _exceptions(client)
            off = [e for e in body["exceptions"]
                   if e["kind"] == "runner_offline"]
            assert len(off) == 1
            assert off[0]["severity"] == "error"
            assert off[0]["room_id"] == rid
            assert off[0]["runner_id"] == str(runner)
            assert off[0]["run_id"] == ""
            assert off[0]["detail"]["label"] == "ex1"

            await client.post(f"/api/runners/{runner}/heartbeat",
                              json={"runner_id": str(runner),
                                    "status": "online"},
                              headers=runner.headers)
            body = await _exceptions(client)
            back = [e for e in body["exceptions"]
                    if e["kind"] == "runner_online"]
            assert len(back) == 1, "掉線沒有配對的恢復，面板講不出那台回來了沒"


async def test_private_room_events_need_standing(tmp_path):
    """別人的私人工作房：房名與派工目標不從這個端點漏出去。"""
    app, client = await _client(tmp_path, "visibility")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client, visibility="private")
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)
            run_id = await _running_run(client, rid, hdr, runner, "secret-1")
            await client.post(f"/api/runs/{run_id}/report",
                              json={"status": "running", "runner_id": runner,
                                    "reason": "stalled",
                                    "stalled_seconds": 30},
                              headers=runner.headers)

            mine = await _exceptions(client, key="human-a")
            assert [e["run_ref"] for e in mine["exceptions"]] == ["secret-1"]

            stranger = await _exceptions(client, key="human-zzz")
            assert stranger["exceptions"] == []

            # 主持人視角：他要看的正是自己沒份的房
            r = await client.get("/api/ops/exceptions",
                                 headers={"X-Session-Key": "human-zzz",
                                          "X-Host-View": "1"})
            assert r.status_code == 200, r.text
            assert [e["run_ref"] for e in r.json()["exceptions"]] == ["secret-1"]


async def test_since_cursor_only_returns_newer(tmp_path):
    """游標吃事件 id 或時間；沒有新事件時回空，而不是把同一批再送一次。"""
    app, client = await _client(tmp_path, "cursor")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)
            run_id = await _running_run(client, rid, hdr, runner, "task-1")
            await client.post(f"/api/runs/{run_id}/report",
                              json={"status": "running", "runner_id": runner,
                                    "reason": "stalled",
                                    "stalled_seconds": 10},
                              headers=runner.headers)
            first = await _exceptions(client)
            assert len(first["exceptions"]) == 1
            cursor = first["exceptions"][0]["id"]
            assert first["next_since"] == first["exceptions"][0]["created_at"]

            again = await _exceptions(client, since=cursor)
            assert again["exceptions"] == []
            # 空的時候游標不回頭：退回空字串等於下一輪從頭全部重送
            assert again["next_since"] == cursor

            # 事件已經不在了（隨房被刪）→ 當成從頭讀，不是 404
            gone = await _exceptions(client, since="no-such-event")
            assert len(gone["exceptions"]) == 1

            await client.post(f"/api/runs/{run_id}/report",
                              json={"status": "failed", "runner_id": runner,
                                    "reason": "soft_stop_timeout"},
                              headers=runner.headers)
            after = await _exceptions(client,
                                      since=first["exceptions"][0]["created_at"])
            assert [e["kind"] for e in after["exceptions"]] == ["timeout"]


async def test_limit_is_applied_after_merging_two_tables(tmp_path):
    """兩張表各取 limit 筆，合併後要再截一次——否則回去的是兩倍長度。"""
    app, client = await _client(tmp_path, "limit", runner_offline_after=60)
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)
            run_id = await _running_run(client, rid, hdr, runner, "task-1")
            for sec in (10, 20, 30):
                await client.post(f"/api/runs/{run_id}/report",
                                  json={"status": "running",
                                        "runner_id": runner,
                                        "reason": "stalled",
                                        "stalled_seconds": sec},
                                  headers=runner.headers)
            old = (datetime.now(timezone.utc)
                   - timedelta(seconds=300)).isoformat()
            await app.state.db.execute(
                "UPDATE runner SET last_seen_at=? WHERE id=?", (old, runner))
            await app.state.db.commit()
            await app.state.sweep_runners()

            body = await _exceptions(client, limit=2)
            assert len(body["exceptions"]) == 2
