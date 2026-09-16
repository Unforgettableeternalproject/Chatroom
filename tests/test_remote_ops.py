"""遠端派工（Remote Ops）P1：ops 房、佇列、執行器與稽核串。

對應 `docs/REMOTE-OPS-PLAN.md` §4／§5.6／§5.7／§6.1／§6.4／§7／§8 的 P1。

這份檔案守的幾條不變式，每一條都對應一個**安靜的失敗**：

- ops 房被自動封存：下次要派工時才發現房沒了，而封存那一刻沒有人在看
- agent 憑證建得了 run：執行器 token 洩漏＝任何人能派工（§6.4 第一條）
- 兩台執行器領到同一筆：兩個 agent 動同一份工作樹，互相覆蓋
- 稽核串缺一筆：`GET /api/runs/{id}` 回一條看起來完整、實際上有洞的歷史
"""

import asyncio

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
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {token}"})


async def _ops_room(client, key="human-a", name="工作房"):
    r = await client.post("/api/rooms",
                          json={"name": name, "kind": "ops",
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


async def _register_runner(client, projects=("ai-website",), label="ex1"):
    r = await client.post("/api/runners/register",
                          json={"host": "esvel-pc", "label": label,
                                "projects": list(projects),
                                "max_parallel": 3, "version": "0.1"})
    assert r.status_code == 200, r.text
    return r.json()["runner"]["id"]


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
            run_id = (await client.post(f"/api/rooms/{rid}/runs",
                                        json=_run_body(),
                                        headers=hdr)).json()["run"]["id"]
            runners = [await _register_runner(client, label=f"ex{i}")
                       for i in range(8)]
            results = await asyncio.gather(*[
                client.post(f"/api/runners/{r}/claim") for r in runners])
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
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            await client.post(f"/api/rooms/{rid}/runs",
                              json=_run_body(project="other-project"),
                              headers=hdr)
            runner = await _register_runner(client, projects=("ai-website",))
            assert (await client.post(
                f"/api/runners/{runner}/claim")).status_code == 204


# ── 狀態機 ──────────────────────────────────────────────────────────

async def test_illegal_transitions_are_409(tmp_path):
    """狀態機寫成「試試看能不能改」的話，一個回報遲到的執行器可以把已經
    取消的 run 推回 running。"""
    app, client = await _client(tmp_path, "statemachine")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            run_id = (await client.post(f"/api/rooms/{rid}/runs",
                                        json=_run_body(),
                                        headers=hdr)).json()["run"]["id"]
            runner = await _register_runner(client)
            # queued → done 跳過中間：擋
            r = await client.post(f"/api/runs/{run_id}/report",
                                  json={"status": "done",
                                        "runner_id": runner})
            assert r.status_code == 409
            assert r.json()["detail"]["code"] == "run_bad_transition"
            assert r.json()["detail"]["from_status"] == "queued"

            await client.post(f"/api/runners/{runner}/claim")
            assert (await client.post(f"/api/runs/{run_id}/report",
                                      json={"status": "running",
                                            "runner_id": runner})
                    ).status_code == 200
            assert (await client.post(f"/api/runs/{run_id}/report",
                                      json={"status": "done",
                                            "runner_id": runner,
                                            "result": "查完了"})
                    ).status_code == 200
            # 終局之後任何回報都擋
            r = await client.post(f"/api/runs/{run_id}/report",
                                  json={"status": "running",
                                        "runner_id": runner})
            assert r.status_code == 409


async def test_another_runner_cannot_report_someone_elses_run(tmp_path):
    app, client = await _client(tmp_path, "notyourrun")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            run_id = (await client.post(f"/api/rooms/{rid}/runs",
                                        json=_run_body(),
                                        headers=hdr)).json()["run"]["id"]
            mine = await _register_runner(client, label="ex1")
            other = await _register_runner(client, label="ex2")
            await client.post(f"/api/runners/{mine}/claim")
            r = await client.post(f"/api/runs/{run_id}/report",
                                  json={"status": "running",
                                        "runner_id": other})
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "not_your_run"


# ── 取消 ────────────────────────────────────────────────────────────

async def test_cancel_queued_is_immediate_running_is_a_request(tmp_path):
    """running 的 cancel **不改狀態**：進程還在跑，這一端先把狀態改掉的話，
    畫面會說它停了而機器上那個 agent 還在寫檔。"""
    app, client = await _client(tmp_path, "cancel")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
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
            runner = await _register_runner(client)
            await client.post(f"/api/runners/{runner}/claim")
            await client.post(f"/api/runs/{running}/report",
                              json={"status": "running", "runner_id": runner})
            body = (await client.post(f"/api/runs/{running}/cancel",
                                      headers=hdr)).json()
            assert body["cancelled"] is False
            assert body["run"]["status"] == "running"
            assert body["run"]["cancel_requested"] is True

            # 執行器在 heartbeat 拿到取消請求
            hb = (await client.post(f"/api/runners/{runner}/heartbeat",
                                    json={"status": "online"})).json()
            assert hb["cancel_requested_run_ids"] == [running]
            assert (await client.post(f"/api/runs/{running}/report",
                                      json={"status": "cancelled",
                                            "runner_id": runner})
                    ).status_code == 200


# ── 交接 ────────────────────────────────────────────────────────────

async def _drive_to_running(client, rid, hdr, runner, ref):
    run_id = (await client.post(f"/api/rooms/{rid}/runs", json=_run_body(ref),
                                headers=hdr)).json()["run"]["id"]
    await client.post(f"/api/runners/{runner}/claim")
    await client.post(f"/api/runs/{run_id}/report",
                      json={"status": "running", "runner_id": runner})
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
                                            "reason": "context"})).json()
            child = body["child_run"]
            assert body["run"]["status"] == "handoff"
            assert child is not None
            assert child["parent_run_id"] == run_id
            assert child["handoff_depth"] == 1
            assert child["status"] == "queued"
            assert f"前一輪 run {run_id} 已交接，先讀卡 task-1" in child["brief"]
            # 派工者跟著傳下去：子 run 做完要 mention 的是同一個人
            assert child["requested_by_actor_key"] == "human-a"


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
                                                "runner_id": runner})).json()
                child = body["child_run"]
                if child is None:
                    assert body["run"]["status"] == "failed"
                    assert body["run"]["reason"] == "handoff_depth_exceeded"
                    break
                depths.append(child["handoff_depth"])
                run_id = child["id"]
                await client.post(f"/api/runners/{runner}/claim")
                await client.post(f"/api/runs/{run_id}/report",
                                  json={"status": "running",
                                        "runner_id": runner})
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
                                    "reason": "rate_limit"})
            await client.post(f"/api/runs/{a}/report",
                              json={"status": "running", "runner_id": runner})
            await client.post(f"/api/runs/{a}/report",
                              json={"status": "done", "runner_id": runner,
                                    "result": "好了"})
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
                                    "runner_id": runner})
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
                              json={"status": "running", "runner_id": runner})
            after = (await client.get(f"/api/runs/{b}",
                                      headers=hdr)).json()["events"]
            assert len(after) == before

            # ④ 交接：這一輪一筆、子 run 的誕生一筆、上限那次的 failed 一筆
            c = await _drive_to_running(client, rid, hdr, runner, "task-c")
            child = (await client.post(f"/api/runs/{c}/report",
                                       json={"status": "handoff",
                                             "runner_id": runner})
                     ).json()["child_run"]["id"]
            assert [e["to_status"] for e in (
                await client.get(f"/api/runs/{c}", headers=hdr)
            ).json()["events"]] == ["queued", "claimed", "running", "handoff"]
            await client.post(f"/api/runners/{runner}/claim")
            await client.post(f"/api/runs/{child}/report",
                              json={"status": "running", "runner_id": runner})
            await client.post(f"/api/runs/{child}/report",
                              json={"status": "handoff", "runner_id": runner})
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

            await client.post(f"/api/runners/{runner}/claim")
            assert await events_in_room() == [], "領走也不發——那不是 §7 的五件事"

            await client.post(f"/api/runs/{run_id}/report",
                              json={"status": "running", "runner_id": runner})
            await client.post(f"/api/runs/{run_id}/report",
                              json={"status": "limited", "runner_id": runner,
                                    "reason": "rate_limit"})
            await client.post(f"/api/runs/{run_id}/report",
                              json={"status": "running", "runner_id": runner})
            await client.post(f"/api/runs/{run_id}/report",
                              json={"status": "done", "runner_id": runner,
                                    "result": "查完了"})
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
            await client.post(f"/api/runners/{runner}/claim")

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
            await client.post(f"/api/runners/{runner}/heartbeat",
                              json={"status": "online"})
            assert [e for e, _ in await presence_msgs()] == [
                "runner_offline", "runner_online"]


# ── 執行器註冊、命令、儀表板 ──────────────────────────────────────────

async def test_register_is_idempotent_per_host_and_label(tmp_path):
    """重啟一次就多一列的話，離線的通知會對每一個殘影各發一次。"""
    app, client = await _client(tmp_path, "register")
    async with client:
        async with app.router.lifespan_context(app):
            a = await client.post("/api/runners/register",
                                  json={"host": "esvel-pc", "label": "main",
                                        "projects": ["ai-website"]})
            b = await client.post("/api/runners/register",
                                  json={"host": "esvel-pc", "label": "main",
                                        "projects": ["ai-website", "x"],
                                        "version": "0.2"})
            assert a.json()["created"] is True
            assert b.json()["created"] is False
            assert a.json()["runner"]["id"] == b.json()["runner"]["id"]
            assert b.json()["runner"]["projects"] == ["ai-website", "x"]
            assert b.json()["runner"]["version"] == "0.2"


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
            hb = (await client.post(f"/api/runners/{runner}/heartbeat",
                                    json={"status": "paused"})).json()
            assert [c["command"] for c in hb["commands"]] == ["pause", "resume"]
            hb = (await client.post(f"/api/runners/{runner}/heartbeat",
                                    json={"status": "online"})).json()
            assert hb["commands"] == []


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
            await client.post(f"/api/runners/{runner}/heartbeat",
                              json={"status": "online", "running_count": 1,
                                    "dashboard_json": dash})
            body = (await client.get(f"/api/rooms/{rid}/runner",
                                     headers=hdr)).json()
            assert set(body) == {"room_id", "runners", "counts", "queued",
                                 "running", "active_runs"}
            assert body["runners"][0]["dashboard"] == dash
            assert body["runners"][0]["running_count"] == 1
            assert body["queued"] == 1
            assert body["counts"] == {"queued": 1}
            assert len(body["active_runs"]) == 1


# ── 回應形狀 ────────────────────────────────────────────────────────

RUN_KEYS = {
    "id", "room_id", "board_id", "kind", "project", "ref", "brief",
    "requested_by", "requested_by_actor_key", "requested_by_name",
    "status", "priority", "position", "runner_id", "claude_session_id",
    "attempt", "parent_run_id", "handoff_depth", "cancel_requested",
    "usage", "result", "reason",
    "created_at", "claimed_at", "started_at", "ended_at", "updated_at",
}
RUNNER_KEYS = {
    "id", "host", "label", "status", "max_parallel", "running_count",
    "projects", "limited_until", "limit_reason", "usage_window",
    "dashboard", "version", "registered_at", "last_seen_at",
}


async def test_response_shapes_are_pinned(tmp_path):
    """釘住鍵集合。App 與執行器都照這份形狀寫，少一把鍵是**靜默的缺欄**。"""
    app, client = await _client(tmp_path, "shape")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(client)
            hdr = await _join_human(client, rid)
            run = (await client.post(f"/api/rooms/{rid}/runs",
                                     json=_run_body(),
                                     headers=hdr)).json()["run"]
            assert set(run) == RUN_KEYS
            assert run["status"] == "queued"
            assert run["usage"] == {}
            assert run["cancel_requested"] is False

            runner_id = await _register_runner(client)
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

            hb = (await client.post(f"/api/runners/{runner_id}/heartbeat",
                                    json={"status": "online"})).json()
            assert set(hb) == {"runner_id", "commands",
                               "cancel_requested_run_ids"}

            got = await client.post(f"/api/runners/{runner_id}/claim")
            assert set(got.json()) == {"run"}

            report = (await client.post(f"/api/runs/{run['id']}/report",
                                        json={"status": "running",
                                              "runner_id": runner_id})).json()
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
