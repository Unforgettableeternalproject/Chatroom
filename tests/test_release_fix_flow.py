"""每次上板都建 release＋release_fix；fix 嚴重無法上板時打回週期；以及
新規則不溯及既往（legacy）。

- release_fix 的 agent 身分（`claude-run-<fix_id>`）可以對**自己這一批的
  週期**做 reopen 並在其下新增階段；其他 agent 不放寬。
- DATA_VERSION 8 把既有的 release／release_fix 標成 legacy：失敗或取消的
  legacy 不再擋完成、不再讓週期可重新上板、`objective.release.status` 是
  `legacy`；新 run 不受影響。
"""

import pytest
from test_board_release import (PAYLOAD, _attach, _board_id, _clients,
                                _heartbeat, _join_agent, _join_human, _kinds,
                                _obj, _ops_room, _register_runner, _report,
                                _set_run, _verified_with_release)

from chatroom_server.db import DATA_VERSION, _migrate_data

pytestmark = pytest.mark.asyncio


async def _released(human, agent, rid, hdr, runner):
    oid, bid, rel = await _verified_with_release(
        human, agent, rid, hdr, runner, release=True)
    fix = next(x["id"] for x in await _kinds(human, oid)
               if x["kind"] == "release_fix")
    return oid, bid, rel["id"], fix


async def _run_fix_agent(human, agent, rid, runner, release_id, fix_id):
    """release 失敗收場 → fix 被領走並開始 → fix 的 agent 以 run 身分進房。"""
    c = await agent.post(f"/api/runners/{runner}/claim", headers=runner.headers)
    assert c.json()["run"]["id"] == release_id
    await _report(agent, runner, release_id, "running")
    await _report(agent, runner, release_id, "failed", "release_partial")
    c = await agent.post(f"/api/runners/{runner}/claim", headers=runner.headers)
    assert c.status_code == 200 and c.json()["run"]["id"] == fix_id
    await _report(agent, runner, fix_id, "running")
    return await _join_agent(human, rid, f"claude-run-{fix_id}", "修復者")


async def test_fix_agent_can_reopen_its_objective_and_add_a_blocker_stage(
        tmp_path):
    app, human, agent = _clients(tmp_path, "fixreopen")
    async with human, agent:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(human)
            hdr = await _join_human(human, rid)
            runner = await _register_runner(agent)
            await _heartbeat(agent, runner)
            oid, bid, rel, fix = await _released(human, agent, rid, hdr,
                                                 runner)
            fixer = await _run_fix_agent(human, agent, rid, runner, rel, fix)

            r = await human.post(f"/api/board/objectives/{oid}/reopen",
                                 headers=fixer)
            assert r.status_code == 200, r.text
            row = await (await app.state.db.execute(
                "SELECT status FROM board_objective WHERE id=?",
                (oid,))).fetchone()
            assert row["status"] == "active"

            # 週期回到 active 後，在其下新增記錄阻擋項的階段
            st = await human.post(
                f"/api/board/objectives/{oid}/checklists",
                json={"title": "上板阻擋：週期一"}, headers=fixer)
            assert st.status_code == 200, st.text

            # fix 以失敗收場；摘要告訴 App 這是「被打回」
            await _report(agent, runner, fix, "failed",
                          "release_fix_incomplete")
            snap = (await human.get(f"/api/rooms/{rid}/board",
                                    headers=hdr)).json()
            assert _obj(snap, oid)["release"] == {
                "run_id": fix, "status": "failed",
                "reason": "release_blocked_reopened",
                "fix_run_id": fix, "fix_status": "failed"}


async def test_other_agents_still_cannot_reopen(tmp_path):
    app, human, agent = _clients(tmp_path, "fixnotothers")
    async with human, agent:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(human)
            hdr = await _join_human(human, rid)
            runner = await _register_runner(agent)
            await _heartbeat(agent, runner)
            oid, bid, rel, fix = await _released(human, agent, rid, hdr,
                                                 runner)
            other = await _join_agent(human, rid, "claude-worker", "工人")
            r = await human.post(f"/api/board/objectives/{oid}/reopen",
                                 headers=other)
            assert r.status_code == 403, r.text
            assert r.json()["detail"]["code"] == "human_only"


async def test_fix_agent_is_limited_to_its_own_objective_and_lifetime(
        tmp_path):
    app, human, agent = _clients(tmp_path, "fixscope")
    async with human, agent:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(human)
            hdr = await _join_human(human, rid)
            runner = await _register_runner(agent)
            await _heartbeat(agent, runner)
            oid, bid, rel, fix = await _released(human, agent, rid, hdr,
                                                 runner)
            fixer = await _run_fix_agent(human, agent, rid, runner, rel, fix)
            # 另一個 verified 的週期：不是 fix spec 裡的那個
            oid2, _b2, none = await _verified_with_release(
                human, agent, rid, hdr, runner, release=False)
            assert none is None
            r = await human.post(f"/api/board/objectives/{oid2}/reopen",
                                 headers=fixer)
            assert r.status_code == 403, r.text
            assert r.json()["detail"]["code"] == "human_only"

            # fix 收場後，身分就失效
            await _set_run(human, fix, "failed", "release_fix_incomplete")
            r = await human.post(f"/api/board/objectives/{oid}/reopen",
                                 headers=fixer)
            assert r.status_code == 403, r.text


# ── 不溯及既往 ───────────────────────────────────────────────────────

async def _mark_legacy(client, *run_ids):
    db = client.hub_app.state.db
    for rid in run_ids:
        await db.execute("UPDATE agent_run SET legacy=1 WHERE id=?", (rid,))
    await db.commit()


async def test_legacy_failed_release_neither_blocks_complete_nor_reports(
        tmp_path):
    app, human, agent = _clients(tmp_path, "legacycomplete")
    async with human, agent:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(human)
            hdr = await _join_human(human, rid)
            runner = await _register_runner(agent)
            await _heartbeat(agent, runner)
            oid, bid, rel, fix = await _released(human, agent, rid, hdr,
                                                 runner)
            await _set_run(human, rel, "failed", "release_partial")
            await _set_run(human, fix, "failed", "release_fix_incomplete")
            await _mark_legacy(human, rel, fix)

            snap = (await human.get(f"/api/rooms/{rid}/board",
                                    headers=hdr)).json()
            assert _obj(snap, oid)["release"] == {
                "run_id": rel, "status": "legacy",
                "reason": "release_partial", "legacy_status": "failed"}
            done = await human.post(
                f"/api/board/objectives/{oid}/complete", headers=hdr)
            assert done.status_code == 200, done.text


async def test_legacy_failed_release_cannot_be_released_again(tmp_path):
    app, human, agent = _clients(tmp_path, "legacyclosed")
    async with human, agent:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(human)
            hdr = await _join_human(human, rid)
            runner = await _register_runner(agent)
            await _heartbeat(agent, runner)
            oid, bid, rel, fix = await _released(human, agent, rid, hdr,
                                                 runner)
            await _set_run(human, rel, "cancelled", "cancelled_by_human")
            await _set_run(human, fix, "cancelled", "cancelled_by_human")
            await _mark_legacy(human, rel, fix)
            before = await _kinds(human, oid)

            r = await human.post(f"/api/board/objectives/{oid}/release",
                                 json=PAYLOAD, headers=hdr)

            assert r.status_code == 409, r.text
            assert r.json()["detail"]["code"] == "release_legacy_closed"
            assert await _kinds(human, oid) == before


async def test_a_never_released_verified_objective_can_still_release_once(
        tmp_path):
    app, human, agent = _clients(tmp_path, "legacynever")
    async with human, agent:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(human)
            hdr = await _join_human(human, rid)
            runner = await _register_runner(agent)
            await _heartbeat(agent, runner)
            oid, _bid, none = await _verified_with_release(
                human, agent, rid, hdr, runner, release=False)
            assert none is None
            r = await human.post(f"/api/board/objectives/{oid}/release",
                                 json=PAYLOAD, headers=hdr)
            assert r.status_code == 200, r.text
            assert r.json()["fix_run"]["kind"] == "release_fix"


async def test_new_runs_after_a_legacy_one_are_not_affected(tmp_path):
    """打回再確認（verified_at 更新）後，舊的 legacy 失敗不再擋上板；新
    run 照新規則計算。"""
    app, human, agent = _clients(tmp_path, "legacyreverify")
    async with human, agent:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(human)
            hdr = await _join_human(human, rid)
            runner = await _register_runner(agent)
            await _heartbeat(agent, runner)
            oid, bid, rel, fix = await _released(human, agent, rid, hdr,
                                                 runner)
            await _set_run(human, rel, "failed", "release_partial")
            await _set_run(human, fix, "failed", "release_fix_incomplete")
            await _mark_legacy(human, rel, fix)

            # 打回 → 再送審 → 確認時重新上板
            r = await human.post(f"/api/board/objectives/{oid}/reopen",
                                 headers=hdr)
            assert r.status_code == 200, r.text
            sender = await _join_agent(agent, rid, "claude-worker2", "工人二")
            r = await agent.post(f"/api/board/objectives/{oid}/review",
                                 headers=sender)
            assert r.status_code == 200, r.text
            r = await human.post(
                f"/api/board/objectives/{oid}/verify",
                json={"release": PAYLOAD}, headers=hdr)
            assert r.status_code == 200, r.text
            new_run = r.json()["release_run"]["id"]
            new_fix = r.json()["release_fix_run"]["id"]
            assert new_run not in (rel, fix)

            # 新 run 失敗就是失敗：照新規則擋完成
            await _set_run(human, new_run, "failed", "release_partial")
            await _set_run(human, new_fix, "failed", "release_fix_incomplete")
            snap = (await human.get(f"/api/rooms/{rid}/board",
                                    headers=hdr)).json()
            assert _obj(snap, oid)["release"]["status"] == "failed"
            blocked = await human.post(
                f"/api/board/objectives/{oid}/complete", headers=hdr)
            assert blocked.status_code == 409, blocked.text
            assert blocked.json()["detail"]["code"] == "release_not_done"


async def test_migration_marks_existing_runs_legacy_once_and_is_idempotent(
        tmp_path):
    app, human, agent = _clients(tmp_path, "legacymigrate")
    async with human, agent:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(human)
            hdr = await _join_human(human, rid)
            runner = await _register_runner(agent)
            await _heartbeat(agent, runner)
            oid, bid, rel, fix = await _released(human, agent, rid, hdr,
                                                 runner)
            db = app.state.db
            # 模擬升級前的庫：版次退回 7、run 全是 legacy=0
            await db.execute("PRAGMA user_version=7")
            await db.execute("UPDATE agent_run SET legacy=0")
            await db.commit()

            await _migrate_data(db)
            rows = await (await db.execute(
                "SELECT kind, legacy FROM agent_run ORDER BY created_at"
            )).fetchall()
            by_kind = {r["kind"]: r["legacy"] for r in rows}
            assert by_kind["release"] == 1 and by_kind["release_fix"] == 1
            assert by_kind.get("ticket", 0) == 0, "只標 release／release_fix"
            ver = (await (await db.execute("PRAGMA user_version")
                          ).fetchone())[0]
            assert ver == DATA_VERSION

            # 之後新建的 run 預設 0；再跑一次遷移不會把它們誤標
            await _set_run(human, rel, "failed", "release_partial")
            await _set_run(human, fix, "failed", "release_fix_incomplete")
            again = await human.post(f"/api/board/objectives/{oid}/release",
                                     json=PAYLOAD, headers=hdr)
            # 舊的已是 legacy failed 且在這次確認之後 ⇒ 不再提供
            assert again.status_code == 409, again.text
            await _migrate_data(db)
            assert (await (await db.execute(
                "SELECT COUNT(*) AS n FROM agent_run WHERE legacy=1"
            )).fetchone())["n"] == 2
