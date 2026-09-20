"""遠端派工（Remote Ops）P1：ops 房、佇列、執行器與稽核串。

對應 `docs/REMOTE-OPS-PLAN.md` §4／§5.6／§5.7／§6.1／§6.4／§7／§8 的 P1。

這份檔案守的幾條不變式，每一條都對應一個**安靜的失敗**：

- ops 房被自動封存：下次要派工時才發現房沒了，而封存那一刻沒有人在看
- agent 憑證建得了 run：執行器 token 洩漏＝任何人能派工（§6.4 第一條）
- 兩台執行器領到同一筆：兩個 agent 動同一份工作樹，互相覆蓋
- 稽核串缺一筆：`GET /api/runs/{id}` 回一條看起來完整、實際上有洞的歷史
"""

import asyncio
from datetime import datetime, timedelta, timezone

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"
HUMAN = "human-token"


async def _client(tmp_path, name, token=ROOT, **cfg_kw):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT, **cfg_kw)
    app = create_app(cfg)
    client = AsyncClient(transport=ASGITransport(app=app),
                         base_url="http://test",
                         headers={"Authorization": f"Bearer {token}"})
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


async def _ops_room(client, key="human-a", name="工作房",
                    workspace="ai-website"):
    r = await client.post("/api/rooms",
                          json={"name": name, "kind": "ops",
                                "session_key": key})
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
    """執行器 id，外加它的 token header。

    `str` 的子類：既有的 `f"/api/runners/{runner}/..."` 照樣是 id，而每一個
    要憑證的呼叫都拿得到 `runner.headers`——測試裡把 token 另外接一個變數
    傳來傳去的話，漏掉一處的症狀是 403，而那與「這條測試本來就該 403」
    長得一樣。
    """

    token: str

    @property
    def headers(self) -> dict:
        return {"X-Runner-Token": self.token}


async def _register_runner(client, projects=("ai-website",), label="ex1",
                           max_parallel=3):
    r = await client.post("/api/runners/register",
                          json={"host": "esvel-pc", "label": label,
                                "projects": list(projects),
                                "max_parallel": max_parallel,
                                "version": "0.1"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["runner_token"], "註冊沒有發 token，下面每一個呼叫都會 403"
    runner = _Runner(body["runner"]["id"])
    runner.token = body["runner_token"]
    return runner


def _run_body(ref="task-1", kind="investigate", project="ai-website"):
    return {"kind": kind, "project": project, "ref": ref, "brief": "查一下"}


# ── ops 房：不封存、不 purge ──────────────────────────────────────────

async def test_ops_room_is_never_auto_archived(tmp_path):
    """🚨 ops 房裡沒有 agent 是**常態**，不是「該收掉了」的訊號。

    自動封存的判準是「房內曾有 agent、現在一個都不在」——對 ops 房恆真：
    它的 agent 是單次任務，做完就走。不排除的話，工作房會在第一次收工後
    開始倒數，然後在下一個人要派工時發現它已經封存了。
    """
    app, client = await _client(tmp_path, "opsarchive", idle_timeout=0.05,
                                sweep_interval=0.05, archive_grace=0.05)
    async with client:
        async with app.router.lifespan_context(app):
            ops = await _ops_room(client)
            chat = (await client.post("/api/rooms", json={
                "name": "一般房", "session_key": "human-a"})).json()["id"]
            for rid in (ops, chat):
                await client.post(f"/api/rooms/{rid}/join",
                                  json={"kind": "claude",
                                        "session_key": f"agent-{rid}"})
            # 等 agent 閒置被移出 → 一般房會走完倒數封存
            for _ in range(60):
                await asyncio.sleep(0.05)
                body = (await client.get(
                    f"/api/rooms/{chat}",
                    headers={"X-Session-Key": "human-a"})).json()
                if body["room"]["status"] == "archived":
                    break
            assert body["room"]["status"] == "archived", "對照組沒有被封存，這條測試等於沒驗"

            ops_room = (await client.get(
                f"/api/rooms/{ops}",
                headers={"X-Session-Key": "human-a"})).json()["room"]
            assert ops_room["status"] == "active"
            assert ops_room["kind"] == "ops"
            # 連倒數都不該啟動：先發一則「即將封存」再取消，在畫面上
            # 與真的要封存一模一樣
            row = await (await app.state.db.execute(
                "SELECT archive_pending_since FROM room WHERE id=?",
                (ops,))).fetchone()
            assert row["archive_pending_since"] is None


async def test_ops_room_is_never_purged(tmp_path):
    """封存夠久就永久刪除，對一間工作房是錯的——板、佇列與稽核都掛在它身上。"""
    app, client = await _client(tmp_path, "opspurge", purge_archived_days=0.0001,
                                purge_first_delay=0, sweep_interval=0.05)
    async with client:
        async with app.router.lifespan_context(app):
            ops = await _ops_room(client)
            chat = (await client.post("/api/rooms", json={
                "name": "一般房", "session_key": "human-a"})).json()["id"]
            old = "2020-01-01T00:00:00+00:00"
            await app.state.db.execute(
                "UPDATE room SET status='archived', archived_at=?"
                " WHERE id IN (?, ?)", (old, ops, chat))
            await app.state.db.commit()
            await app.state.sweep_once()
            rows = await (await app.state.db.execute(
                "SELECT id FROM room")).fetchall()
            ids = {r["id"] for r in rows}
            assert chat not in ids, "對照組沒有被清掉，這條測試等於沒驗"
            assert ops in ids


# ── 建 ops 房與派工的憑證界線 ─────────────────────────────────────────

async def test_agent_credentials_cannot_create_ops_rooms_or_runs(tmp_path):
    """§6.4 第一條：執行器的 token 只能領單、回報、heartbeat。

    在**分離期**（設了 CHATROOM_HUMAN_TOKEN）才嚴格。沒設的話一律放行，
    那正是分離期之前的行為——升級一次 Hub 就讓所有人派不了工，而錯誤訊息
    會指向一把他根本沒設過的 token。
    """
    cfg = Config(db_path=str(tmp_path / "split.db"), api_token=ROOT,
                 human_api_token=HUMAN)
    app = create_app(cfg)
    human = AsyncClient(transport=ASGITransport(app=app),
                        base_url="http://test",
                        headers={"Authorization": f"Bearer {HUMAN}"})
    agent = AsyncClient(transport=ASGITransport(app=app),
                        base_url="http://test",
                        headers={"Authorization": f"Bearer {ROOT}"})
    human.hub_app = agent.hub_app = app
    async with human, agent:
        async with app.router.lifespan_context(app):
            # agent 憑證建不了 ops 房
            r = await agent.post("/api/rooms", json={
                "name": "偷建的工作房", "kind": "ops",
                "session_key": "claude-x"})
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "human_token_required_for_ops_room"
            # 一般房照樣建得了
            assert (await agent.post("/api/rooms", json={
                "name": "一般房", "session_key": "claude-x"})).status_code == 200

            rid = await _ops_room(human)
            hdr = await _join_human(human, rid)
            # 執行器用 agent 憑證註冊（§6.4）；沒有它，下面的 run 會先撞
            # project_not_served
            await _register_runner(agent)
            # agent 拿著人類的 participant id 也建不了 run——憑證先擋
            r = await agent.post(f"/api/rooms/{rid}/runs", json=_run_body(),
                                 headers=hdr)
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "human_token_required_for_run"
            assert (await human.post(f"/api/rooms/{rid}/runs",
                                     json=_run_body(),
                                     headers=hdr)).status_code == 200


async def test_agent_member_cannot_request_a_run(tmp_path):
    """憑證之外還有一層：房內的 agent 成員也不能派工。"""
    app, client = await _client(tmp_path, "agentmember")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            j = await client.post(f"/api/rooms/{rid}/join",
                                  json={"kind": "claude",
                                        "session_key": "claude-b"})
            hdr = {"X-Participant-Id": j.json()["participant_id"],
                   "X-Session-Key": "claude-b"}
            r = await client.post(f"/api/rooms/{rid}/runs", json=_run_body(),
                                  headers=hdr)
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "human_actor_required_for_run"


async def test_runs_only_exist_in_ops_rooms(tmp_path):
    app, client = await _client(tmp_path, "notops")
    async with client:
        async with app.router.lifespan_context(app):
            rid = (await client.post("/api/rooms", json={
                "name": "一般房", "session_key": "human-a"})).json()["id"]
            hdr = await _join_human(client, rid)
            r = await client.post(f"/api/rooms/{rid}/runs", json=_run_body(),
                                  headers=hdr)
            assert r.status_code == 409
            assert r.json()["detail"]["code"] == "room_not_ops"


# ── 重複、配額 ───────────────────────────────────────────────────────

async def test_same_ref_cannot_be_dispatched_twice(tmp_path):
    """同一張卡兩筆 run＝兩個 agent 動同一份工作樹。"""
    app, client = await _client(tmp_path, "dupref")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            await _register_runner(client)
            first = await client.post(f"/api/rooms/{rid}/runs",
                                      json=_run_body(), headers=hdr)
            assert first.status_code == 200
            r = await client.post(f"/api/rooms/{rid}/runs", json=_run_body(),
                                  headers=hdr)
            assert r.status_code == 409
            detail = r.json()["detail"]
            assert detail["code"] == "run_ref_already_active"
            assert detail["run_id"] == first.json()["run"]["id"]

            # 前一筆結束之後就放得出來了
            await client.post(f"/api/runs/{first.json()['run']['id']}/cancel",
                              headers=hdr)
            assert (await client.post(f"/api/rooms/{rid}/runs",
                                      json=_run_body(),
                                      headers=hdr)).status_code == 200


async def test_queue_cap_and_daily_quota_are_429(tmp_path):
    """配額用 **429** 不是 409（create_run 的 docstring 講了為什麼）。"""
    app, client = await _client(tmp_path, "quota", run_queue_cap=2,
                                run_daily_quota=3)
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            await _register_runner(client)
            for i in range(2):
                assert (await client.post(f"/api/rooms/{rid}/runs",
                                          json=_run_body(f"task-{i}"),
                                          headers=hdr)).status_code == 200
            r = await client.post(f"/api/rooms/{rid}/runs",
                                  json=_run_body("task-9"), headers=hdr)
            assert r.status_code == 429
            assert r.json()["detail"]["code"] == "run_queue_cap_exceeded"

            # 清掉排隊之後換每日上限接手（已經用掉 2 筆，上限 3）
            for run in (await client.get(f"/api/rooms/{rid}/runs",
                                         headers=hdr)).json()["runs"]:
                await client.post(f"/api/runs/{run['id']}/cancel", headers=hdr)
            assert (await client.post(f"/api/rooms/{rid}/runs",
                                      json=_run_body("task-3"),
                                      headers=hdr)).status_code == 200
            r = await client.post(f"/api/rooms/{rid}/runs",
                                  json=_run_body("task-4"), headers=hdr)
            assert r.status_code == 429
            assert r.json()["detail"]["code"] == "run_daily_quota_exceeded"


# ── 領單：併發只有一個拿到 ────────────────────────────────────────────

async def test_eight_runners_claiming_at_once_only_one_wins(tmp_path):
    """🚨 **領號的教訓。**

    先 SELECT 再 UPDATE 的話，兩句之間的 `await` 會讓兩個執行器領到同一筆。
    這條同時發 8 個 claim 到同一個佇列（只有一筆 queued），只能有一個拿到。
    """
    app, client = await _client(tmp_path, "claimrace")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runners = [await _register_runner(client, label=f"ex{i}")
                       for i in range(8)]
            run_id = (await client.post(f"/api/rooms/{rid}/runs",
                                        json=_run_body(),
                                        headers=hdr)).json()["run"]["id"]
            results = await asyncio.gather(*[
                client.post(f"/api/runners/{r}/claim", headers=r.headers)
                for r in runners])
            winners = [r for r in results if r.status_code == 200]
            assert len(winners) == 1, (
                f"{len(winners)} 台執行器領到了同一筆單——"
                "兩個 agent 會在同一份工作樹上互相覆蓋")
            assert all(r.status_code == 204 for r in results
                       if r is not winners[0])
            assert winners[0].json()["run"]["id"] == run_id
            row = await (await app.state.db.execute(
                "SELECT status, runner_id, attempt FROM agent_run WHERE id=?",
                (run_id,))).fetchone()
            assert row["status"] == "claimed"
            assert row["runner_id"] == winners[0].json()["run"]["runner_id"]
            assert row["attempt"] == 1, "輸家不該把 attempt 一起加上去"


async def test_claim_respects_the_project_allowlist(tmp_path):
    """`project` 是**白名單**，不是提示：不在清單裡就領不到。"""
    app, client = await _client(tmp_path, "allowlist")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client, workspace="other-project")
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client, projects=("ai-website",))
            # 這筆單的 project 由**另一台**服務。少了它，create_run 會先回
            # project_not_served，而這條就再也驗不到領單的白名單
            await _register_runner(client, projects=("other-project",),
                                   label="ex2")
            assert (await client.post(
                f"/api/rooms/{rid}/runs",
                json=_run_body(project="other-project"),
                headers=hdr)).status_code == 200, "這筆單沒建起來，領單那一步等於沒驗"
            assert (await client.post(
                f"/api/runners/{runner}/claim",
                headers=runner.headers)).status_code == 204


# ── 狀態機 ──────────────────────────────────────────────────────────

async def test_illegal_transitions_are_409(tmp_path):
    """狀態機寫成「試試看能不能改」的話，一個回報遲到的執行器可以把已經
    取消的 run 推回 running。"""
    app, client = await _client(tmp_path, "statemachine")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)
            run_id = (await client.post(f"/api/rooms/{rid}/runs",
                                        json=_run_body(),
                                        headers=hdr)).json()["run"]["id"]
            # queued → done 跳過中間：擋
            r = await client.post(f"/api/runs/{run_id}/report",
                                  json={"status": "done",
                                        "runner_id": runner}, headers=runner.headers)
            assert r.status_code == 409
            assert r.json()["detail"]["code"] == "run_bad_transition"
            assert r.json()["detail"]["from_status"] == "queued"

            await client.post(f"/api/runners/{runner}/claim", headers=runner.headers)
            assert (await client.post(f"/api/runs/{run_id}/report",
                                      json={"status": "running",
                                            "runner_id": runner}, headers=runner.headers)
                    ).status_code == 200
            assert (await client.post(f"/api/runs/{run_id}/report",
                                      json={"status": "done",
                                            "runner_id": runner,
                                            "result": "查完了"}, headers=runner.headers)
                    ).status_code == 200
            # 終局之後任何回報都擋
            r = await client.post(f"/api/runs/{run_id}/report",
                                  json={"status": "running",
                                        "runner_id": runner}, headers=runner.headers)
            assert r.status_code == 409


async def test_another_runner_cannot_report_someone_elses_run(tmp_path):
    app, client = await _client(tmp_path, "notyourrun")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            mine = await _register_runner(client, label="ex1")
            other = await _register_runner(client, label="ex2")
            run_id = (await client.post(f"/api/rooms/{rid}/runs",
                                        json=_run_body(),
                                        headers=hdr)).json()["run"]["id"]
            await client.post(f"/api/runners/{mine}/claim", headers=mine.headers)
            r = await client.post(f"/api/runs/{run_id}/report",
                                  json={"status": "running",
                                        "runner_id": other}, headers=other.headers)
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "not_your_run"


async def test_report_without_a_runner_id_is_422_not_a_free_pass(tmp_path):
    """🚨 `not_your_run` 本來繞得過去：省略 `runner_id` 就整條跳過。

    舊寫法是 `if body.runner_id and row["runner_id"] and 不相等`——空字串讓
    第一個條件短路，於是**誰都可以替別台把 run 收掉**，而回應與正常收工
    一模一樣。必填之後，省略是 422（欄位不合法），帶錯是 403。
    """
    app, client = await _client(tmp_path, "reportauth")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            mine = await _register_runner(client, label="ex1")
            other = await _register_runner(client, label="ex2")
            run_id = (await client.post(f"/api/rooms/{rid}/runs",
                                        json=_run_body(),
                                        headers=hdr)).json()["run"]["id"]
            await client.post(f"/api/runners/{mine}/claim",
                              headers=mine.headers)

            # 省略 runner_id：422，不是「反正沒帶就放行」
            r = await client.post(f"/api/runs/{run_id}/report",
                                  json={"status": "running"},
                                  headers=mine.headers)
            assert r.status_code == 422, "省略 runner_id 被放行了"
            # 空字串同理（min_length=1）
            r = await client.post(f"/api/runs/{run_id}/report",
                                  json={"status": "running", "runner_id": ""},
                                  headers=mine.headers)
            assert r.status_code == 422

            # 帶別台的：403（它自己的 token 也不行）
            r = await client.post(f"/api/runs/{run_id}/report",
                                  json={"status": "running",
                                        "runner_id": str(other)},
                                  headers=other.headers)
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "not_your_run"

            # run 還在 claimed：沒有任何一次回報被放進去
            row = await (await app.state.db.execute(
                "SELECT status FROM agent_run WHERE id=?", (run_id,)
            )).fetchone()
            assert row["status"] == "claimed"


async def test_two_concurrent_handoffs_only_one_is_applied(tmp_path):
    """🚨 **狀態轉移要 CAS。**

    轉移檢查讀的是 `SELECT` 當下的狀態，而它與 `UPDATE` 之間隔著 await：
    兩個同時到的 handoff 都會看到 running、都會通過檢查，然後**各建一棵子
    run**——一張卡從此有兩條交接鏈在跑，兩個 agent 動同一份工作樹。

    `WHERE id=? AND status=?` 帶舊狀態之後，第二個什麼都改不到，回 409。
    """
    app, client = await _client(tmp_path, "handoffrace")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)
            run_id = await _drive_to_running(client, rid, hdr, runner, "task-1")
            before = len((await client.get(f"/api/runs/{run_id}",
                                           headers=hdr)).json()["events"])

            results = await asyncio.gather(*[
                client.post(f"/api/runs/{run_id}/report",
                            json={"status": "handoff",
                                  "runner_id": str(runner)},
                            headers=runner.headers)
                for _ in range(2)])
            oks = [r for r in results if r.status_code == 200]
            assert len(oks) == 1, (
                f"{len(oks)} 次 handoff 都被套用了——這張卡會有兩條交接鏈")
            losers = [r for r in results if r is not oks[0]]
            assert all(r.status_code == 409 for r in losers)
            assert all(r.json()["detail"]["code"] == "run_bad_transition"
                       for r in losers)

            children = await (await app.state.db.execute(
                "SELECT id FROM agent_run WHERE parent_run_id=?", (run_id,)
            )).fetchall()
            assert len(children) == 1, "輸家也建了子 run"
            after = (await client.get(f"/api/runs/{run_id}",
                                      headers=hdr)).json()["events"]
            assert len(after) == before + 1, "被擋下來的那次也留了稽核"
            assert after[-1]["to_status"] == "handoff"


async def test_claim_is_capped_by_the_reported_running_count(tmp_path):
    """Hub 端的併發保險：`running_count >= max_parallel` 一律 204。

    數字是最近一次 heartbeat 回報的，可能落後一個週期——這是保險，本地上限
    仍由執行器守。少了它，Hub 會把整條佇列塞給一台已經滿載的執行器，而它
    只能自己把多的丟掉（或者跑滿機器）。
    """
    app, client = await _client(tmp_path, "parallelcap")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client, max_parallel=1)
            for i in range(2):
                assert (await client.post(f"/api/rooms/{rid}/runs",
                                          json=_run_body(f"task-{i}"),
                                          headers=hdr)).status_code == 200
            # 還沒回報任何 running：領得到
            assert (await client.post(f"/api/runners/{runner}/claim",
                                      headers=runner.headers)
                    ).status_code == 200
            await client.post(f"/api/runners/{runner}/heartbeat",
                              json={"status": "online", "running_count": 1},
                              headers=runner.headers)
            assert (await client.post(f"/api/runners/{runner}/claim",
                                      headers=runner.headers)
                    ).status_code == 204, "滿載的執行器還是領到了單"
            # 回報跑完一個就又領得到——這是保險，不是關門
            await client.post(f"/api/runners/{runner}/heartbeat",
                              json={"status": "online", "running_count": 0},
                              headers=runner.headers)
            assert (await client.post(f"/api/runners/{runner}/claim",
                                      headers=runner.headers)
                    ).status_code == 200


async def test_a_project_nobody_serves_is_rejected_at_dispatch(tmp_path):
    """打錯一個字與「執行器還沒開機」在佇列上長得一模一樣：都是永遠排著。

    所以建單當下就擋（409 `project_not_served`），不要讓它安靜地排進去。
    """
    app, client = await _client(tmp_path, "projectserved")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            r = await client.post(f"/api/rooms/{rid}/runs",
                                  json=_run_body(project="ai-website"),
                                  headers=hdr)
            assert r.status_code == 409, "沒有任何執行器時照樣建得出來"
            assert r.json()["detail"]["code"] == "project_not_served"

            runner = await _register_runner(client, projects=("ai-website",))
            assert (await client.post(f"/api/rooms/{rid}/runs",
                                      json=_run_body(project="ai-website"),
                                      headers=hdr)).status_code == 200
            # 打錯字擋得住。房間綁定工作區之後，擋它的是**前一層**：
            # project 跟這間房的 workspace_key 對不上，連「有沒有人服務」
            # 都不必問。優先序是故意的：要人改的是這一筆單，不是執行器
            r = await client.post(f"/api/rooms/{rid}/runs",
                                  json=_run_body("task-2", project="ai-webiste"),
                                  headers=hdr)
            assert r.status_code == 409
            assert r.json()["detail"]["code"] == "workspace_project_mismatch"

            # 執行器離線之後也算沒人服務：它領不到，這筆單只會排著
            await app.state.db.execute(
                "UPDATE runner SET status='offline' WHERE id=?", (str(runner),))
            await app.state.db.commit()
            r = await client.post(f"/api/rooms/{rid}/runs",
                                  json=_run_body("task-3"), headers=hdr)
            assert r.status_code == 409
            assert r.json()["detail"]["code"] == "project_not_served"


# ── 取消 ────────────────────────────────────────────────────────────

async def test_cancel_queued_is_immediate_running_is_a_request(tmp_path):
    """running 的 cancel **不改狀態**：進程還在跑，這一端先把狀態改掉的話，
    畫面會說它停了而機器上那個 agent 還在寫檔。"""
    app, client = await _client(tmp_path, "cancel")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)
            queued = (await client.post(f"/api/rooms/{rid}/runs",
                                        json=_run_body("task-1"),
                                        headers=hdr)).json()["run"]["id"]
            body = (await client.post(f"/api/runs/{queued}/cancel",
                                      headers=hdr)).json()
            assert body["cancelled"] is True
            assert body["run"]["status"] == "cancelled"

            running = (await client.post(f"/api/rooms/{rid}/runs",
                                         json=_run_body("task-2"),
                                         headers=hdr)).json()["run"]["id"]
            await client.post(f"/api/runners/{runner}/claim",
                              headers=runner.headers)
            await client.post(f"/api/runs/{running}/report",
                              json={"status": "running", "runner_id": runner}, headers=runner.headers)
            body = (await client.post(f"/api/runs/{running}/cancel",
                                      headers=hdr)).json()
            assert body["cancelled"] is False
            assert body["run"]["status"] == "running"
            assert body["run"]["cancel_requested"] is True

            # 執行器在 heartbeat 拿到取消請求
            hb = (await client.post(f"/api/runners/{runner}/heartbeat", headers=runner.headers,
                                    json={"status": "online"})).json()
            assert hb["cancel_requested_run_ids"] == [running]
            assert (await client.post(f"/api/runs/{running}/report",
                                      json={"status": "cancelled",
                                            "runner_id": runner}, headers=runner.headers)
                    ).status_code == 200


# ── 交接 ────────────────────────────────────────────────────────────

async def _drive_to_running(client, rid, hdr, runner, ref):
    run_id = (await client.post(f"/api/rooms/{rid}/runs", json=_run_body(ref),
                                headers=hdr)).json()["run"]["id"]
    await client.post(f"/api/runners/{runner}/claim", headers=runner.headers)
    await client.post(f"/api/runs/{run_id}/report",
                      json={"status": "running", "runner_id": runner}, headers=runner.headers)
    return run_id


async def test_handoff_creates_a_child_run(tmp_path):
    app, client = await _client(tmp_path, "handoff")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)
            run_id = await _drive_to_running(client, rid, hdr, runner, "task-1")
            body = (await client.post(f"/api/runs/{run_id}/report",
                                      json={"status": "handoff",
                                            "runner_id": runner,
                                            "reason": "context"}, headers=runner.headers)).json()
            child = body["child_run"]
            assert body["run"]["status"] == "handoff"
            assert child is not None
            assert child["parent_run_id"] == run_id
            assert child["handoff_depth"] == 1
            assert child["status"] == "queued"
            assert f"前一輪 run {run_id} 已交接，先讀卡 task-1" in child["brief"]
            # 派工者跟著傳下去：子 run 做完要 mention 的是同一個人
            assert child["requested_by_actor_key"] == "human-a"


async def test_a_finished_handoff_chain_does_not_block_redispatch(tmp_path):
    """交接過的卡要能再派工。

    父 run 永遠停在 handoff（它同時在 _RUN_ACTIVE 與 _RUN_TERMINAL 裡）；
    重複檢查若把它算成「還沒結束」，子 run 收場後這張卡就再也派不了工。
    2026-09-18 實測：佇列空、人已離房，建單仍回 run_ref_already_active。
    """
    app, client = await _client(tmp_path, "handoff-redispatch")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)
            run_id = await _drive_to_running(client, rid, hdr, runner, "task-1")
            body = (await client.post(f"/api/runs/{run_id}/report",
                                      json={"status": "handoff",
                                            "runner_id": runner,
                                            "reason": "context"},
                                      headers=runner.headers)).json()
            child_id = body["child_run"]["id"]
            # 子 run 還在排隊：同一張卡仍要被擋，而且指向子 run
            r = await client.post(f"/api/rooms/{rid}/runs", json=_run_body(),
                                  headers=hdr)
            assert r.status_code == 409
            assert r.json()["detail"]["run_id"] == child_id
            # 子 run 收場後就放得出來
            await client.post(f"/api/runs/{child_id}/cancel", headers=hdr)
            r = await client.post(f"/api/rooms/{rid}/runs", json=_run_body(),
                                  headers=hdr)
            assert r.status_code == 200, r.json()


async def test_handoff_brief_carries_the_parent_summary(tmp_path):
    """交接摘要要接進子 run 的 brief。

    只給「先讀卡」的話，下一棒得自己把上一輪的結論從卡與房裡拼回來，
    而那份摘要本來就隨著回報一起送到了。
    """
    app, client = await _client(tmp_path, "handoffbrief")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)
            run_id = await _drive_to_running(client, rid, hdr, runner,
                                             "task-1")
            summary = "已做：改了 config。未做：測試。下一步：跑 pytest。"
            child = (await client.post(
                f"/api/runs/{run_id}/report",
                json={"status": "handoff", "runner_id": runner,
                      "reason": "context", "result": summary},
                headers=runner.headers)).json()["child_run"]
            assert "## 前一輪交接摘要" in child["brief"]
            assert summary in child["brief"]
            assert child["brief"].index("先讀卡") \
                < child["brief"].index("前一輪交接摘要"), "摘要接在指引後面"


async def test_handoff_brief_takes_a_summary_at_the_size_limit(tmp_path):
    """上限（8000）長度的摘要要整份帶進去，不能在邊界上被切掉。

    ⚠️ `RunReport.result` 本身就是 `max_length=8000`，所以 brief 這一端的截尾
    是第二道防線（上限放寬時才會走到），從 API 打不進去。
    """
    app, client = await _client(tmp_path, "handofflong")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)
            run_id = await _drive_to_running(client, rid, hdr, runner,
                                             "task-1")
            child = (await client.post(
                f"/api/runs/{run_id}/report",
                json={"status": "handoff", "runner_id": runner,
                      "reason": "context", "result": "長" * 8000},
                headers=runner.headers)).json()["child_run"]
            assert child["brief"].count("長") == 8000
            assert "摘要過長" not in child["brief"]
            # 再長一點是 422，不是靜默截尾
            too_long = await client.post(
                f"/api/runs/{run_id}/report",
                json={"status": "handoff", "runner_id": runner,
                      "result": "長" * 8001}, headers=runner.headers)
            assert too_long.status_code == 422


async def test_handoff_depth_is_capped(tmp_path):
    """無上限的交接鏈會自己續命，而遠端沒有人看著它續到第幾輪。"""
    app, client = await _client(tmp_path, "handoffmax", run_handoff_max=2)
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)
            run_id = await _drive_to_running(client, rid, hdr, runner, "task-1")
            depths = []
            for _ in range(3):
                body = (await client.post(f"/api/runs/{run_id}/report",
                                          json={"status": "handoff",
                                                "runner_id": runner}, headers=runner.headers)).json()
                child = body["child_run"]
                if child is None:
                    assert body["run"]["status"] == "failed"
                    assert body["run"]["reason"] == "handoff_depth_exceeded"
                    break
                depths.append(child["handoff_depth"])
                run_id = child["id"]
                await client.post(f"/api/runners/{runner}/claim", headers=runner.headers)
                await client.post(f"/api/runs/{run_id}/report",
                                  json={"status": "running",
                                        "runner_id": runner}, headers=runner.headers)
            else:
                pytest.fail("交接鏈沒有被上限擋下來")
            assert depths == [1, 2]


# ── 稽核串完整性 ─────────────────────────────────────────────────────

async def test_every_status_change_leaves_exactly_one_event(tmp_path):
    """比照 `test_board_event_completeness`：**列舉**所有狀態變化，不挑樣本。

    只有部分路徑記 event 的話，`GET /api/runs/{id}` 會回一條看起來完整、
    實際上有洞的稽核串——而那比沒有稽核串更糟。
    """
    app, client = await _client(tmp_path, "trail", run_handoff_max=1)
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)

            # ① queued → claimed → running → limited → running → done
            a = await _drive_to_running(client, rid, hdr, runner, "task-a")
            await client.post(f"/api/runs/{a}/report",
                              json={"status": "limited", "runner_id": runner,
                                    "reason": "rate_limit"}, headers=runner.headers)
            await client.post(f"/api/runs/{a}/report",
                              json={"status": "running", "runner_id": runner}, headers=runner.headers)
            await client.post(f"/api/runs/{a}/report",
                              json={"status": "done", "runner_id": runner,
                                    "result": "好了"}, headers=runner.headers)
            trail = (await client.get(f"/api/runs/{a}",
                                      headers=hdr)).json()["events"]
            assert [e["to_status"] for e in trail] == [
                "queued", "claimed", "running", "limited", "running", "done"]
            assert [e["from_status"] for e in trail] == [
                "", "queued", "claimed", "running", "limited", "running"]

            # ② 取消請求也留痕：送出去、執行器還沒收到的那段時間，
            #    沒有別的地方講得出「有人按過取消」
            b = await _drive_to_running(client, rid, hdr, runner, "task-b")
            await client.post(f"/api/runs/{b}/cancel", headers=hdr)
            await client.post(f"/api/runs/{b}/report",
                              json={"status": "cancelled",
                                    "runner_id": runner}, headers=runner.headers)
            trail = (await client.get(f"/api/runs/{b}",
                                      headers=hdr)).json()["events"]
            assert [(e["from_status"], e["to_status"]) for e in trail] == [
                ("", "queued"), ("queued", "claimed"), ("claimed", "running"),
                ("running", "running"), ("running", "cancelled")]
            assert trail[3]["reason"] == "cancel_requested"

            # ③ 被擋下來的轉移不留 event（沒領號就沒有洞）
            before = len((await client.get(f"/api/runs/{b}",
                                           headers=hdr)).json()["events"])
            await client.post(f"/api/runs/{b}/report",
                              json={"status": "running", "runner_id": runner}, headers=runner.headers)
            after = (await client.get(f"/api/runs/{b}",
                                      headers=hdr)).json()["events"]
            assert len(after) == before

            # ④ 交接：這一輪一筆、子 run 的誕生一筆、上限那次的 failed 一筆
            c = await _drive_to_running(client, rid, hdr, runner, "task-c")
            child = (await client.post(f"/api/runs/{c}/report",
                                       json={"status": "handoff",
                                             "runner_id": runner}, headers=runner.headers)
                     ).json()["child_run"]["id"]
            assert [e["to_status"] for e in (
                await client.get(f"/api/runs/{c}", headers=hdr)
            ).json()["events"]] == ["queued", "claimed", "running", "handoff"]
            await client.post(f"/api/runners/{runner}/claim", headers=runner.headers)
            await client.post(f"/api/runs/{child}/report",
                              json={"status": "running", "runner_id": runner}, headers=runner.headers)
            await client.post(f"/api/runs/{child}/report",
                              json={"status": "handoff", "runner_id": runner}, headers=runner.headers)
            assert [e["to_status"] for e in (
                await client.get(f"/api/runs/{child}", headers=hdr)
            ).json()["events"]] == [
                "queued", "claimed", "running", "handoff", "failed"]

            # 每一筆 event 都指得回它的 run 與房
            rows = await (await app.state.db.execute(
                "SELECT run_id, room_id FROM agent_run_event")).fetchall()
            assert rows and all(r["run_id"] and r["room_id"] == rid
                                for r in rows)


# ── 房內 system 訊息（§7）────────────────────────────────────────────

async def test_only_the_five_moments_get_a_system_message(tmp_path):
    """§7：只發開始、結束、limited、交接、執行器離線。

    排隊不發——位置變化發成訊息會把整個房洗掉，而那正是「下次真的要緊時
    沒有人在看」的來源。
    """
    app, client = await _client(tmp_path, "notify")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)

            async def events_in_room():
                msgs = (await client.get(f"/api/rooms/{rid}/messages",
                                         headers=hdr)).json()["messages"]
                return [(m["system_event"], m["mentions"]) for m in msgs
                        if (m["system_event"] or "").startswith("run")]

            run_id = (await client.post(f"/api/rooms/{rid}/runs",
                                        json=_run_body(),
                                        headers=hdr)).json()["run"]["id"]
            assert await events_in_room() == [], "排隊不該發 system 訊息"

            await client.post(f"/api/runners/{runner}/claim", headers=runner.headers)
            assert await events_in_room() == [], "領走也不發——那不是 §7 的五件事"

            await client.post(f"/api/runs/{run_id}/report",
                              json={"status": "running", "runner_id": runner}, headers=runner.headers)
            await client.post(f"/api/runs/{run_id}/report",
                              json={"status": "limited", "runner_id": runner,
                                    "reason": "rate_limit"}, headers=runner.headers)
            await client.post(f"/api/runs/{run_id}/report",
                              json={"status": "running", "runner_id": runner}, headers=runner.headers)
            await client.post(f"/api/runs/{run_id}/report",
                              json={"status": "done", "runner_id": runner,
                                    "result": "查完了"}, headers=runner.headers)
            got = await events_in_room()
            assert [e for e, _ in got] == [
                "run_running", "run_limited", "run_running", "run_done"]
            # limited mention 房內所有人類；完成 mention 派工者
            assert got[1][1] == ["艾斯維爾"]
            assert got[3][1] == ["艾斯維爾"]


async def test_runner_going_offline_is_announced_then_stays_quiet(tmp_path):
    """**只標一次**：每輪都發的話，一台關掉的執行器會每 30 秒在房裡喊一次。"""
    app, client = await _client(tmp_path, "offline", runner_offline_after=0.05,
                                sweep_interval=999)
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)
            await client.post(f"/api/rooms/{rid}/runs", json=_run_body(),
                              headers=hdr)
            await client.post(f"/api/runners/{runner}/claim", headers=runner.headers)

            async def presence_msgs():
                msgs = (await client.get(f"/api/rooms/{rid}/messages",
                                         headers=hdr)).json()["messages"]
                return [(m["system_event"], m["mentions"]) for m in msgs
                        if (m["system_event"] or "").startswith("runner_")]

            await asyncio.sleep(0.1)
            await app.state.sweep_runners()
            assert await presence_msgs() == [("runner_offline", ["艾斯維爾"])]
            await app.state.sweep_runners()
            assert len(await presence_msgs()) == 1, "第二輪不該再喊一次"

            # 回來也講一句
            await client.post(f"/api/runners/{runner}/heartbeat", headers=runner.headers,
                              json={"status": "online"})
            assert [e for e, _ in await presence_msgs()] == [
                "runner_offline", "runner_online"]


async def test_an_expected_restart_does_not_announce_losing_connection(tmp_path):
    """執行器自己說「我要重啟了」之後的離線是**預期中的**（實機 2026-09-18）。

    照樣喊「失去連線，排隊中的派工暫時沒有人領」的話，一個每小時一次的
    維護窗重啟會在房裡留下一則看起來很嚴重、實際上 1～2 分鐘就結束的警報；
    回來時的「已恢復連線」也不發——只有後半句的話，房裡看到的是一台從來
    沒掉線過卻一直在恢復連線的執行器。
    """
    app, client = await _client(tmp_path, "restartquiet",
                                runner_offline_after=0.05, sweep_interval=999)
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)
            await _drive_to_running(client, rid, hdr, runner, "task-1")

            async def presence():
                msgs = (await client.get(f"/api/rooms/{rid}/messages",
                                         headers=hdr)).json()["messages"]
                return [m["system_event"] for m in msgs
                        if (m["system_event"] or "").startswith("runner_")]

            # 退出前的最後一次心跳：restarting
            await client.post(f"/api/runners/{runner}/heartbeat",
                              headers=runner.headers,
                              json={"status": "restarting"})
            await asyncio.sleep(0.1)
            await app.state.sweep_runners()
            row = await (await app.state.db.execute(
                "SELECT status FROM runner WHERE id=?", (str(runner),)
            )).fetchone()
            assert row["status"] == "offline", "沒被掃成 offline，這條等於沒驗"
            assert await presence() == [], "預期中的重啟也喊了失去連線"

            await client.post(f"/api/runners/{runner}/heartbeat",
                              headers=runner.headers,
                              json={"status": "online"})
            assert await presence() == [], "掉線沒講，回來卻講了"


async def test_repeated_offline_is_announced_at_most_once_per_30_minutes(
        tmp_path):
    """同一台執行器一直掉線，房裡只留第一則（實機 2026-09-18）。

    重啟迴圈裡的執行器每 5 分鐘掉一次線，而那一小時房裡是 12 則一模一樣的
    話——要人來看的那一則就埋在裡面。
    """
    app, client = await _client(tmp_path, "offlinethrottle",
                                runner_offline_after=0.05, sweep_interval=999)
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)
            await _drive_to_running(client, rid, hdr, runner, "task-1")

            async def presence():
                msgs = (await client.get(f"/api/rooms/{rid}/messages",
                                         headers=hdr)).json()["messages"]
                return [m["system_event"] for m in msgs
                        if (m["system_event"] or "").startswith("runner_")]

            async def drop_and_return(status="online"):
                await asyncio.sleep(0.1)
                await app.state.sweep_runners()
                await client.post(f"/api/runners/{runner}/heartbeat",
                                  headers=runner.headers,
                                  json={"status": status})

            await drop_and_return()
            assert await presence() == ["runner_offline", "runner_online"]

            await drop_and_return()
            assert await presence() == ["runner_offline", "runner_online"], (
                "30 分鐘內的第二次掉線又喊了一次")

            # 上一則是 31 分鐘前：這一次要講
            notice = app.state.runner_offline_notice_at
            notice[str(runner)] = notice[str(runner)] - timedelta(minutes=31)
            await drop_and_return()
            assert await presence() == [
                "runner_offline", "runner_online",
                "runner_offline", "runner_online"], (
                "過了節流窗還是不講，那就不是節流而是靜音")


async def test_offline_notice_skips_rooms_whose_runs_are_finished(tmp_path):
    """執行器離線，對一間「派過工、但早就做完了」的房沒有意義。

    條件是**現在還佔著它的 run**，不是歷史上曾經有過——發到不相干的房裡，
    下一次真的要緊時就沒有人在看了。
    """
    app, client = await _client(tmp_path, "offlinescope",
                                runner_offline_after=0.05, sweep_interval=999)
    async with client:
        async with app.router.lifespan_context(app):
            runner = await _register_runner(client)
            done_room = await _ops_room(client, name="做完的房")
            live_room = await _ops_room(client, name="還在跑的房")
            done_hdr = await _join_human(client, done_room)
            live_hdr = await _join_human(client, live_room)

            finished = await _drive_to_running(client, done_room, done_hdr,
                                               runner, "task-done")
            await client.post(f"/api/runs/{finished}/report",
                              json={"status": "done", "runner_id": str(runner),
                                    "result": "好了"},
                              headers=runner.headers)
            await _drive_to_running(client, live_room, live_hdr, runner,
                                    "task-live")

            async def presence(rid, hdr):
                msgs = (await client.get(f"/api/rooms/{rid}/messages",
                                         headers=hdr)).json()["messages"]
                return [m["system_event"] for m in msgs
                        if (m["system_event"] or "").startswith("runner_")]

            await asyncio.sleep(0.1)
            await app.state.sweep_runners()
            assert await presence(live_room, live_hdr) == ["runner_offline"], (
                "還有 run 在跑的房沒收到通知，這條測試等於沒驗")
            assert await presence(done_room, done_hdr) == [], (
                "run 已經做完的房也收到了執行器離線的通知")


# ── 執行器註冊、命令、儀表板 ──────────────────────────────────────────

async def test_register_is_idempotent_per_host_and_label(tmp_path):
    """重啟一次就多一列的話，離線的通知會對每一個殘影各發一次。

    冪等的入場券是 `X-Runner-Token`：同一台帶著它回來才算重註冊。
    """
    app, client = await _client(tmp_path, "register")
    async with client:
        async with app.router.lifespan_context(app):
            a = await client.post("/api/runners/register",
                                  json={"host": "esvel-pc", "label": "main",
                                        "projects": ["ai-website"]})
            token = a.json()["runner_token"]
            b = await client.post("/api/runners/register",
                                  json={"host": "esvel-pc", "label": "main",
                                        "projects": ["ai-website", "x"],
                                        "version": "0.2"},
                                  headers={"X-Runner-Token": token})
            assert a.json()["created"] is True
            assert b.json()["created"] is False
            assert a.json()["runner"]["id"] == b.json()["runner"]["id"]
            assert b.json()["runner"]["projects"] == ["ai-website", "x"]
            assert b.json()["runner"]["version"] == "0.2"
            # token 不換：換掉的話，執行器手上那把在下一次 heartbeat 就死了
            assert b.json()["runner_token"] is None
            assert (await client.post(
                f"/api/runners/{a.json()['runner']['id']}/heartbeat",
                json={"status": "online"},
                headers={"X-Runner-Token": token})).status_code == 200


async def test_register_does_not_hand_a_runner_over_to_whoever_asks(tmp_path):
    """🚨 **冪等不等於任何人都能接管。**

    `created: False` 這條路本來只看 host+label——拿 agent token 的人對同一組
    重註冊一次就拿到它的 id，接著替它 heartbeat（把人類下的命令吃掉）、
    領單、把它領的 run 收掉。名錄上看起來完全正常，因為那**就是**同一列。

    這條驗的是：沒帶 token（或帶錯）一律 403，而且拿不到憑證就做不了
    heartbeat / claim / report 任何一件事。
    """
    app, client = await _client(tmp_path, "takeover")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            victim = await _register_runner(client, label="main")
            run_id = (await client.post(f"/api/rooms/{rid}/runs",
                                        json=_run_body(),
                                        headers=hdr)).json()["run"]["id"]
            await client.post(f"/api/runners/{victim}/claim",
                              headers=victim.headers)

            # ① 不帶 token 的重註冊：403
            r = await client.post("/api/runners/register",
                                  json={"host": "esvel-pc", "label": "main",
                                        "projects": ["ai-website"]})
            assert r.status_code == 403, "任何人都能對同一組 host+label 重註冊"
            assert r.json()["detail"]["code"] == "runner_token_required"

            # ② 帶錯的 token 一樣擋
            r = await client.post("/api/runners/register",
                                  json={"host": "esvel-pc", "label": "main",
                                        "projects": ["ai-website"]},
                                  headers={"X-Runner-Token": "not-the-token"})
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "runner_token_required"

            # ③ 就算已經知道 id（儀表板讀得到），三個執行器端點都過不去
            for r in (
                await client.post(f"/api/runners/{victim}/heartbeat",
                                  json={"status": "paused"}),
                await client.post(f"/api/runners/{victim}/claim"),
                await client.post(f"/api/runs/{run_id}/report",
                                  json={"status": "running",
                                        "runner_id": str(victim)}),
            ):
                assert r.status_code == 403, "沒帶憑證就做得到"
                assert r.json()["detail"]["code"] == "runner_token_required"
            bad = {"X-Runner-Token": "not-the-token"}
            for r in (
                await client.post(f"/api/runners/{victim}/heartbeat",
                                  json={"status": "paused"}, headers=bad),
                await client.post(f"/api/runners/{victim}/claim", headers=bad),
                await client.post(f"/api/runs/{run_id}/report",
                                  json={"status": "running",
                                        "runner_id": str(victim)},
                                  headers=bad),
            ):
                assert r.status_code == 403
                assert r.json()["detail"]["code"] == "runner_token_invalid"

            # ④ 正主拿著 token 照樣做得到——不然這條只是把功能關掉
            assert (await client.post(
                f"/api/runs/{run_id}/report",
                json={"status": "running", "runner_id": str(victim)},
                headers=victim.headers)).status_code == 200
            # 執行器還是 online（別人的假 heartbeat 沒有把它改成 paused）
            row = await (await app.state.db.execute(
                "SELECT status FROM runner WHERE id=?", (str(victim),)
            )).fetchone()
            assert row["status"] == "online"


async def test_runners_registered_before_tokens_existed_still_work(tmp_path):
    """升級一次 Hub 就讓所有在跑的執行器 403 的話，遠端沒有人會去重跑註冊。

    `token_sha256` 空字串＝那一欄存在之前註冊的，驗證放行；下一次 register
    補發一把，從此照規則走。
    """
    app, client = await _client(tmp_path, "legacyrunner")
    async with client:
        async with app.router.lifespan_context(app):
            runner = await _register_runner(client, label="old")
            await app.state.db.execute(
                "UPDATE runner SET token_sha256='' WHERE id=?", (str(runner),))
            await app.state.db.commit()
            assert (await client.post(
                f"/api/runners/{runner}/heartbeat",
                json={"status": "online"})).status_code == 200
            # 重註冊補發一把新的
            r = await client.post("/api/runners/register",
                                  json={"host": "esvel-pc", "label": "old",
                                        "projects": ["ai-website"]})
            assert r.status_code == 200
            assert r.json()["created"] is False
            fresh = r.json()["runner_token"]
            assert fresh
            assert (await client.post(
                f"/api/runners/{runner}/heartbeat",
                json={"status": "online"},
                headers={"X-Runner-Token": "x"})).status_code == 403
            assert (await client.post(
                f"/api/runners/{runner}/heartbeat",
                json={"status": "online"},
                headers={"X-Runner-Token": fresh})).status_code == 200


async def test_commands_are_taken_once(tmp_path):
    """命令是**一次性**的：重送一次 restart 等於重啟兩次。"""
    app, client = await _client(tmp_path, "commands")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)
            for cmd in ("pause", "resume"):
                r = await client.post(f"/api/runners/{runner}/commands",
                                      json={"command": cmd, "room_id": rid},
                                      headers=hdr)
                assert r.status_code == 200, r.text
            hb = (await client.post(f"/api/runners/{runner}/heartbeat", headers=runner.headers,
                                    json={"status": "paused"})).json()
            assert [c["command"] for c in hb["commands"]] == ["pause", "resume"]
            hb = (await client.post(f"/api/runners/{runner}/heartbeat", headers=runner.headers,
                                    json={"status": "online"})).json()
            assert hb["commands"] == []


async def test_the_command_feedback_chain_reaches_the_dashboard(tmp_path):
    """§5.7：命令從「按下」到「生效」每一段都要在面板上看得到。

    這條守的是那個**安靜的失敗**：Hub 只記得「已送達」的話，人按完鈕看到
    的是一個 30 秒不動的面板，而唯一合理的推論是它壞了。
    """
    app, client = await _client(tmp_path, "cmdfeedback")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)
            cmd = (await client.post(f"/api/runners/{runner}/commands",
                                     json={"command": "pause",
                                           "room_id": rid},
                                     headers=hdr)).json()["command"]
            hb = (await client.post(f"/api/runners/{runner}/heartbeat",
                                    headers=runner.headers,
                                    json={"status": "online"})).json()
            assert [c["id"] for c in hb["commands"]] == [cmd["id"]]

            # 生效：執行器在下一次心跳寫回來
            r = await client.post(
                f"/api/runners/{runner}/heartbeat", headers=runner.headers,
                json={"status": "paused",
                      "command_acks": [{"id": cmd["id"],
                                        "applied_at": "2026-09-17T10:00:00Z",
                                        "note": "已暫停"}]})
            assert r.status_code == 200, r.text
            one = (await client.get(f"/api/rooms/{rid}/runner",
                                    headers=hdr)).json()["runners"][0]
            got = one["commands"][0]
            assert set(got) == {"id", "command", "issued_by_name",
                                "created_at", "acked_at", "applied_at", "note"}
            assert got["command"] == "pause" and got["note"] == "已暫停"
            # `applied_at` **原樣存執行器送來的值**：它要跟
            # `dashboard.runner.started_at` 同一支時鐘，App 靠
            # `started_at > applied_at` 判定「已經重啟完回來了」
            assert got["applied_at"] == "2026-09-17T10:00:00Z"
            assert got["acked_at"]
            assert got["issued_by_name"] == "艾斯維爾"


async def test_an_unapplied_command_keeps_its_note_and_no_applied_at(tmp_path):
    """還沒生效的 restart：note 要寫、`applied_at` 要留空。

    兩個都漏掉的話，面板只能在「已送達」與「已生效」之間二選一，而「等 2
    筆 run 結束後重啟」正是人這時候唯一想知道的事。生效之後**不能被後來
    的空 ack 洗回去**：那會讓一台已經重啟完的執行器看起來還在等。
    """
    app, client = await _client(tmp_path, "unapplied")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)
            cmd = (await client.post(f"/api/runners/{runner}/commands",
                                     json={"command": "restart"},
                                     headers=hdr)).json()["command"]
            await client.post(f"/api/runners/{runner}/heartbeat",
                              headers=runner.headers,
                              json={"status": "online"})
            await client.post(
                f"/api/runners/{runner}/heartbeat", headers=runner.headers,
                json={"status": "online",
                      "command_acks": [{"id": cmd["id"], "applied_at": None,
                                        "note": "等 2 筆 run 結束後重啟"}]})
            got = (await client.get(f"/api/rooms/{rid}/runner", headers=hdr)
                   ).json()["runners"][0]["commands"][0]
            assert got["applied_at"] is None
            assert got["note"] == "等 2 筆 run 結束後重啟"

            # 退出前那一次：狀態 restarting，命令標生效
            r = await client.post(
                f"/api/runners/{runner}/heartbeat", headers=runner.headers,
                json={"status": "restarting",
                      "command_acks": [{"id": cmd["id"],
                                        "applied_at": "2026-09-17T10:00:00Z",
                                        "note": "正在重啟，預計 1～2 分鐘完成"}]})
            assert r.status_code == 200, r.text
            body = (await client.get(f"/api/rooms/{rid}/runner",
                                     headers=hdr)).json()
            # restarting 的執行器**要留在列表上**：從列表消失與「它掛了」
            # 在面板上長得一樣
            assert body["runners"][0]["status"] == "restarting"
            applied = body["runners"][0]["commands"][0]["applied_at"]
            assert applied

            # 再來一次沒帶 applied_at 的 ack，不能把它洗回 None
            await client.post(
                f"/api/runners/{runner}/heartbeat", headers=runner.headers,
                json={"status": "restarting",
                      "command_acks": [{"id": cmd["id"], "applied_at": None,
                                        "note": "正在重啟，預計 1～2 分鐘完成"}]})
            again = (await client.get(f"/api/rooms/{rid}/runner", headers=hdr)
                     ).json()["runners"][0]["commands"][0]
            assert again["applied_at"] == applied


async def test_reregistering_settles_commands_that_never_reported_back(
        tmp_path):
    """重註冊＝上一個進程已經不在，它領走的命令不會再有回音（實機 2026-09-18）。

    App 把 `applied_at IS NULL` 當成「進行中」→ 重啟鈕停用。正式 Hub 上有
    一筆 restart 被舊版執行器領走後直接退出，於是那顆鈕從 09-18 起一直按
    不動，而房裡沒有任何地方說得出原因。
    """
    app, client = await _client(tmp_path, "reregsettle")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)
            await client.post(f"/api/runners/{runner}/commands",
                              json={"command": "restart"}, headers=hdr)
            hb = (await client.post(f"/api/runners/{runner}/heartbeat",
                                    headers=runner.headers,
                                    json={"status": "online"})).json()
            assert len(hb["commands"]) == 1, "命令沒被取走，這條測試等於沒驗"
            got = (await client.get(f"/api/rooms/{rid}/runner", headers=hdr)
                   ).json()["runners"][0]["commands"][0]
            assert got["applied_at"] is None

            # 重啟回來：同 host+label 帶 token 重註冊
            r = await client.post("/api/runners/register",
                                  headers=runner.headers,
                                  json={"host": "esvel-pc", "label": "ex1",
                                        "projects": ["ai-website"],
                                        "max_parallel": 3, "version": "0.1"})
            assert r.status_code == 200, r.text
            got = (await client.get(f"/api/rooms/{rid}/runner", headers=hdr)
                   ).json()["runners"][0]["commands"][0]
            assert got["applied_at"], "重註冊了，那筆命令還停在「已收到」"
            assert "重新啟動" in got["note"]


async def test_a_command_acked_long_ago_is_settled_as_timed_out(tmp_path):
    """取走超過 10 分鐘還沒回報生效＝那個回報丟了，不能讓面板永遠等。"""
    app, client = await _client(tmp_path, "acktimeout")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)
            cmd = (await client.post(f"/api/runners/{runner}/commands",
                                     json={"command": "pause"},
                                     headers=hdr)).json()["command"]
            await client.post(f"/api/runners/{runner}/heartbeat",
                              headers=runner.headers,
                              json={"status": "online"})
            await client.post(f"/api/runners/{runner}/heartbeat",
                              headers=runner.headers,
                              json={"status": "online"})
            got = (await client.get(f"/api/rooms/{rid}/runner", headers=hdr)
                   ).json()["runners"][0]["commands"][0]
            assert got["applied_at"] is None, (
                "剛取走就被當成逾時，那是把還在路上的命令收掉")

            old = (datetime.now(timezone.utc)
                   - timedelta(minutes=11)).isoformat()
            await app.state.db.execute(
                "UPDATE runner_command SET acked_at=? WHERE id=?",
                (old, cmd["id"]))
            await app.state.db.commit()
            await client.post(f"/api/runners/{runner}/heartbeat",
                              headers=runner.headers,
                              json={"status": "online"})
            got = (await client.get(f"/api/rooms/{rid}/runner", headers=hdr)
                   ).json()["runners"][0]["commands"][0]
            assert got["applied_at"], "取走 11 分鐘還停在「已收到」"
            assert "逾時" in got["note"]


async def test_another_runner_cannot_ack_someone_elses_command(tmp_path):
    """別台的 ack 不算數：替別人把命令標成「已生效」＝面板說它照做了，
    而它其實什麼都沒收到。"""
    app, client = await _client(tmp_path, "ackowner")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            mine = await _register_runner(client, label="ex1")
            other = await _register_runner(client, label="ex2")
            cmd = (await client.post(f"/api/runners/{mine}/commands",
                                     json={"command": "pause"},
                                     headers=hdr)).json()["command"]
            await client.post(
                f"/api/runners/{other}/heartbeat", headers=other.headers,
                json={"status": "online",
                      "command_acks": [{"id": cmd["id"],
                                        "applied_at": "2026-09-17T10:00:00Z",
                                        "note": "我替你按的"}]})
            row = await (await app.state.db.execute(
                "SELECT applied_at, note FROM runner_command WHERE id=?",
                (cmd["id"],))).fetchone()
            assert row["applied_at"] is None and row["note"] == ""


async def test_dashboard_json_is_stored_verbatim(tmp_path):
    """Hub **不解讀** dashboard_json：它一旦開始解讀，執行器每加一格就要改兩端。"""
    app, client = await _client(tmp_path, "dashboard")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)
            await client.post(f"/api/rooms/{rid}/runs", json=_run_body(),
                              headers=hdr)
            dash = {"repos": [{"path": "JSAI-Web", "branch": "jsai_dev",
                               "unpushed_count": 2, "dirty": False}],
                    "usage": {"cost_usd": 1.25}}
            await client.post(f"/api/runners/{runner}/heartbeat", headers=runner.headers,
                              json={"status": "online", "running_count": 1,
                                    "dashboard_json": dash})
            body = (await client.get(f"/api/rooms/{rid}/runner",
                                     headers=hdr)).json()
            assert set(body) == {"room_id", "workspace_key",
                                 "workspace_candidates", "runners",
                                 "counts", "queued", "running",
                                 "active_runs"}
            assert body["runners"][0]["dashboard"] == dash
            assert body["runners"][0]["running_count"] == 1
            assert body["queued"] == 1
            assert body["counts"] == {"queued": 1}
            assert len(body["active_runs"]) == 1


# ── 回應形狀 ────────────────────────────────────────────────────────

RUN_KEYS = {
    "id", "room_id", "board_id", "kind", "project", "ref", "brief",
    "requested_by", "requested_by_actor_key", "requested_by_name",
    # 誰動的手（Supervisor 自派工 2026-09-19）。與上面那組「配額算誰的」
    # 分開：Supervisor 代派時兩組是不同的人
    "requester_kind", "requester_name",
    "status", "priority", "position", "runner_id", "claude_session_id",
    "attempt", "parent_run_id", "handoff_depth", "cancel_requested",
    # 收尾請求與 @ 轉達的游標（軟停止／mention 轉達）
    "soft_stop_requested_at", "mention_cursor_seq",
    "usage", "result", "reason",
    # 這一輪是誰做的（participant.run_id 反查）。還沒進房時為 None
    "agent_name",
    "created_at", "claimed_at", "started_at", "ended_at", "updated_at",
}
RUNNER_KEYS = {
    "id", "host", "label", "status", "max_parallel", "running_count",
    "projects", "limited_until", "limit_reason", "usage_window",
    "dashboard", "version", "registered_at", "last_seen_at",
    # 最近幾筆命令與它們的下場（§5.7 回饋鏈）。只有儀表板那條路徑會帶
    "commands",
}


async def test_response_shapes_are_pinned(tmp_path):
    """釘住鍵集合。App 與執行器都照這份形狀寫，少一把鍵是**靜默的缺欄**。"""
    app, client = await _client(tmp_path, "shape")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner_id = await _register_runner(client)
            run = (await client.post(f"/api/rooms/{rid}/runs",
                                     json=_run_body(),
                                     headers=hdr)).json()["run"]
            assert set(run) == RUN_KEYS
            assert run["status"] == "queued"
            assert run["usage"] == {}
            assert run["cancel_requested"] is False

            runner = (await client.get(f"/api/rooms/{rid}/runner",
                                       headers=hdr)).json()["runners"][0]
            assert set(runner) == RUNNER_KEYS

            listing = (await client.get(f"/api/rooms/{rid}/runs?status=queued",
                                        headers=hdr)).json()
            assert set(listing) == {"runs"}
            assert set(listing["runs"][0]) == RUN_KEYS

            one = (await client.get(f"/api/runs/{run['id']}",
                                    headers=hdr)).json()
            assert set(one) == {"run", "events"}
            assert set(one["events"][0]) == {
                "id", "run_id", "room_id", "from_status", "to_status",
                "actor", "actor_name", "reason", "detail_json", "created_at"}

            hb = (await client.post(f"/api/runners/{runner_id}/heartbeat", headers=runner_id.headers,
                                    json={"status": "online"})).json()
            assert set(hb) == {"runner_id", "commands",
                               "cancel_requested_run_ids",
                               "soft_stop_requested_run_ids",
                               "pending_mentions"}

            got = await client.post(f"/api/runners/{runner_id}/claim", headers=runner_id.headers)
            assert set(got.json()) == {"run"}

            report = (await client.post(
                f"/api/runs/{run['id']}/report",
                json={"status": "running", "runner_id": runner_id},
                headers=runner_id.headers)).json()
            assert set(report) == {"run", "child_run"}
            assert report["child_run"] is None


async def test_room_kind_is_served_in_list_and_detail(tmp_path):
    """App 要靠 `kind` 分區顯示——列表少了它，工作房會混在對話裡。"""
    app, client = await _client(tmp_path, "roomkind")
    async with client:
        async with app.router.lifespan_context(app):
            ops = await _ops_room(client)
            chat = (await client.post("/api/rooms", json={
                "name": "一般房", "session_key": "human-a"})).json()["id"]
            key = {"X-Session-Key": "human-a"}
            rooms = (await client.get("/api/rooms",
                                      headers=key)).json()["rooms"]
            kinds = {r["id"]: r["kind"] for r in rooms}
            assert kinds[ops] == "ops"
            assert kinds[chat] == "chat", "沒有指定時要是 chat，不是空字串"
            detail = (await client.get(f"/api/rooms/{ops}",
                                       headers=key)).json()["room"]
            assert detail["kind"] == "ops"


# ── 新表的守門：刪房清單 ─────────────────────────────────────────────

async def test_deleting_an_ops_room_takes_its_runs_with_it(tmp_path):
    """🚨 新表帶著 `room_id` 卻沒登記進刪房清單＝刪房刪到一半撞外鍵。

    `_purge_room` 對帳不過就整個拒絕（那是唯一不留殘局的時機），所以症狀是
    刪不掉；登記錯邊（該刪的沒刪）則是外鍵例外。這條走完整條刪除路徑，
    兩種都抓得到。對帳本身由 `test_room_deletion.py` 的
    `test_the_room_owned_table_list_covers_the_whole_schema` 守。
    """
    app, client = await _client(tmp_path, "deleteops")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)
            run_id = await _drive_to_running(client, rid, hdr, runner, "task-1")
            await client.post(f"/api/runners/{runner}/commands",
                              json={"command": "pause", "room_id": rid},
                              headers=hdr)
            assert await app.state.room_owned_tables_gap() == []

            r = await client.delete(f"/api/rooms/{rid}",
                                    headers={"X-Session-Key": "human-a"})
            assert r.status_code == 200, r.text
            counts = r.json()["deleted"]
            assert counts["agent_run"] == 1
            assert counts["agent_run_event"] >= 3
            left = await (await app.state.db.execute(
                "SELECT COUNT(*) AS n FROM agent_run WHERE id=?",
                (run_id,))).fetchone()
            assert left["n"] == 0
            # 執行器命令**不隨房刪除**：它屬於執行器，房刪掉之後
            # 「誰在什麼時候叫這台執行器暫停過」那段歷史還要成立
            kept = await (await app.state.db.execute(
                "SELECT COUNT(*) AS n FROM runner_command WHERE room_id=?",
                (rid,))).fetchone()
            assert kept["n"] == 1


# ── 軟停止與 @ 轉達 ─────────────────────────────────────────────────

async def _join_run_agent(client, rid, run_id, name="派工執行者"):
    """以 run 的身分加入房間（`claude-run-<run_id>`，§5.4）。"""
    r = await client.post(f"/api/rooms/{rid}/join",
                          json={"kind": "claude", "role": "agent",
                                "session_key": f"claude-run-{run_id}",
                                "preferred_name": name})
    assert r.status_code == 200, r.text
    return r.json()["display_name"]


async def test_soft_stop_marks_the_run_and_reaches_the_heartbeat(tmp_path):
    """收尾請求**不改狀態**：它還在跑，改掉的話畫面會說它停了而 agent 正在
    寫檔。執行器要收得到——只寫進 DB、心跳不帶的話，那顆鈕按下去什麼都沒有
    發生，而 App 上看起來是成功的。
    """
    app, client = await _client(tmp_path, "softstop")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)
            run_id = await _drive_to_running(client, rid, hdr, runner, "task-1")

            body = (await client.post(f"/api/runs/{run_id}/soft-stop",
                                      headers=hdr)).json()
            assert body["soft_stop_requested"] is True
            assert body["run"]["soft_stop_requested_at"]
            assert body["run"]["status"] == "running"

            hb = (await client.post(f"/api/runners/{runner}/heartbeat",
                                    headers=runner.headers,
                                    json={"status": "online",
                                          "running_count": 1})).json()
            assert hb["soft_stop_requested_run_ids"] == [run_id]

            trail = (await client.get(f"/api/runs/{run_id}",
                                      headers=hdr)).json()["events"]
            assert trail[-1]["reason"] == "soft_stop_requested"
            assert trail[-1]["from_status"] == trail[-1]["to_status"]

            msgs = (await client.get(f"/api/rooms/{rid}/messages",
                                     headers=hdr)).json()["messages"]
            said = [m for m in msgs
                    if m.get("system_event") == "run_soft_stop_requested"]
            assert len(said) == 1 and "收到收尾請求" in said[0]["content"]

            # 再按一次是冪等的：房裡不該多出第二則
            again = (await client.post(f"/api/runs/{run_id}/soft-stop",
                                       headers=hdr)).json()
            assert again["run"]["soft_stop_requested_at"] == \
                body["run"]["soft_stop_requested_at"]
            msgs2 = (await client.get(f"/api/rooms/{rid}/messages",
                                      headers=hdr)).json()["messages"]
            assert len([m for m in msgs2 if m.get("system_event")
                        == "run_soft_stop_requested"]) == 1


async def test_soft_stop_needs_a_human_and_a_started_run(tmp_path):
    app, client = await _client(tmp_path, "softstopguard")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)
            queued = (await client.post(f"/api/rooms/{rid}/runs",
                                        json=_run_body("task-q"),
                                        headers=hdr)).json()["run"]["id"]
            r = await client.post(f"/api/runs/{queued}/soft-stop", headers=hdr)
            assert r.status_code == 409
            assert r.json()["detail"]["code"] == "run_not_started"

            run_id = await _drive_to_running(client, rid, hdr, runner, "task-1")
            agent = await client.post(
                f"/api/rooms/{rid}/join",
                json={"kind": "claude", "role": "agent",
                      "session_key": "agent-x", "preferred_name": "旁觀者"})
            r = await client.post(
                f"/api/runs/{run_id}/soft-stop",
                headers={"X-Participant-Id": agent.json()["participant_id"],
                         "X-Session-Key": "agent-x"})
            assert r.status_code == 403


async def test_mentions_reach_the_runner_exactly_once(tmp_path):
    """@ 只轉達一次。重送的話，agent 每一次心跳都會被同一句話再叫一次，
    而它分不出那是新的還是上一輪那則。
    """
    app, client = await _client(tmp_path, "mentions")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)
            run_id = await _drive_to_running(client, rid, hdr, runner, "task-1")

            # 加入之前房裡先有一則 @（給別人的），以及第一次心跳把游標補起來
            await client.post(f"/api/rooms/{rid}/messages",
                              json={"content": "先講一句"}, headers=hdr)
            hb = (await client.post(f"/api/runners/{runner}/heartbeat",
                                    headers=runner.headers,
                                    json={"status": "online"})).json()
            assert hb["pending_mentions"] == {}

            name = await _join_run_agent(client, rid, run_id)
            await client.post(f"/api/rooms/{rid}/messages",
                              json={"content": f"@{name} 先停一下",
                                    "mentions": [name]}, headers=hdr)
            await client.post(f"/api/rooms/{rid}/messages",
                              json={"content": "這句不是給它的"}, headers=hdr)

            hb = (await client.post(f"/api/runners/{runner}/heartbeat",
                                    headers=runner.headers,
                                    json={"status": "online"})).json()
            items = hb["pending_mentions"][run_id]
            assert [i["text"] for i in items] == [f"@{name} 先停一下"]
            assert items[0]["from"] == "艾斯維爾"
            assert items[0]["seq"] > 0

            hb = (await client.post(f"/api/runners/{runner}/heartbeat",
                                    headers=runner.headers,
                                    json={"status": "online"})).json()
            assert hb["pending_mentions"] == {}, "同一則被轉達了第二次"


async def test_mentions_from_before_the_run_joined_are_not_replayed(tmp_path):
    """游標是 0 ＝還沒有游標，此時只把它補到現況。歷史上的 @ 是講給上一輪
    聽的，一次灌進去等於讓剛起跑的 run 先收到一疊跟它無關的話。
    """
    app, client = await _client(tmp_path, "mentionsold")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            runner = await _register_runner(client)
            run_id = await _drive_to_running(client, rid, hdr, runner, "task-1")
            name = await _join_run_agent(client, rid, run_id)
            # 游標還是 0 的狀態下先累積一則 @
            await client.post(f"/api/rooms/{rid}/messages",
                              json={"content": f"@{name} 舊話",
                                    "mentions": [name]}, headers=hdr)
            hb = (await client.post(f"/api/runners/{runner}/heartbeat",
                                    headers=runner.headers,
                                    json={"status": "online"})).json()
            assert hb["pending_mentions"] == {}
