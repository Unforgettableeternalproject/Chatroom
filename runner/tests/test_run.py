"""一筆 run 的執行（REMOTE-OPS-PLAN §5.2～§5.6）。

Hub 是**真的** P1 端點（in-process ASGI），claude 是假的。每條測試都盯著一個
會安靜失敗的地方：狀態沒回報、退避沒發生、交接沒立旗標、取消沒殺到進程、
push 推了不是畫面上那幾顆。
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import subprocess
import sys
from pathlib import Path

import pytest

from chatroom_runner import run as run_module
from chatroom_runner.run import (RepoLocks, RepoLockTimeout, RunExecutor,
                                 resolve_repo, short_id)
from chatroom_runner.usage import UsageStore

from ._fixtures import FAKE_CLAUDE, create_run, git, make_config

HOOK = str(Path(__file__).resolve().parents[1]
           / "chatroom_runner" / "hooks" / "pretooluse.py")


async def _claimed_run(client, room_id, headers, runner_hub, **body):
    await runner_hub.register("test-host", "test", ["ai-website"], 2, "0.1")
    created = await create_run(client, room_id, headers, **body)
    claimed = await runner_hub.claim()
    assert claimed is not None and claimed["id"] == created["id"]
    return claimed


def _executor(cfg, hub, **kw):
    return RunExecutor(cfg, hub, usage_store=UsageStore(cfg.usage_db), **kw)


async def _trail(client, run_id, headers):
    body = (await client.get(f"/api/runs/{run_id}", headers=headers)).json()
    return body["run"], [e["to_status"] for e in body["events"]]


# ── 全鏈：claim → running → done ────────────────────────────────

async def test_full_chain_to_done(hub_app, ops_room, runner_hub, work_repo,
                                  tmp_path, monkeypatch):
    _app, client = hub_app
    room_id, headers = ops_room
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "success")
    run = await _claimed_run(client, room_id, headers, runner_hub,
                             kind="ticket", ref="task-done")
    cfg = make_config(tmp_path, work_repo)

    outcome = await _executor(cfg, runner_hub).execute(run)

    assert outcome.status == "done"
    final, trail = await _trail(client, run["id"], headers)
    assert final["status"] == "done"
    assert trail == ["queued", "claimed", "running", "done"], \
        "稽核串缺一段就等於一條看起來完整、實際上有洞的歷史"
    assert final["claude_session_id"] == "fake-session-0001"
    # 收工摘要要同時有 agent 自己寫的與執行器補的 exit 資訊
    assert "已完成" in final["result"]
    assert "執行器附註" in final["result"]
    assert "HEAD" in final["result"]
    assert final["usage"]["num_turns"] == 5


async def test_success_subtype_with_error_is_still_failed(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, monkeypatch):
    """🚨 成敗看 exit code 與 `is_error`，**不是只看 subtype**。

    實測 2.1.273：未登入時 `result.subtype` 照樣是 `success`，而那一輪什麼
    都沒做。只看 subtype 的執行器會把它標成完成，卡就這樣被結掉了。
    """
    _app, client = hub_app
    room_id, headers = ops_room
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "not_logged_in")
    run = await _claimed_run(client, room_id, headers, runner_hub,
                             ref="task-notlogin")
    cfg = make_config(tmp_path, work_repo)

    outcome = await _executor(cfg, runner_hub).execute(run)

    assert outcome.status == "failed"
    final, _ = await _trail(client, run["id"], headers)
    assert final["status"] == "failed"


async def test_max_turns_is_failed(hub_app, ops_room, runner_hub, work_repo,
                                   tmp_path, monkeypatch):
    _app, client = hub_app
    room_id, headers = ops_room
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "max_turns")
    run = await _claimed_run(client, room_id, headers, runner_hub,
                             ref="task-turns")
    cfg = make_config(tmp_path, work_repo)

    outcome = await _executor(cfg, runner_hub).execute(run)

    assert (outcome.status, outcome.reason) == ("failed", "max_turns")


# ── rate limit 與退避 ───────────────────────────────────────────

async def test_rate_limit_backs_off_and_resumes(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, monkeypatch):
    """撞到額度 → 報 limited → 退避 → `--resume` 續跑。

    **每一次退避都要 report 一次**：那是房裡唯一看得到「它還活著、只是在等」
    的地方。不報的話，一個退避 60 分鐘的 run 在面板上與當掉沒有分別。
    """
    _app, client = hub_app
    room_id, headers = ops_room
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "rate_limit_then_ok")
    run = await _claimed_run(client, room_id, headers, runner_hub,
                             ref="task-rate")
    cfg = make_config(tmp_path, work_repo)
    slept: list[float] = []

    async def fake_sleep(seconds):
        slept.append(seconds)

    outcome = await _executor(cfg, runner_hub, sleep=fake_sleep).execute(run)

    assert outcome.status == "done"
    assert slept == [60], "第一階退避是 1 分鐘（測試設定），而且只該退一次"
    final, trail = await _trail(client, run["id"], headers)
    assert trail == ["queued", "claimed", "running", "limited", "running",
                     "done"]
    assert final["status"] == "done"


async def test_rate_limit_exhausted_becomes_failed(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, monkeypatch):
    _app, client = hub_app
    room_id, headers = ops_room
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "rate_limit")
    run = await _claimed_run(client, room_id, headers, runner_hub,
                             ref="task-rate2")
    cfg = make_config(tmp_path, work_repo)
    slept: list[float] = []

    outcome = await _executor(
        cfg, runner_hub,
        sleep=lambda s: _record(slept, s)).execute(run)

    assert (outcome.status, outcome.reason) == ("failed",
                                                "rate_limit_exhausted")
    assert slept == [60, 120], "兩階退避都用完才放棄"


async def _record(bucket, seconds):
    bucket.append(seconds)


async def test_weekly_limit_stops_the_runner_and_never_retries(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, monkeypatch):
    """週上限是終端錯誤：run 標 limited、整台執行器停收，**不重試**。

    重試只是把同一句話再撞一次，而每撞一次都要等一輪退避。
    """
    _app, client = hub_app
    room_id, headers = ops_room
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "weekly")
    run = await _claimed_run(client, room_id, headers, runner_hub,
                             ref="task-weekly")
    cfg = make_config(tmp_path, work_repo)
    limited: list[str] = []
    slept: list[float] = []

    outcome = await _executor(
        cfg, runner_hub, sleep=lambda s: _record(slept, s),
        on_runner_limited=limited.append).execute(run)

    assert (outcome.status, outcome.reason) == ("limited", "weekly_limit")
    assert limited == ["weekly_limit"]
    assert slept == [], "週上限不該進退避迴圈"
    final, _ = await _trail(client, run["id"], headers)
    assert final["status"] == "limited"


# ── chatroom MCP 是前置條件 ─────────────────────────────────────

async def test_chatroom_mcp_pending_is_retried_until_it_connects(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, monkeypatch):
    """開場 chatroom 不是 `connected` ⇒ 殺掉重起，連上了就照常跑。

    實測 run 401a66ab：pending 的那一輪整份 stream 零筆 chatroom 工具呼叫，
    agent 自己改走別的工具盲做一整輪——沒有 join、沒讀卡、收尾也沒寫卡。
    重起才有第二次機會，而這是**唯一**的機會：init 之後不會再有事件來更正。
    """
    _app, client = hub_app
    room_id, headers = ops_room
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "mcp_pending_then_ok")
    monkeypatch.setenv("FAKE_CLAUDE_MCP_OK_AT", "3")
    run = await _claimed_run(client, room_id, headers, runner_hub,
                             kind="ticket", ref="task-mcp-retry")
    cfg = make_config(tmp_path, work_repo,
                      mcp_retries=3, mcp_retry_backoff_seconds=[1, 2, 3])
    slept: list[float] = []

    outcome = await _executor(
        cfg, runner_hub, sleep=lambda s: _record(slept, s)).execute(run)

    assert outcome.status == "done"
    assert slept == [1, 2], "第三次才連上 ⇒ 只該退避兩次，間隔遞增"
    final, _ = await _trail(client, run["id"], headers)
    assert final["status"] == "done"
    attempts = (cfg.runs_dir / run["id"] / "mcp_attempts").read_text(
        encoding="utf-8")
    assert attempts == "3", "前兩次都該被殺掉，不是讓它繼續盲做"


async def test_chatroom_mcp_never_connects_fails_with_a_named_error(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, monkeypatch):
    """重試耗盡 ⇒ `failed` + `chatroom_mcp_unavailable`，**不盲跑**。

    艾斯維爾裁決 09/19：進不了房就直接報錯誤並收尾。理由字串要叫得出名字
    ——報一個 `exit_0` 的話，房裡看到的是一筆莫名其妙失敗的 run。
    """
    _app, client = hub_app
    room_id, headers = ops_room
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "mcp_pending")
    run = await _claimed_run(client, room_id, headers, runner_hub,
                             kind="ticket", ref="task-mcp-dead")
    cfg = make_config(tmp_path, work_repo,
                      mcp_retries=2, mcp_retry_backoff_seconds=[1, 2])
    slept: list[float] = []

    outcome = await _executor(
        cfg, runner_hub, sleep=lambda s: _record(slept, s)).execute(run)

    assert (outcome.status, outcome.reason) == ("failed",
                                                "chatroom_mcp_unavailable")
    assert slept == [1, 2], "兩次重試都用完才放棄"
    final, _ = await _trail(client, run["id"], headers)
    assert final["status"] == "failed"
    assert "chatroom MCP" in final["result"]
    assert "前置條件" in final["result"], "要講得出為什麼不跑，不只是失敗"
    attempts = (cfg.runs_dir / run["id"] / "mcp_attempts").read_text(
        encoding="utf-8")
    assert attempts == "3", "首次 + 兩次重試"


async def test_chatroom_mcp_pending_kills_a_still_talking_child(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, monkeypatch):
    """開場 pending 中止時，子進程要是**正在動**的，不是恰好在睡的（埃里爾
    09/21 除錯）。

    `mcp_pending` 情境驗的是「殺的時候它剛好在睡」，睡眠中的進程被殺與沒被
    殺、外部都看不出差別。這裡用 `mcp_pending_noisy`：init 之後**持續吐事件**
    直到被殺——殺乾淨的話，`_spawn` 回來之後 stream.jsonl 不會再變大；沒殺乾
    淨的話，它會一直長到 `FAKE_CLAUDE_SLEEP` 的長睡上限（實測 09/20 run
    5ba6caa5、09/21 run 57c3ae48 的除錯起點）。
    """
    _app, client = hub_app
    room_id, headers = ops_room
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "mcp_pending_noisy")
    monkeypatch.setenv("FAKE_CLAUDE_SLEEP", "10")
    run = await _claimed_run(client, room_id, headers, runner_hub,
                             kind="ticket", ref="task-mcp-noisy")
    cfg = make_config(tmp_path, work_repo,
                      mcp_retries=0, mcp_retry_backoff_seconds=[])
    killed: list[int] = []
    real_kill = run_module.kill_tree
    monkeypatch.setattr(run_module, "kill_tree",
                        lambda pid: (killed.append(pid), real_kill(pid))[1])

    outcome = await asyncio.wait_for(
        _executor(cfg, runner_hub).execute(run), timeout=30)

    assert (outcome.status, outcome.reason) == ("failed",
                                                "chatroom_mcp_unavailable")
    assert killed, "子進程沒被殺：它會照 FAKE_CLAUDE_SLEEP 一直吐到上限"
    stream = cfg.runs_dir / run["id"] / "stream.jsonl"
    size_at_return = stream.stat().st_size
    # 給任何還活著的殘留進程一點時間，如果它還在吐，這裡會抓到成長
    await asyncio.sleep(1.0)
    assert stream.stat().st_size == size_at_return, (
        "execute() 回來之後 stream 還在長大：子進程沒有真的死")


async def test_chatroom_mcp_retry_report_does_not_hit_run_bad_transition(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, monkeypatch):
    """重試中的 running 回報要落在 Hub 的同狀態白名單裡（`stalled`／
    `resumed`），不能再用 `mcp_retry_N` 這種撞 409 的 reason（埃里爾 09/21
    除錯：09/20 run 5ba6caa5、09/21 run 57c3ae48 兩筆都撞了這個 409——雖然
    `hub.report` 把它當成已套用處理、不影響最終結果，但每次重試都留一則看
    起來像失敗的警告，混淆了真正的根因）。"""
    _app, client = hub_app
    room_id, headers = ops_room
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "mcp_pending_then_ok")
    monkeypatch.setenv("FAKE_CLAUDE_MCP_OK_AT", "2")
    run = await _claimed_run(client, room_id, headers, runner_hub,
                             kind="ticket", ref="task-mcp-resumed-reason")
    cfg = make_config(tmp_path, work_repo,
                      mcp_retries=2, mcp_retry_backoff_seconds=[1, 2])
    reported: list[tuple[str, str]] = []
    real_report = runner_hub.report

    async def spy_report(run_id, status, **kw):
        reported.append((status, kw.get("reason", "")))
        return await real_report(run_id, status, **kw)

    monkeypatch.setattr(runner_hub, "report", spy_report)

    outcome = await _executor(cfg, runner_hub).execute(run)

    assert outcome.status == "done"
    running_reasons = [reason for status, reason in reported
                       if status == "running"]
    assert "resumed" in running_reasons
    assert not any(r.startswith("mcp_retry_") for r in running_reasons), \
        "mcp_retry_N 不在 Hub 的同狀態白名單裡，會撞 409 run_bad_transition"


async def test_chatroom_mcp_connected_runs_without_any_retry(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, monkeypatch):
    """connected 的開場一切照舊——前置條件檢查不該動到正常路徑。"""
    _app, client = hub_app
    room_id, headers = ops_room
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "mcp_connected")
    run = await _claimed_run(client, room_id, headers, runner_hub,
                             kind="ticket", ref="task-mcp-ok")
    cfg = make_config(tmp_path, work_repo)
    slept: list[float] = []

    outcome = await _executor(
        cfg, runner_hub, sleep=lambda s: _record(slept, s)).execute(run)

    assert outcome.status == "done"
    assert slept == []
    final, trail = await _trail(client, run["id"], headers)
    assert trail == ["queued", "claimed", "running", "done"]
    assert "進房讀卡" in final["result"]


# ── context 軟閾值 → 交接 ───────────────────────────────────────

async def test_context_soft_limit_raises_flag_and_hands_off(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, monkeypatch):
    """context 估算過閾值 → 立 `handoff.flag` → hook 擋下一次工具呼叫 →
    run 以 handoff 收尾 → Hub 建子 run。

    這是**唯一**能在自動壓縮之前逼 agent 交接的路徑（§5.3）。
    """
    _app, client = hub_app
    room_id, headers = ops_room
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "context")
    run = await _claimed_run(client, room_id, headers, runner_hub,
                             kind="ticket", ref="task-context")
    cfg = make_config(tmp_path, work_repo)

    outcome = await _executor(cfg, runner_hub).execute(run)

    assert (outcome.status, outcome.reason) == ("handoff",
                                                "context_soft_limit")
    run_dir = cfg.runs_dir / run["id"]
    flag = run_dir / "handoff.flag"
    assert flag.exists()
    assert json.loads(flag.read_text(encoding="utf-8"))["context_tokens"] \
        >= int(200000 * 0.7)

    # 旗標立起來之後，hook 對任何工具呼叫都回 exit 2
    proc = subprocess.run(
        [sys.executable, HOOK],
        input=json.dumps({"tool_name": "Bash",
                          "tool_input": {"command": "git status"}}),
        # hook 的 stderr 是 UTF-8（Claude Code 就是這樣讀），不能用主控台的 CP950 解
        text=True, encoding="utf-8", capture_output=True,
        env={**_env(), "CHATROOM_RUNNER_RUN_DIR": str(run_dir)})
    assert proc.returncode == 2
    assert "context 已達上限" in proc.stderr

    runs = (await client.get(f"/api/rooms/{room_id}/runs",
                             headers=headers)).json()["runs"]
    children = [r for r in runs if r["parent_run_id"] == run["id"]]
    assert len(children) == 1, "交接沒有下一棒的話，面板上與『正在交接』一樣"
    assert children[0]["status"] == "queued"
    assert str(run["id"]) in children[0]["brief"]


def _env():
    import os
    return dict(os.environ)


# ── 取消 ────────────────────────────────────────────────────────

async def test_cancel_kills_the_child_and_reports_cancelled(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, monkeypatch):
    """取消是「殺完再回報」：Hub 先改狀態的話，畫面會說它停了而 agent
    還在寫檔（§4.2）。"""
    _app, client = hub_app
    room_id, headers = ops_room
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "long")
    monkeypatch.setenv("FAKE_CLAUDE_SLEEP", "60")
    run = await _claimed_run(client, room_id, headers, runner_hub,
                             ref="task-cancel")
    cfg = make_config(tmp_path, work_repo)
    cancel = asyncio.Event()
    task = asyncio.ensure_future(_executor(cfg, runner_hub).execute(run,
                                                                    cancel))

    stream = cfg.runs_dir / run["id"] / "stream.jsonl"
    for _ in range(200):
        await asyncio.sleep(0.05)
        if stream.exists() and stream.stat().st_size > 0:
            break
    assert stream.exists() and stream.stat().st_size > 0, "子進程根本沒起來"

    # 人類在 Hub 按取消：running 的 run **不改狀態**，只立旗標
    r = await client.post(f"/api/runs/{run['id']}/cancel", headers=headers)
    assert r.status_code == 200 and r.json()["cancelled"] is False
    beat = await runner_hub.heartbeat("online", 1, {}, {})
    assert run["id"] in beat["cancel_requested_run_ids"]

    cancel.set()
    outcome = await asyncio.wait_for(task, timeout=60)

    assert outcome.status == "cancelled"
    final, _ = await _trail(client, run["id"], headers)
    assert final["status"] == "cancelled"


# ── 同 repo 的寫入鎖 ────────────────────────────────────────────

async def test_one_writer_per_repo(hub_app, ops_room, runner_hub, work_repo,
                                   tmp_path, monkeypatch):
    """同一個 repo 同時只有一個寫入型 run；等待中的那一筆要看得見、要收得完。

    PM 記憶裡「共用工作樹互相覆蓋」「commit 帶走別人的 index」發生過不只
    一次；遠端無人看著時代價更高。

    埃里爾 09/21 除錯：`a70bcd9a` 領到單後卡在這把鎖上，Hub 停在 claimed、
    沒有回報、沒有 run 目錄、log 一個字都沒有——跟「執行器掛了」長得一模
    一樣。等待中要主動回報一次 running（reason=repo_lock_wait），第一筆
    結束後要自己接著跑完，不能永遠卡住。
    """
    _app, client = hub_app
    room_id, headers = ops_room
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "long")
    monkeypatch.setenv("FAKE_CLAUDE_SLEEP", "1.5")
    await runner_hub.register("test-host", "test", ["ai-website"], 2, "0.1")
    first = await create_run(client, room_id, headers, kind="ticket",
                             ref="task-lock-1")
    second = await create_run(client, room_id, headers, kind="ticket",
                              ref="task-lock-2")
    a = await runner_hub.claim()
    b = await runner_hub.claim()
    cfg = make_config(tmp_path, work_repo)
    locks = RepoLocks()
    reported: list[tuple[str, str, str]] = []
    real_report = runner_hub.report

    async def spy_report(run_id, status, **kw):
        reported.append((run_id, status, kw.get("reason", "")))
        return await real_report(run_id, status, **kw)

    monkeypatch.setattr(runner_hub, "report", spy_report)

    cancel_a, cancel_b = asyncio.Event(), asyncio.Event()
    task_a = asyncio.ensure_future(
        _executor(cfg, runner_hub, locks=locks).execute(a, cancel_a))
    task_b = asyncio.ensure_future(
        _executor(cfg, runner_hub, locks=locks).execute(b, cancel_b))
    try:
        # 🚨 等 `locks.is_held()` 不夠：那把鎖在拿到的當下就會是 True，遠早於
        # `_write_run_files` 真的落地 `stream.jsonl`——用它判斷 holder 會兩邊
        # 都還不存在，隨便挑到一個當 holder。要等到**真的有一邊起了進程**
        started: list[dict] = []
        for _ in range(200):
            started = [r for r in (a, b)
                      if (cfg.runs_dir / r["id"] / "stream.jsonl").exists()]
            if started:
                break
            await asyncio.sleep(0.05)
        assert started, "等了 10 秒，兩筆都沒有起進程"
        holder = started[0]
        other = b if holder is a else a
        assert not (cfg.runs_dir / other["id"] / "stream.jsonl").exists(), \
            "第二筆不該在第一筆還握著 repo 鎖時起進程"
        # 等待回報是另一個 task 的 await 鏈，不保證跟這裡的 `sleep(0)` 同一輪
        # 排到——用輪詢代替固定 sleep，避免系統忙的時候變成假性失敗
        blocked = {}
        for _ in range(200):
            blocked = (await client.get(f"/api/runs/{other['id']}",
                                        headers=headers)).json()["run"]
            if blocked["status"] != "claimed":
                break
            await asyncio.sleep(0.05)
        assert blocked["status"] == "running", \
            "等待中要主動報一次 running，不能停在 claimed 看起來像掛了"
        assert blocked["reason"] == "repo_lock_wait"
        assert short_id(holder["id"]) in (blocked.get("result") or ""), \
            "附註要講出正在等哪一筆 run"

        # 上面都對了才讓兩筆自然跑完——**不能在這裡先 cancel**：
        # 那正是要驗的事（第一筆結束後，等待中的那一筆會不會自己接著跑）
        outcome_a, outcome_b = await asyncio.wait_for(
            asyncio.gather(task_a, task_b), timeout=90)
    except BaseException:
        # 🚨 任何一個 assert 炸掉都要在這裡把兩個 task 收乾淨，不能留給測試
        # 函式回來之後才收：沒等到的 task 會撞進下一個測試已經關掉的
        # httpx client（埃里爾 09/21 除錯：這裡漏收曾經拖垮過後面兩個測試）
        cancel_a.set()
        cancel_b.set()
        await asyncio.wait_for(
            asyncio.gather(task_a, task_b, return_exceptions=True),
            timeout=90)
        raise
    assert outcome_a.status == "done"
    assert outcome_b.status == "done", "第一筆結束後，等待中的那一筆要自己接著跑完"
    other_reports = [(status, reason) for run_id, status, reason in reported
                     if run_id == other["id"]]
    assert ("running", "repo_lock_wait") in other_reports
    final_other, _ = await _trail(client, other["id"], headers)
    assert final_other["status"] == "done"
    assert first["id"] and second["id"]


async def test_single_writer_off_runs_in_parallel(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, monkeypatch):
    """房間關掉單一寫入者限制時，同 repo 的兩筆寫入型 run 同時開跑。

    `single_writer=False` 由 Hub 從房間帶出來。關掉的只有排隊規則：兩筆都要
    真的起進程、都要報 running，而且**不能**出現 `repo_lock_wait`——那代表
    其中一筆還是排在鎖後面，等於這個開關沒有作用。

    派工前的同步（fetch ＋ ff-only）仍然序列化（敏卡裁決 09/21）：兩筆同時
    在同一份工作樹上 pull 會 fatal，輸的那筆會以 `sync_not_fast_forward`
    收場——那是並行的副作用，不是它自己的問題。
    """
    _app, client = hub_app
    room_id, headers = ops_room
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "long")
    monkeypatch.setenv("FAKE_CLAUDE_SLEEP", "1.5")
    await runner_hub.register("test-host", "test", ["ai-website"], 2, "0.1")
    await create_run(client, room_id, headers, kind="ticket",
                     ref="task-parallel-1")
    await create_run(client, room_id, headers, kind="ticket",
                     ref="task-parallel-2")
    a = await runner_hub.claim()
    b = await runner_hub.claim()
    # Hub 端的欄位另一位在加；這裡模擬領到的 run 物件已經帶著它
    a["single_writer"] = False
    b["single_writer"] = False
    cfg = make_config(tmp_path, work_repo)
    locks = RepoLocks()
    reported: list[tuple[str, str, str, str]] = []
    real_report = runner_hub.report

    async def spy_report(run_id, status, **kw):
        reported.append((run_id, status, kw.get("reason", ""),
                         kw.get("result") or ""))
        return await real_report(run_id, status, **kw)

    monkeypatch.setattr(runner_hub, "report", spy_report)

    cancel_a, cancel_b = asyncio.Event(), asyncio.Event()
    task_a = asyncio.ensure_future(
        _executor(cfg, runner_hub, locks=locks).execute(a, cancel_a))
    task_b = asyncio.ensure_future(
        _executor(cfg, runner_hub, locks=locks).execute(b, cancel_b))
    try:
        started: list[dict] = []
        for _ in range(200):
            started = [r for r in (a, b)
                       if (cfg.runs_dir / r["id"] / "stream.jsonl").exists()]
            if len(started) == 2:
                break
            await asyncio.sleep(0.05)
        assert len(started) == 2, "關掉限制後兩筆都該起進程，不該有人在排隊"
        outcome_a, outcome_b = await asyncio.wait_for(
            asyncio.gather(task_a, task_b), timeout=90)
    except BaseException:
        cancel_a.set()
        cancel_b.set()
        await asyncio.wait_for(
            asyncio.gather(task_a, task_b, return_exceptions=True),
            timeout=90)
        raise
    assert outcome_a.status == "done" and outcome_b.status == "done",         "派工前的同步仍走鎖，兩筆都不該以 sync_not_fast_forward 收場"
    assert not [r for r in (outcome_a, outcome_b)
                if r.reason == "sync_not_fast_forward"]
    reasons = {(run_id, reason) for run_id, _s, reason, _r in reported}
    assert not [r for r in reasons if r[1] == "repo_lock_wait"], \
        "關掉限制後不該有人等 repo 鎖"
    for run in (a, b):
        assert (run["id"], "running", "spawn") in {
            (rid, status, reason) for rid, status, reason, _r in reported}
        notes = [result for rid, status, reason, result in reported
                 if rid == run["id"] and reason == "spawn"]
        assert any("並行" in n for n in notes), "第一次 running 要講出是並行的"


async def test_repo_lock_wait_timeout_reports_failed(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, monkeypatch):
    """等 repo 鎖等過牆鐘上限就收成 failed，不能永遠空等。"""
    _app, client = hub_app
    room_id, headers = ops_room
    run = await _claimed_run(client, room_id, headers, runner_hub,
                             kind="ticket", ref="task-lock-timeout")
    cfg = make_config(tmp_path, work_repo)

    class _AlwaysTimesOut(RepoLocks):
        @contextlib.asynccontextmanager
        async def hold(self, keys, *, run_id="", timeout=None, on_wait=None):
            raise RepoLockTimeout(keys, {keys[0]: "abc12345"})
            yield  # pragma: no cover - 上一行必定先丟例外

    executor = _executor(cfg, runner_hub, locks=_AlwaysTimesOut())
    outcome = await executor.execute(run)

    assert outcome.status == "failed"
    assert outcome.reason == "repo_lock_timeout"
    assert "abc12345" in outcome.result
    final, trail = await _trail(client, run["id"], headers)
    assert final["status"] == "failed"
    assert final["reason"] == "repo_lock_timeout"


async def test_investigate_does_not_take_the_write_lock(work_repo, tmp_path,
                                                        monkeypatch):
    """investigate 只讀，不必排在寫入型 run 後面。

    把它也排進同一把鎖的話，一個跑一小時的 ticket 會讓「我只想知道這件事」
    等一小時——而它根本不會動到工作樹。
    """
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "success")
    cfg = make_config(tmp_path, work_repo)
    locks = RepoLocks()
    ex = RunExecutor(cfg, _NullHub(), locks=locks)
    await locks.get("ai-website/JSAI-Web").acquire()
    try:
        run = {"id": "r-inv", "kind": "investigate", "project": "ai-website",
               "ref": "task-x", "brief": "", "room_id": "room"}
        outcome = await asyncio.wait_for(ex.execute(run), timeout=60)
        assert outcome.status == "done"
    finally:
        locks.get("ai-website/JSAI-Web").release()


class _NullHub:
    async def report(self, *a, **kw):
        return None


# ── push run（不經模型）─────────────────────────────────────────

async def test_push_run_refuses_when_sha_sets_differ(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    """儀表板看到的與現在的不一致就不推。

    按鈕的人以為自己推的是畫面上那幾顆；多出來的那一顆是誰的、要不要推，
    不是執行器能決定的事。
    """
    _app, client = hub_app
    room_id, headers = ops_room
    (work_repo / "a.txt").write_text("a", encoding="utf-8")
    git(work_repo, "add", "a.txt")
    git(work_repo, "commit", "-m", "第一顆")
    stale = git(work_repo, "rev-parse", "HEAD")
    (work_repo / "b.txt").write_text("b", encoding="utf-8")
    git(work_repo, "add", "b.txt")
    git(work_repo, "commit", "-m", "第二顆")

    run = await _claimed_run(client, room_id, headers, runner_hub,
                             kind="push", ref="JSAI-Web",
                             brief=f"branch: jsai_dev\n{stale}")
    cfg = make_config(tmp_path, work_repo)

    outcome = await _executor(cfg, runner_hub).execute(run)

    assert (outcome.status, outcome.reason) == ("failed", "push_sha_mismatch")
    assert git(work_repo, "log", "origin/jsai_dev..jsai_dev",
               "--format=%H").count("\n") == 1, "不一致時一顆都不該推上去"


async def test_push_run_pushes_when_sha_sets_match(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    _app, client = hub_app
    room_id, headers = ops_room
    (work_repo / "a.txt").write_text("a", encoding="utf-8")
    git(work_repo, "add", "a.txt")
    git(work_repo, "commit", "-m", "要推的那顆")
    sha = git(work_repo, "rev-parse", "HEAD")

    run = await _claimed_run(client, room_id, headers, runner_hub,
                             kind="push", ref="JSAI-Web",
                             brief=f"branch: jsai_dev\n{sha}")
    cfg = make_config(tmp_path, work_repo)

    outcome = await _executor(cfg, runner_hub).execute(run)

    assert outcome.status == "done", outcome.result
    assert git(work_repo, "log", "origin/jsai_dev..jsai_dev",
               "--format=%H") == ""


async def test_push_run_reports_running_before_done(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    """🚨 push 成功後 Hub 要停在 ``done``，不是還卡在 ``claimed``。

    Hub 的狀態機只讓 ``done`` 從 ``running`` 來；push 路徑若不先回報
    ``running``，那筆 ``done`` 會被 409 擋掉，而 409 在客戶端是「當成已套用」
    的——推其實成功了，面板上卻永遠停在領走的樣子。
    """
    _app, client = hub_app
    room_id, headers = ops_room
    (work_repo / "a.txt").write_text("a", encoding="utf-8")
    git(work_repo, "add", "a.txt")
    git(work_repo, "commit", "-m", "要推的那顆")
    sha = git(work_repo, "rev-parse", "HEAD")

    run = await _claimed_run(client, room_id, headers, runner_hub,
                             kind="push", ref="JSAI-Web",
                             brief=f"branch: jsai_dev\n{sha}")
    cfg = make_config(tmp_path, work_repo)
    reported: list[str] = []
    real_report = runner_hub.report

    async def spy(run_id, status, **kw):
        reported.append(status)
        return await real_report(run_id, status, **kw)

    runner_hub.report = spy
    outcome = await _executor(cfg, runner_hub).execute(run)

    assert outcome.status == "done", outcome.result
    assert reported == ["running", "done"], reported
    final, trail = await _trail(client, run["id"], headers)
    assert final["status"] == "done"
    assert trail == ["queued", "claimed", "running", "done"]


async def test_push_run_refuses_branch_outside_push_list(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    _app, client = hub_app
    room_id, headers = ops_room
    run = await _claimed_run(client, room_id, headers, runner_hub,
                             kind="push", ref="JSAI-Web",
                             brief="branch: jsai_prod\ndeadbeef")
    cfg = make_config(tmp_path, work_repo)

    outcome = await _executor(cfg, runner_hub).execute(run)

    assert (outcome.status, outcome.reason) == ("failed",
                                                "push_branch_not_allowed")


async def test_push_run_refuses_without_a_sha_list(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    _app, client = hub_app
    room_id, headers = ops_room
    run = await _claimed_run(client, room_id, headers, runner_hub,
                             kind="push", ref="JSAI-Web",
                             brief="branch: jsai_dev")
    cfg = make_config(tmp_path, work_repo)

    outcome = await _executor(cfg, runner_hub).execute(run)

    assert (outcome.status, outcome.reason) == ("failed",
                                                "push_sha_list_missing")


# ── 前置條件 ────────────────────────────────────────────────────

async def test_branch_outside_allow_list_fails_before_spawning(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    """repo 停在不允許的分支時直接 failed，不起 claude。

    執行器**不替人切分支**：那是人類的決定，而它切過去之後沒有人會知道。
    """
    _app, client = hub_app
    room_id, headers = ops_room
    git(work_repo, "checkout", "-b", "master")
    run = await _claimed_run(client, room_id, headers, runner_hub,
                             kind="ticket", ref="task-branch")
    cfg = make_config(tmp_path, work_repo)

    outcome = await _executor(cfg, runner_hub).execute(run)

    assert (outcome.status, outcome.reason) == ("failed",
                                                "branch_not_allowed")
    assert not (cfg.runs_dir / run["id"] / "stream.jsonl").exists()


async def test_unknown_project_fails_without_spawning(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    cfg = make_config(tmp_path, work_repo)
    ex = _executor(cfg, _NullHub())
    outcome = await ex.execute({"id": "r-x", "kind": "ticket",
                                "project": "not-allowed", "ref": "t",
                                "brief": "", "room_id": "room"})
    assert outcome.status == "failed" and outcome.reason == "setup_error"


def test_resolve_repo_rules(tmp_path, work_repo):
    cfg = make_config(tmp_path, work_repo)
    project = cfg.workspace("ai-website")
    base = {"id": "r", "kind": "ticket", "project": "ai-website", "ref": "t",
            "brief": "", "room_id": "room"}
    assert resolve_repo(base, project).name == "JSAI-Web"
    assert resolve_repo({**base, "brief": "repo: JSAI-Web\n其他"},
                        project).name == "JSAI-Web"
    with pytest.raises(Exception):
        resolve_repo({**base, "brief": "repo: JSAI-Nope"}, project)


def test_run_files_carry_the_matcher_and_bridge_pythonpath(tmp_path,
                                                           work_repo):
    """settings 與 mcp.json 的形狀是契約：matcher 少一個工具、PYTHONPATH 指錯，
    兩者都只會在真的跑一個 agent 時才發現。"""
    cfg = make_config(tmp_path, work_repo)
    ex = _executor(cfg, _NullHub())
    run_dir = cfg.runs_dir / "r-files"
    run_dir.mkdir(parents=True)
    ex._write_run_files(run_dir, {"id": "r-files"},
                        cfg.workspace("ai-website").projects["JSAI-Web"])
    settings = json.loads((run_dir / "settings.json").read_text("utf-8"))
    matcher = settings["hooks"]["PreToolUse"][0]["matcher"]
    assert "PowerShell" in matcher and "Bash" in matcher
    assert settings["hooks"]["PreCompact"]
    mcp = json.loads((run_dir / "mcp.json").read_text("utf-8"))
    env = mcp["mcpServers"]["chatroom"]["env"]
    assert env["PYTHONPATH"].endswith("bridge")
    assert env["CHATROOM_SESSION_KEY"] == "claude-run-r-files"
    # 名字留空＝Hub 的名字池發名號。塞 `<label>-<run 短碼>` 的話成員列上
    # 顯示的是一串 id；**鍵本身不能省**，省掉會沿用執行器自己的代稱
    assert env["CHATROOM_DEFAULT_NAME"] == ""
    # 少了它 bridge 會落回 other，房間成員列顯示 OTHER
    assert env["CHATROOM_AGENT_KIND"] == "claude"
    # 🚨 附件要落在 run 目錄，不是 cwd。bridge 預設寫 `./.chatroom/downloads/`，
    # 而那個「.」是被派工的 repo——實測附件就這樣弄髒了人類的工作樹
    downloads = run_dir / "downloads"
    assert env["CHATROOM_DOWNLOAD_DIR"] == str(downloads)
    assert downloads.is_dir(), "目錄要先建起來，bridge 才寫得進去"
    guard = json.loads((run_dir / "guard.json").read_text("utf-8"))
    assert guard["allowed_branches"] == ["jsai_dev", "feature/*"]
    # guard 要認得這個例外，否則「執行器自己的目錄」會把附件一起擋掉
    assert guard["downloads_dir"] == str(downloads)


def test_argv_has_verbose_with_stream_json(tmp_path, work_repo):
    """`--output-format stream-json` 沒配 `--verbose` 會直接 exit 1。"""
    cfg = make_config(tmp_path, work_repo)
    ex = _executor(cfg, _NullHub())
    argv = ex._argv("prompt", "contract", cfg.workspace("ai-website"),
                    tmp_path, "")
    assert "--verbose" in argv
    assert argv[argv.index("--output-format") + 1] == "stream-json"
    assert argv[argv.index("--permission-mode") + 1] == "auto"
    assert "--bare" not in argv, "--bare 只認 API key，本機是 OAuth 登入"
    assert FAKE_CLAUDE in argv[1]
    ws = cfg.workspace("ai-website")
    resumed = ex._argv("p", "c", ws, tmp_path, "sid-1")
    assert resumed[resumed.index("--resume") + 1] == "sid-1"


def _allowed(argv: list[str]) -> list[str]:
    return argv[argv.index("--allowedTools") + 1].split(",")


def test_argv_preauthorizes_tools(tmp_path, work_repo):
    """`--permission-mode auto` 不會自動放行 MCP 工具：實測 run 9ee0fd48 裡
    `mcp__chatroom__chatroom_join` 停在權限提示，headless 沒有人能按允許。"""
    cfg = make_config(tmp_path, work_repo)
    ex = _executor(cfg, _NullHub())
    proj = cfg.workspace("ai-website")

    ticket = _allowed(ex._argv("p", "c", proj, tmp_path, "", "ticket"))
    assert "mcp__chatroom__*" in ticket
    for name in ("ToolSearch", "Read", "Glob", "Grep", "Bash", "PowerShell"):
        assert name in ticket
    for name in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        assert name in ticket, "ticket 要能改檔"

    investigate = _allowed(ex._argv("p", "c", proj, tmp_path, "",
                                    "investigate"))
    assert "mcp__chatroom__*" in investigate
    for name in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        assert name not in investigate, "investigate 是唯讀的"


def test_extra_allowed_tools_merges_in(tmp_path, work_repo):
    """設定檔的 `extra_allowed_tools` 要併進 `--allowedTools`。"""
    cfg = make_config(
        tmp_path, work_repo,
        extra_allowed_tools=["mcp__claude_ai_Atlassian_Rovo__*", "Read"])
    ex = _executor(cfg, _NullHub())
    tools = _allowed(ex._argv("p", "c", cfg.workspace("ai-website"),
                              tmp_path, "", "investigate"))
    assert "mcp__claude_ai_Atlassian_Rovo__*" in tools
    assert tools.count("Read") == 1, "重複的名字不要疊上去"


# ── claude.ai 連接器的封鎖（09/17）─────────────────────────────

# `claude mcp list` 的真實輸出（2026-09-17，執行器的設定目錄）。三種狀態行
# 都要認得——尤其 ✘ 那行後面還跟著一句帶引號的錯誤訊息
MCP_LIST_SAMPLE = """Checking MCP server health…

claude.ai Claude Docs: https://api.anthropic.com/v1/pages/mcp - ✔ Connected
claude.ai Notion: https://mcp.notion.com/mcp - ! Needs authentication
claude.ai Atlassian Rovo: https://mcp.atlassian.com/v1/mcp - ✘ Failed to \
connect — MCP server "claude.ai Atlassian Rovo" connection timed out after \
30000ms
claude.ai Brand New Thing: https://brand-new.example.com/mcp - ✔ Connected
chatroom: C:/python.exe -m chatroom_mcp - ✔ Connected
"""


@pytest.fixture(autouse=True)
def _forget_discovered_servers():
    """`_discovered_servers` 是模組層的，測試之間不能互相汙染。"""
    yield
    run_module._discovered_servers.clear()


def _disallowed(argv: list[str]) -> list[str]:
    return argv[argv.index("--disallowedTools") + 1].split(",")


def test_parse_mcp_list_reads_all_three_status_lines():
    """✔／!／✘ 三種狀態都要撈到；本機 stdio 伺服器也要，只是沒有 URL。"""
    found = dict(run_module.parse_mcp_list(MCP_LIST_SAMPLE))
    assert found["claude.ai Claude Docs"] == \
        "https://api.anthropic.com/v1/pages/mcp"
    assert found["claude.ai Notion"] == "https://mcp.notion.com/mcp"
    # 連不上的那行：錯誤訊息裡也有伺服器名，不能把 URL 或名字吃掉
    assert found["claude.ai Atlassian Rovo"] == \
        "https://mcp.atlassian.com/v1/mcp"
    # 本機 stdio 伺服器：允許清單是預設拒絕，撈不到就沒有規則管得到它
    assert found["chatroom"] == "", "stdio 沒有 URL，deny 要改用 serverName"


def test_argv_denies_every_connector_except_the_allowed_ones(tmp_path,
                                                             work_repo):
    """預設拒絕：chatroom 以外的 claude.ai 連接器全部進 `--disallowedTools`。"""
    cfg = make_config(tmp_path, work_repo)
    ex = _executor(cfg, _NullHub())
    denied = _disallowed(ex._argv("p", "c", cfg.workspace("ai-website"),
                                  tmp_path, "", "ticket"))
    for name in ("mcp__claude_ai_Gmail__*", "mcp__claude_ai_Google_Drive__*",
                 "mcp__claude_ai_Canva__*", "mcp__claude_ai_Notion__*",
                 "mcp__claude_ai_Atlassian_Rovo__*"):
        assert name in denied
    assert "mcp__chatroom__*" not in denied


def test_extra_allowed_tools_keeps_that_server_out_of_the_deny_list(
        tmp_path, work_repo):
    """設定檔放行了 Atlassian 的工具，就不能反手把整台伺服器擋掉——
    一條規則兩端實作不一致只會湊出死局。"""
    cfg = make_config(
        tmp_path, work_repo,
        extra_allowed_tools=["mcp__claude_ai_Atlassian_Rovo__*"])
    ex = _executor(cfg, _NullHub())
    argv = ex._argv("p", "c", cfg.workspace("ai-website"), tmp_path, "",
                    "ticket")
    denied = _disallowed(argv)
    assert "mcp__claude_ai_Atlassian_Rovo__*" not in denied
    assert "mcp__claude_ai_Atlassian_Rovo__*" in _allowed(argv)
    assert "mcp__claude_ai_Gmail__*" in denied


def test_allowed_mcp_servers_opens_exactly_what_it_names(tmp_path, work_repo):
    cfg = make_config(tmp_path, work_repo,
                      allowed_mcp_servers=["chatroom", "claude.ai Gmail"])
    ex = _executor(cfg, _NullHub())
    denied = _disallowed(ex._argv("p", "c", cfg.workspace("ai-website"),
                                  tmp_path, "", "ticket"))
    assert "mcp__claude_ai_Gmail__*" not in denied
    assert "mcp__claude_ai_Canva__*" in denied


def test_selfcheck_probe_adds_newly_seen_connectors(tmp_path, work_repo):
    """保底名單沒有的連接器，自檢探到之後也要被擋。"""
    cfg = make_config(tmp_path, work_repo)
    ex = _executor(cfg, _NullHub())
    before = _disallowed(ex._argv("p", "c", cfg.workspace("ai-website"),
                                  tmp_path, "", "ticket"))
    assert "mcp__claude_ai_Brand_New_Thing__*" not in before
    run_module.remember_mcp_servers(
        run_module.parse_mcp_list(MCP_LIST_SAMPLE))
    after = _disallowed(ex._argv("p", "c", cfg.workspace("ai-website"),
                                 tmp_path, "", "ticket"))
    assert "mcp__claude_ai_Brand_New_Thing__*" in after


# `claude mcp list` 在一台有本機 stdio 伺服器的執行器上看到的樣子
MCP_LIST_WITH_LOCAL = """\
claude.ai Gmail: https://gmailmcp.googleapis.com/mcp/v1 - ✔ Connected
fff: C:/fff.exe serve - ✔ Connected
playwright: npx @playwright/mcp - ✔ Connected
chatroom: C:/python.exe -m chatroom_mcp - ✔ Connected
"""


def test_local_stdio_servers_outside_the_allow_list_are_denied(tmp_path,
                                                               work_repo):
    """本機 stdio 伺服器也吃允許清單。

    🚨 沒有 `--strict-mcp-config`，執行器設定目錄註冊的 stdio 伺服器照樣
    會載入。只擋連接器的話，App 上那份允許清單對它們等於沒有規則。
    """
    cfg = make_config(tmp_path, work_repo)
    ex = _executor(cfg, _NullHub())
    run_module.remember_mcp_servers(
        run_module.parse_mcp_list(MCP_LIST_WITH_LOCAL))
    denied = _disallowed(ex._argv("p", "c", cfg.workspace("ai-website"),
                                  tmp_path, "", "ticket"))
    assert "mcp__fff__*" in denied
    assert "mcp__playwright__*" in denied
    # chatroom 在預設允許清單裡，不能被自己擋掉——擋掉就連不上聊天室
    assert "mcp__chatroom__*" not in denied


def test_allowed_local_server_stays_out_of_both_deny_layers(tmp_path,
                                                            work_repo):
    """允許清單點名的本機伺服器，兩層 deny 都不能有它。"""
    cfg = make_config(tmp_path, work_repo,
                      allowed_mcp_servers=["chatroom", "fff"])
    ex = _executor(cfg, _NullHub())
    run_module.remember_mcp_servers(
        run_module.parse_mcp_list(MCP_LIST_WITH_LOCAL))
    run_dir = cfg.runs_dir / "r-local"
    run_dir.mkdir(parents=True)
    ex._write_run_files(run_dir, {"id": "r-local"},
                        cfg.workspace("ai-website").projects["JSAI-Web"])
    settings = json.loads((run_dir / "settings.json").read_text("utf-8"))
    names = [e.get("serverName") for e in settings["deniedMcpServers"]]
    assert "fff" not in names
    assert "chatroom" not in names
    # 沒有 URL 的本機伺服器只能靠 serverName
    assert "playwright" in names
    assert "mcp__fff__*" not in settings["permissions"]["deny"]
    assert "mcp__playwright__*" in settings["permissions"]["deny"]


def test_run_settings_deny_the_connectors_at_both_layers(tmp_path, work_repo):
    """雙保險：`deniedMcpServers` 讓伺服器不載入，`permissions.deny` 是
    萬一它們仍然到齊時的第二道。"""
    cfg = make_config(tmp_path, work_repo)
    ex = _executor(cfg, _NullHub())
    run_dir = cfg.runs_dir / "r-deny"
    run_dir.mkdir(parents=True)
    ex._write_run_files(run_dir, {"id": "r-deny"},
                        cfg.workspace("ai-website").projects["JSAI-Web"])
    settings = json.loads((run_dir / "settings.json").read_text("utf-8"))
    # 有 URL 就用 serverUrl：文件說連接器的顯示名會改，serverName 會失效
    urls = [e["serverUrl"] for e in settings["deniedMcpServers"]
            if "serverUrl" in e]
    assert "https://gmailmcp.googleapis.com/mcp/v1" in urls
    assert "https://mcp.canva.com/mcp" in urls
    assert not [u for u in urls if "chatroom" in u]
    assert "mcp__claude_ai_Gmail__*" in settings["permissions"]["deny"]
    assert "mcp__chatroom__*" not in settings["permissions"]["deny"]


# ── 全域 .claude.json 的 MCP 伺服器 ─────────────────────────────

def _fake_global_config(tmp_path, monkeypatch, servers: dict | None,
                        broken: bool = False):
    """假的使用者全域 `.claude.json`。servers 是 None ＝檔案根本不存在。"""
    path = tmp_path / "home" / ".claude.json"
    if servers is not None or broken:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("{壞掉" if broken else json.dumps(
            {"mcpServers": servers}, ensure_ascii=False), encoding="utf-8")
    monkeypatch.setattr(run_module, "global_config_path", lambda: path)
    return path


GLOBAL_SERVERS = {
    "fff": {"command": "C:/fff.exe", "args": ["serve"],
            "env": {"FFF_TOKEN": "$KEEP_ME"}},
    "mempal": {"command": "C:/py.exe", "args": ["-m", "mempal"]},
}


def _write_files(cfg, run_id):
    ex = _executor(cfg, _NullHub())
    run_dir = cfg.runs_dir / run_id
    run_dir.mkdir(parents=True)
    ex._write_run_files(run_dir, {"id": run_id},
                        cfg.workspace("ai-website").projects["JSAI-Web"])
    return run_dir


def test_allowed_global_server_lands_in_run_mcp_json(tmp_path, work_repo,
                                                     monkeypatch):
    """勾了全域的 fff，run 的 mcp.json 就要有它原樣的定義。

    🚨 run 用的是執行器自己的設定目錄，那裡沒有這些伺服器；不複製定義
    進來的話，畫面上勾了也只是放行一台根本不會被載入的伺服器。
    """
    _fake_global_config(tmp_path, monkeypatch, GLOBAL_SERVERS)
    cfg = make_config(tmp_path, work_repo,
                      allowed_mcp_servers=["chatroom", "fff"])
    mcp = json.loads((_write_files(cfg, "r-global") / "mcp.json")
                     .read_text("utf-8"))
    assert mcp["mcpServers"]["fff"] == GLOBAL_SERVERS["fff"]
    # env 原樣帶，不做展開——那是人類自己寫的值
    assert mcp["mcpServers"]["fff"]["env"]["FFF_TOKEN"] == "$KEEP_ME"
    # 沒勾的不帶
    assert "mempal" not in mcp["mcpServers"]
    # chatroom 仍然是執行器自己那一份
    assert mcp["mcpServers"]["chatroom"]["env"]["CHATROOM_URL"]


def test_global_server_outside_the_allow_list_is_denied(tmp_path, work_repo,
                                                        monkeypatch):
    """沒勾的全域伺服器要進 deny：run 不帶 --strict-mcp-config，claude 仍然
    會自己載入它設定目錄的伺服器，允許清單必須管得到每一個名字。"""
    _fake_global_config(tmp_path, monkeypatch, GLOBAL_SERVERS)
    cfg = make_config(tmp_path, work_repo,
                      allowed_mcp_servers=["chatroom", "fff"])
    settings = json.loads((_write_files(cfg, "r-global-deny") /
                           "settings.json").read_text("utf-8"))
    names = [e.get("serverName") for e in settings["deniedMcpServers"]]
    assert "mempal" in names
    assert "fff" not in names
    assert "mcp__mempal__*" in settings["permissions"]["deny"]
    assert "mcp__fff__*" not in settings["permissions"]["deny"]


def test_chatroom_is_never_taken_from_the_global_file(tmp_path, work_repo,
                                                      monkeypatch):
    """全域也有一台叫 chatroom 也不能蓋掉執行器自己的那一份。"""
    _fake_global_config(tmp_path, monkeypatch,
                        {"chatroom": {"command": "別人的", "args": []}})
    cfg = make_config(tmp_path, work_repo)
    mcp = json.loads((_write_files(cfg, "r-global-chatroom") / "mcp.json")
                     .read_text("utf-8"))
    assert mcp["mcpServers"]["chatroom"]["args"] == ["-m", "chatroom_mcp"]


@pytest.mark.parametrize("broken", [False, True])
def test_missing_or_broken_global_file_does_not_block_the_run(
        tmp_path, work_repo, monkeypatch, broken):
    """全域檔不存在或壞掉：略過就好，run 照起。"""
    _fake_global_config(tmp_path, monkeypatch, None, broken=broken)
    cfg = make_config(tmp_path, work_repo,
                      allowed_mcp_servers=["chatroom", "fff"])
    mcp = json.loads((_write_files(cfg, f"r-global-{broken}") / "mcp.json")
                     .read_text("utf-8"))
    assert list(mcp["mcpServers"]) == ["chatroom"]


# ── 回報的容錯（審查 09/16 Major）───────────────────────────────

class _FlakyHub:
    """前 ``failures`` 次 report 丟 HubError，之後成功。"""

    def __init__(self, failures: int) -> None:
        self.failures = failures
        self.calls: list[tuple] = []

    async def report(self, run_id, status, **kw):
        from chatroom_runner.hub import HubError
        self.calls.append((run_id, status))
        if len(self.calls) <= self.failures:
            raise HubError("連不上", code="unreachable")
        return None


async def test_report_retries_before_giving_up(tmp_path, work_repo):
    """Hub 抖一下不該讓一筆做完的 run 變成永遠 running。"""
    from chatroom_runner.run import RunOutcome

    cfg = make_config(tmp_path, work_repo)
    hub = _FlakyHub(failures=2)
    slept: list[float] = []

    async def fake_sleep(seconds):
        slept.append(seconds)

    ex = _executor(cfg, hub, sleep=fake_sleep)
    ok = await ex._report("r-flaky", RunOutcome("done", reason="success",
                                                result="做完了"))

    assert ok is True
    assert len(hub.calls) == 3, "沒有重試"
    assert slept == [2, 5], "退避沒有拉開"
    assert not (cfg.runs_dir / "r-flaky" / "report_failed.json").exists()


async def test_report_that_never_lands_is_written_to_disk(tmp_path,
                                                          work_repo, caplog):
    """🚨 三次都失敗就把回報**落地**。

    不落地的話，那筆 run 的結果只存在於一個已經結束的 process 的記憶體裡：
    房裡永遠停在 running，而本機一行紀錄都沒有。
    """
    import logging

    from chatroom_runner.run import RunOutcome

    cfg = make_config(tmp_path, work_repo)
    hub = _FlakyHub(failures=99)
    slept: list[float] = []

    async def fake_sleep(seconds):
        slept.append(seconds)

    ex = _executor(cfg, hub, sleep=fake_sleep)
    with caplog.at_level(logging.WARNING, logger="chatroom_runner.run"):
        ok = await ex._report("r-dead", RunOutcome("failed", reason="boom",
                                                   result="掛了"))

    assert ok is False
    assert len(hub.calls) == 3
    landed = cfg.runs_dir / "r-dead" / "report_failed.json"
    assert landed.exists(), "回報沒有落地"
    saved = json.loads(landed.read_text(encoding="utf-8"))
    assert saved["status"] == "failed" and saved["reason"] == "boom"
    assert saved["run_id"] == "r-dead"
    assert caplog.records, "log 裡沒有任何痕跡"


# ── push 前先 fetch（審查 09/16 Major）───────────────────────────

async def test_push_fetches_before_comparing(hub_app, ops_room, runner_hub,
                                             work_repo, tmp_path,
                                             monkeypatch):
    """🚨 不 fetch 就比對，比的是上次 fetch 時的遠端位置。

    別人在這期間推了東西，`origin/<b>..<b>` 會多算幾顆，而那份清單同時是
    「按鈕的人看到什麼」的依據。
    """
    from chatroom_runner import run as run_mod

    _app, client = hub_app
    room_id, headers = ops_room
    (work_repo / "a.txt").write_text("a", encoding="utf-8")
    git(work_repo, "add", "a.txt")
    git(work_repo, "commit", "-m", "要推的那顆")
    sha = git(work_repo, "rev-parse", "HEAD")
    run = await _claimed_run(client, room_id, headers, runner_hub,
                             kind="push", ref="JSAI-Web",
                             brief=f"branch: jsai_dev\n{sha}")
    cfg = make_config(tmp_path, work_repo)
    calls: list[tuple] = []
    real = run_mod.gitops.git

    async def spy(repo, *args, **kw):
        calls.append((args, kw))
        return await real(repo, *args, **kw)

    monkeypatch.setattr(run_mod.gitops, "git", spy)
    outcome = await _executor(cfg, runner_hub).execute(run)

    assert outcome.status == "done", outcome.result
    kinds = [a for a, _kw in calls]
    fetches = [a for a in kinds if a and a[-3:] == ("fetch", "origin",
                                                    "jsai_dev")]
    assert fetches, f"push 前沒有 fetch：{kinds}"
    pushes = [a for a in kinds if "push" in a]
    assert pushes, "沒有推"
    assert kinds.index(fetches[0]) < kinds.index(pushes[0])


async def test_push_refuses_when_fetch_fails(hub_app, ops_room, runner_hub,
                                             work_repo, tmp_path):
    """fetch 失敗＝不知道遠端現在長什麼樣子。這時推上去是盲推。"""
    _app, client = hub_app
    room_id, headers = ops_room
    (work_repo / "a.txt").write_text("a", encoding="utf-8")
    git(work_repo, "add", "a.txt")
    git(work_repo, "commit", "-m", "要推的那顆")
    sha = git(work_repo, "rev-parse", "HEAD")
    git(work_repo, "remote", "set-url", "origin", str(tmp_path / "gone.git"))
    run = await _claimed_run(client, room_id, headers, runner_hub,
                             kind="push", ref="JSAI-Web",
                             brief=f"branch: jsai_dev\n{sha}")
    cfg = make_config(tmp_path, work_repo)

    outcome = await _executor(cfg, runner_hub).execute(run)

    assert (outcome.status, outcome.reason) == ("failed", "push_fetch_failed")


# ── 推送憑證隔離（艾斯維爾裁決 09/16）───────────────────────────

async def test_push_run_carries_the_push_credential_helper(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, monkeypatch):
    """push run 是唯一帶憑證的路徑，helper 由執行器**明確指定**。"""
    from chatroom_runner import run as run_mod

    _app, client = hub_app
    room_id, headers = ops_room
    (work_repo / "a.txt").write_text("a", encoding="utf-8")
    git(work_repo, "add", "a.txt")
    git(work_repo, "commit", "-m", "要推的那顆")
    sha = git(work_repo, "rev-parse", "HEAD")
    run = await _claimed_run(client, room_id, headers, runner_hub,
                             kind="push", ref="JSAI-Web",
                             brief=f"branch: jsai_dev\n{sha}")
    cfg = make_config(tmp_path, work_repo)
    calls: list[tuple] = []
    real = run_mod.gitops.git

    async def spy(repo, *args, **kw):
        calls.append((args, kw))
        return await real(repo, *args, **kw)

    monkeypatch.setattr(run_mod.gitops, "git", spy)
    await _executor(cfg, runner_hub).execute(run)

    helper = ("-c", f"credential.helper={run_mod.PUSH_CREDENTIAL_HELPER}")
    for verb in ("fetch", "push"):
        hit = [a for a, _kw in calls if verb in a]
        assert hit, f"沒有 {verb}"
        assert hit[0][:2] == helper, f"{verb} 沒帶憑證 helper：{hit[0]}"
    # push 的 git 呼叫**不帶**一般 run 的憑證覆寫環境
    assert all("env" not in kw for _a, kw in calls)


def test_child_env_strips_git_credentials(tmp_path, work_repo):
    """一般 run 的進程拿不到推送憑證：清掉 helper 清單、關掉互動與 askpass。"""
    from chatroom_runner import run as run_mod

    cfg = make_config(tmp_path, work_repo)
    ex = _executor(cfg, _NullHub())
    env = ex._child_env({"id": "r-env"}, tmp_path)

    assert env["GIT_CONFIG_COUNT"] == "1"
    assert env["GIT_CONFIG_KEY_0"] == "credential.helper"
    assert env["GIT_CONFIG_VALUE_0"] == ""
    assert env["GIT_TERMINAL_PROMPT"] == "0"
    assert Path(env["GIT_ASKPASS"]).is_file()
    assert env["GIT_ASKPASS"] == str(run_mod.ASKPASS_SCRIPT)


def test_child_env_does_not_hand_the_run_a_name(tmp_path, work_repo, monkeypatch):
    """run 的名字由 Hub 的名字池發，執行器不塞。

    🚨 要**明寫空字串**：`env = dict(os.environ)` 會把執行器自己的
    CHATROOM_DEFAULT_NAME 一路帶進去，run 就頂著執行器的代稱進房；bridge
    載 `.env` 時也只補「不在 env 裡」的鍵，空字串擋得住那一路。
    """
    monkeypatch.setenv("CHATROOM_DEFAULT_NAME", "Minka")
    cfg = make_config(tmp_path, work_repo)
    ex = _executor(cfg, _NullHub())
    env = ex._child_env({"id": "r-env"}, tmp_path)

    assert env["CHATROOM_DEFAULT_NAME"] == ""
    assert env["CHATROOM_SESSION_KEY"] == "claude-run-r-env"


def test_credential_override_really_denies_credentials(tmp_path, work_repo):
    """不是只看環境變數有沒有設：真的跑一次 `git credential fill`。

    ⚠️ `git config --get-all credential.helper` **驗不到這件事**：它印的是
    設定檔裡的原始值（會看到 `manager` 加一個空項），清空 helper 清單是
    credential 那一層的行為。要驗就要驗那一層。
    """
    cfg = make_config(tmp_path, work_repo)
    ex = _executor(cfg, _NullHub())
    env = ex._child_env({"id": "r-env"}, tmp_path)
    query = "\n".join(["protocol=https", "host=github.com", "", ""])
    out = subprocess.run(["git", "credential", "fill"], input=query,
                         cwd=str(work_repo), env=env, capture_output=True,
                         text=True, timeout=60)
    assert out.returncode != 0, "run 的環境還拿得到憑證"
    assert "username" not in out.stdout.lower()
    assert "password" not in out.stdout.lower()
    # 而且不是卡在問句上：終端提示關掉、askpass 一律失敗
    assert "terminal prompts disabled" in out.stderr.lower()


async def test_child_process_sees_the_isolated_git_env(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, monkeypatch):
    """環境變數要真的到得了子進程——這是憑證隔離唯一的執行點。"""
    _app, client = hub_app
    room_id, headers = ops_room
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "env_dump")
    run = await _claimed_run(client, room_id, headers, runner_hub,
                             kind="ticket", ref="task-env")
    cfg = make_config(tmp_path, work_repo)

    outcome = await _executor(cfg, runner_hub).execute(run)

    assert outcome.status == "done", outcome.result
    seen = json.loads((cfg.runs_dir / run["id"] / "env.json")
                      .read_text(encoding="utf-8"))
    assert seen["GIT_CONFIG_COUNT"] == "1"
    assert seen["GIT_CONFIG_KEY_0"] == "credential.helper"
    assert seen["GIT_CONFIG_VALUE_0"] == ""
    assert seen["GIT_TERMINAL_PROMPT"] == "0"


# ── stream 的單行上限（2026-09-17 事故）────────────────────────

async def test_a_huge_stream_line_does_not_kill_the_pump(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, monkeypatch):
    """🚨 一行 300 KB 的 tool_result 不能把執行任務帶走。

    實測：模型 `Read` 一張 141 KB 的 PNG，那一行 base64 超過 asyncio
    StreamReader 預設的 64 KiB，`readline()` 丟
    `ValueError: Separator is not found, and chunk exceed the limit`；
    pump 炸掉、執行任務跟著死，claude 進程沒了而 Hub 上那筆 run 永遠停在
    running。這條測試盯的是「那一行進得來，而且後面的事件照樣被解析」。
    """
    _app, client = hub_app
    room_id, headers = ops_room
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "big_line")
    run = await _claimed_run(client, room_id, headers, runner_hub,
                             kind="ticket", ref="task-bigline")
    cfg = make_config(tmp_path, work_repo)
    ex = _executor(cfg, runner_hub)

    outcome = await ex.execute(run)

    assert ex.pump_error == "", f"pump 掛了：{ex.pump_error}"
    assert outcome.status == "done"
    final, _ = await _trail(client, run["id"], headers)
    assert final["status"] == "done"
    # 大行之後的事件要照樣被看到——只吞掉例外而停止讀取也算失敗
    assert "附件讀得進來" in final["result"]
    lines = (cfg.runs_dir / run["id"] / "stream.jsonl").read_text(
        "utf-8").splitlines()
    assert max(len(ln) for ln in lines) > 200_000


# ── 執行任務的安全網（2026-09-17 事故）──────────────────────────

async def test_an_unexpected_exception_still_reports_and_kills_the_child(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, monkeypatch):
    """🚨 執行任務丟出未預期的例外時，run 一定要收場、進程一定要死。

    事故當時 pump 的 `ValueError` 把整個任務帶走：`_finish` 把它從 active
    移掉、log 有一行堆疊，但 Hub 上那筆 run 停在 running，人類按取消也沒有
    人處理——因為已經沒有人在處理它了。
    """
    _app, client = hub_app
    room_id, headers = ops_room
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "long")
    monkeypatch.setenv("FAKE_CLAUDE_SLEEP", "60")
    run = await _claimed_run(client, room_id, headers, runner_hub,
                             kind="ticket", ref="task-boom")
    cfg = make_config(tmp_path, work_repo)
    ex = _executor(cfg, runner_hub)

    async def boom(self_proc, watcher, run_dir):
        raise ValueError("Separator is not found, and chunk exceed the limit")

    monkeypatch.setattr(RunExecutor, "_pump",
                        lambda self, proc, watcher, run_dir: boom(
                            proc, watcher, run_dir))
    killed: list[int] = []
    real_kill = run_module.kill_tree
    monkeypatch.setattr(run_module, "kill_tree",
                        lambda pid: (killed.append(pid), real_kill(pid))[1])

    outcome = await asyncio.wait_for(ex.execute(run), timeout=120)

    assert outcome.status == "failed"
    assert outcome.reason.startswith("runner_error: ValueError"), outcome.reason
    final, _ = await _trail(client, run["id"], headers)
    assert final["status"] == "failed", "Hub 上不能留一筆沒有人在跑的 running"
    assert killed, "子進程沒被殺：它會一直跑到牆鐘上限，而沒有人在看它"


# ── 派工前同步工作樹（諾薇亞 09/18）────────────────────────────

def _remote_commit(tmp_path, work_repo, name: str = "遠端那顆") -> str:
    """從另一份 clone 推一顆上去，模擬「別人先動了」。"""
    other = tmp_path / "other-clone"
    origin = git(work_repo, "remote", "get-url", "origin")
    subprocess.run(["git", "clone", "-b", "jsai_dev", origin, str(other)],
                   capture_output=True, check=True)
    (other / "remote.txt").write_text(name, encoding="utf-8")
    git(other, "add", "remote.txt")
    git(other, "commit", "-m", name)
    git(other, "push", "origin", "jsai_dev")
    return git(other, "rev-parse", "HEAD")


async def test_clean_worktree_fetches_and_fast_forwards(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, monkeypatch):
    """🚨 常駐工作樹跨 run 共用，不先拉就是在上一輪的舊基礎上動工。"""
    from chatroom_runner import run as run_mod

    _app, client = hub_app
    room_id, headers = ops_room
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "success")
    remote_head = _remote_commit(tmp_path, work_repo)
    run = await _claimed_run(client, room_id, headers, runner_hub,
                             kind="ticket", ref="task-sync")
    cfg = make_config(tmp_path, work_repo)
    calls: list[tuple] = []
    real = run_mod.gitops.git

    async def spy(repo, *args, **kw):
        calls.append(args)
        return await real(repo, *args, **kw)

    monkeypatch.setattr(run_mod.gitops, "git", spy)
    outcome = await _executor(cfg, runner_hub).execute(run)

    assert outcome.status == "done", outcome.result
    assert ("fetch",) in calls, f"沒有 fetch：{calls}"
    assert ("pull", "--ff-only") in calls, f"沒有 pull：{calls}"
    assert git(work_repo, "rev-parse", "HEAD") == remote_head, \
        "工作樹沒有真的被快轉到遠端的位置"
    final, _ = await _trail(client, run["id"], headers)
    assert "已快轉 1 個 commit" in final["result"]


async def test_dirty_worktree_skips_pull_and_says_so(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, monkeypatch):
    """髒工作樹**不 pull**：未提交的東西比「最新」重要，但摘要要講。"""
    from chatroom_runner import run as run_mod

    _app, client = hub_app
    room_id, headers = ops_room
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "success")
    _remote_commit(tmp_path, work_repo)
    (work_repo / "wip.txt").write_text("做到一半", encoding="utf-8")
    before_head = git(work_repo, "rev-parse", "HEAD")
    run = await _claimed_run(client, room_id, headers, runner_hub,
                             kind="ticket", ref="task-dirty")
    cfg = make_config(tmp_path, work_repo)
    calls: list[tuple] = []
    real = run_mod.gitops.git

    async def spy(repo, *args, **kw):
        calls.append(args)
        return await real(repo, *args, **kw)

    monkeypatch.setattr(run_mod.gitops, "git", spy)
    outcome = await _executor(cfg, runner_hub).execute(run)

    assert outcome.status == "done", outcome.result
    assert ("pull", "--ff-only") not in calls, "髒工作樹不該 pull"
    assert git(work_repo, "rev-parse", "HEAD") == before_head
    final, _ = await _trail(client, run["id"], headers)
    assert "工作樹有未提交變更，未同步遠端。" in final["result"]


async def test_diverged_branch_fails_before_spawning(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, monkeypatch):
    """不能快轉＝分支已分岔。往下跑等於在錯的基礎上做事。"""
    _app, client = hub_app
    room_id, headers = ops_room
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "success")
    _remote_commit(tmp_path, work_repo)
    (work_repo / "local.txt").write_text("本機那顆", encoding="utf-8")
    git(work_repo, "add", "local.txt")
    git(work_repo, "commit", "-m", "本機那顆")
    local_head = git(work_repo, "rev-parse", "HEAD")
    run = await _claimed_run(client, room_id, headers, runner_hub,
                             kind="ticket", ref="task-diverged")
    cfg = make_config(tmp_path, work_repo)

    outcome = await _executor(cfg, runner_hub).execute(run)

    assert (outcome.status, outcome.reason) == ("failed",
                                                "sync_not_fast_forward")
    assert "無法快轉" in outcome.result
    assert git(work_repo, "rev-parse", "HEAD") == local_head, \
        "擋下的這一輪不該動到工作樹"
    final, _ = await _trail(client, run["id"], headers)
    assert final["status"] == "failed"


# ── 執行器附註的排版（App 端用 GFM 算繪）─────────────────────────

def _note(tmp_path, state, before, after, sync_note=""):
    """單 repo 的附註（多 repo 走 `_multi_note`）。"""
    executor = RunExecutor.__new__(RunExecutor)
    return executor._compose_result(state, tmp_path, {"JSAI-Web": before},
                                    {"JSAI-Web": after},
                                    {"JSAI-Web": sync_note})


def _multi_note(tmp_path, state, before: dict, after: dict, sync=None):
    executor = RunExecutor.__new__(RunExecutor)
    return executor._compose_result(state, tmp_path, before, after, sync)


def test_runner_note_is_markdown_bullets(tmp_path):
    """附註要是條列。純文字逐行在 GFM 底下會黏成一條讀不出欄位的長句。"""
    from chatroom_runner.gitops import RepoSnapshot
    from chatroom_runner.stream import StreamState

    state = StreamState(result_text="做完了。", num_turns=7,
                        total_cost_usd=1.5, peak_context_tokens=123456)
    before = RepoSnapshot(branch="feature/x", head="a" * 40, dirty=[])
    after = RepoSnapshot(branch="feature/x", head="b" * 40,
                         dirty=["M runner/a.py", "M runner/b.py"])
    (tmp_path / "tool.log").write_text("1\n2\n3\n", encoding="utf-8")

    note = _note(tmp_path, state, before, after)

    assert "\n\n- turns：7" in note, "標題與條列之間要有空行"
    assert "- 成本：$1.5000" in note
    assert "- context 峰值：123456 tokens" in note
    assert "- HEAD：aaaaaaaa → bbbbbbbb，有新 commit" in note
    assert "- 未 commit 的變更（2 個檔案）：" in note
    assert "\n    - M runner/a.py\n    - M runner/b.py" in note
    assert "- 工具呼叫 3 次，完整紀錄：`" in note
    for line in note.splitlines():
        assert not line.startswith("turns："), "欄位不能是裸行"


def test_runner_note_keeps_a_single_dirty_file_inline(tmp_path):
    from chatroom_runner.gitops import RepoSnapshot
    from chatroom_runner.stream import StreamState

    before = RepoSnapshot(branch="b", head="a" * 40, dirty=[])
    after = RepoSnapshot(branch="b", head="a" * 40, dirty=["M only.py"])
    note = _note(tmp_path, StreamState(), before, after)
    assert "- 未 commit 的變更：M only.py" in note


def test_runner_note_reports_mcp_servers_that_were_not_ready(tmp_path):
    """開場沒連上的連接器要進附註，否則只看得到 agent 說『不可用』。"""
    from chatroom_runner.gitops import RepoSnapshot
    from chatroom_runner.stream import StreamState

    state = StreamState(pending_mcp_servers=["claude_ai_Atlassian_Rovo"])
    snap = RepoSnapshot(branch="b", head="a" * 40, dirty=[])
    note = _note(tmp_path, state, snap, snap)
    assert "- 開場時未就緒的 MCP：claude_ai_Atlassian_Rovo" in note


# ── 多 repo 專案：一次派工可以動全部 ─────────────────────────────

def _extra_repo(tmp_path, name: str, branch: str = "jsai_dev") -> Path:
    """再開一個掛著 origin 的工作樹（`work_repo` 的兄弟）。"""
    bare = tmp_path / f"{name}-origin.git"
    bare.mkdir()
    subprocess.run(["git", "init", "--bare", "-b", branch, str(bare)],
                   capture_output=True, check=True)
    repo = tmp_path / name
    repo.mkdir()
    git(repo, "init", "-b", branch)
    git(repo, "remote", "add", "origin", str(bare))
    (repo / "README.md").write_text(f"{name}\n", encoding="utf-8")
    git(repo, "add", "README.md")
    git(repo, "commit", "-m", "init")
    git(repo, "push", "-u", "origin", branch)
    return repo


def _multi_config(tmp_path, web: Path, api: Path, **overrides):
    workspaces = {
        "ai-website": {
            "default_project": "JSAI-Web",
            "wall_clock_seconds": 60,
            "projects": {
                "JSAI-Web": {"path": str(web),
                             "allowed_branches": ["jsai_dev", "feature/*"],
                             "push_branches": ["jsai_dev"]},
                "JSAI-API": {"path": str(api),
                             "allowed_branches": ["jsai_dev", "feature/*"],
                             "push_branches": ["jsai_dev"]},
            },
        },
    }
    return make_config(tmp_path, web, workspaces=workspaces, **overrides)


async def test_every_repo_of_the_project_is_synced_and_snapshotted(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, monkeypatch):
    """🚨 一次派工可以動專案底下每一個 repo：只同步主 repo 的話，第二個 repo
    會在舊基礎上被改，而沒有任何地方會說它動過。"""
    from chatroom_runner import run as run_mod

    _app, client = hub_app
    room_id, headers = ops_room
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "success")
    api = _extra_repo(tmp_path, "JSAI-API")
    run = await _claimed_run(client, room_id, headers, runner_hub,
                             kind="ticket", ref="task-multi")
    cfg = _multi_config(tmp_path, work_repo, api)
    calls: list[tuple] = []
    real = run_mod.gitops.git

    async def spy(repo, *args, **kw):
        calls.append((Path(repo).name, args))
        return await real(repo, *args, **kw)

    monkeypatch.setattr(run_mod.gitops, "git", spy)
    outcome = await _executor(cfg, runner_hub).execute(run)

    assert outcome.status == "done", outcome.result
    for name in ("JSAI-Web", "JSAI-API"):
        assert (name, ("fetch",)) in calls, f"{name} 沒有 fetch：{calls}"
        assert (name, ("pull", "--ff-only")) in calls, f"{name} 沒有 pull"
        assert (name, ("rev-parse", "HEAD")) in calls, f"{name} 沒有快照"


async def test_a_second_repo_on_a_forbidden_branch_stops_the_run(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, monkeypatch):
    """分支檢查要對每個 repo 做：第二個 repo 停在不允許的分支上時，
    這一輪本來就不該開始——agent 會去改它。"""
    _app, client = hub_app
    room_id, headers = ops_room
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "success")
    api = _extra_repo(tmp_path, "JSAI-API")
    git(api, "checkout", "-b", "master")
    run = await _claimed_run(client, room_id, headers, runner_hub,
                             kind="ticket", ref="task-branch")
    cfg = _multi_config(tmp_path, work_repo, api)

    outcome = await _executor(cfg, runner_hub).execute(run)

    assert (outcome.status, outcome.reason) == ("failed",
                                                "branch_not_allowed")
    assert "JSAI-API" in outcome.result and "master" in outcome.result


def test_runner_note_has_a_section_per_touched_repo(tmp_path):
    """多 repo 的附註分節。混成一段的話，看報告的人分不出那顆 commit 在哪。"""
    from chatroom_runner.gitops import RepoSnapshot
    from chatroom_runner.stream import StreamState

    before = {"JSAI-Web": RepoSnapshot("jsai_dev", "a" * 40, []),
              "JSAI-API": RepoSnapshot("jsai_dev", "c" * 40, []),
              "JSAI-Functions": RepoSnapshot("jsai_dev", "e" * 40, [])}
    after = {"JSAI-Web": RepoSnapshot("jsai_dev", "b" * 40, []),
             "JSAI-API": RepoSnapshot("jsai_dev", "c" * 40,
                                      ["M src/api.ts"]),
             "JSAI-Functions": RepoSnapshot("jsai_dev", "e" * 40, [])}
    note = _multi_note(tmp_path, StreamState(result_text="做完了。"),
                       before, after,
                       {"JSAI-API": "已是最新"})

    assert "- JSAI-Web\n    - HEAD：aaaaaaaa → bbbbbbbb，有新 commit" in note
    assert "- JSAI-API\n    - HEAD：cccccccc → cccccccc" in note
    assert "    - 未 commit 的變更：M src/api.ts" in note
    # 沒動過的 repo 不佔版面
    assert "JSAI-Functions" not in note
    # 同步結果要標明是哪個 repo 的
    assert "- 工作樹同步（JSAI-API）：已是最新" in note


def test_runner_note_lists_the_primary_repo_when_nothing_moved(tmp_path):
    """全都沒動就只列主 repo——空白一片會被讀成「附註漏了」。"""
    from chatroom_runner.gitops import RepoSnapshot
    from chatroom_runner.stream import StreamState

    snap = {"JSAI-Web": RepoSnapshot("jsai_dev", "a" * 40, []),
            "JSAI-API": RepoSnapshot("jsai_dev", "c" * 40, [])}
    note = _multi_note(tmp_path, StreamState(), snap, dict(snap))

    assert "- JSAI-Web\n    - HEAD：aaaaaaaa → aaaaaaaa" in note
    assert "JSAI-API\n" not in note


def test_prompt_lists_every_repo_of_the_project():
    """prompt 只列一個 repo 的話，agent 會把另一半寫進卡裡說「我只能動這個」。"""
    from chatroom_runner import prompts

    block = prompts.repos_block([
        {"name": "JSAI-Web", "path": "C:/x/JSAI-Web", "branch": "jsai_dev",
         "allowed_branches": ["jsai_dev", "feature/*"], "primary": True},
        {"name": "JSAI-API", "path": "C:/x/JSAI-API", "branch": "jsai_dev",
         "allowed_branches": ["jsai_dev"], "primary": False},
    ])
    fields = {"run_id": "r1", "room_id": "room", "kind": "ticket",
              "project": "ai-website", "ref": "task-1", "repo": "JSAI-Web",
              "cwd": "C:/x/JSAI-Web", "branch": "jsai_dev",
              "allowed_branches": "jsai_dev、feature/*",
              "repos_block": block, "repo_names": "JSAI-Web、JSAI-API"}
    for kind in ("ticket", "stage", "investigate"):
        text = prompts.build(kind, fields, "簡述在這")
        assert "{{" not in text
        assert "JSAI-API" in text and "C:/x/JSAI-API" in text
        assert "（主工作目錄）" in text
    contract = prompts.build_contract(fields)
    assert "{{" not in contract and "JSAI-API" in contract


async def test_a_shared_second_repo_serialises_two_runs(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, monkeypatch):
    """🚨 寫入型 run 會動專案底下每一個 repo，所以鎖要拿全部。

    只鎖主 repo 的話，兩筆主 repo 不同的 run 會同時寫同一個副 repo——
    那正是「同一個 repo 只允許一個寫入者」本來要擋掉的事，而面板上看起來
    只是兩筆都在跑。
    """
    _app, client = hub_app
    room_id, headers = ops_room
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "long")
    monkeypatch.setenv("FAKE_CLAUDE_SLEEP", "60")
    api = _extra_repo(tmp_path, "JSAI-API")
    await runner_hub.register("test-host", "test", ["ai-website"], 2, "0.1")
    await create_run(client, room_id, headers, kind="ticket",
                     ref="task-web", brief="repo: JSAI-Web")
    await create_run(client, room_id, headers, kind="ticket",
                     ref="task-api", brief="repo: JSAI-API")
    a = await runner_hub.claim()
    b = await runner_hub.claim()
    cfg = _multi_config(tmp_path, work_repo, api)
    locks = RepoLocks()
    cancel_a, cancel_b = asyncio.Event(), asyncio.Event()
    task_a = asyncio.ensure_future(
        _executor(cfg, runner_hub, locks=locks).execute(a, cancel_a))
    task_b = asyncio.ensure_future(
        _executor(cfg, runner_hub, locks=locks).execute(b, cancel_b))
    try:
        started: list[dict] = []
        for _ in range(600):
            await asyncio.sleep(0.05)
            started = [r for r in (a, b)
                       if (cfg.runs_dir / r["id"] / "stream.jsonl").exists()]
            if started:
                break
        # 兩把鎖都在同一筆手上
        assert locks.is_held("ai-website/JSAI-Web")
        assert locks.is_held("ai-website/JSAI-API")
        started = [r for r in (a, b)
                   if (cfg.runs_dir / r["id"] / "stream.jsonl").exists()]
        assert len(started) == 1, "主 repo 不同也只准一筆起進程"
        other = b if started[0] is a else a
        # 等待中要主動報一次 running（reason=repo_lock_wait），輪詢代替固定
        # sleep，避免系統忙的時候變成假性失敗
        blocked = {}
        for _ in range(200):
            blocked = (await client.get(f"/api/runs/{other['id']}",
                                        headers=headers)).json()["run"]
            if blocked["status"] != "claimed":
                break
            await asyncio.sleep(0.05)
        assert blocked["status"] == "running", \
            "等待中要主動報一次 running，不能停在 claimed 看起來像掛了"
        assert blocked["reason"] == "repo_lock_wait"
    finally:
        cancel_a.set()
        cancel_b.set()
        await asyncio.wait_for(asyncio.gather(task_a, task_b,
                                              return_exceptions=True),
                               timeout=90)


async def test_lock_keys_are_taken_in_a_fixed_order(tmp_path):
    """取得順序不照主 repo 走，否則兩筆主 repo 相反的 run 會互等。"""
    locks = RepoLocks()
    taken: list[str] = []
    real_get = locks.get

    def spy(key):
        taken.append(key)
        return real_get(key)

    locks.get = spy  # type: ignore[assignment]
    async with locks.hold(["p/JSAI-Web", "p/JSAI-API"]):
        pass
    async with locks.hold(["p/JSAI-API", "p/JSAI-Web"]):
        pass
    assert taken == ["p/JSAI-API", "p/JSAI-Web"] * 2
