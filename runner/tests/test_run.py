"""一筆 run 的執行（REMOTE-OPS-PLAN §5.2～§5.6）。

Hub 是**真的** P1 端點（in-process ASGI），claude 是假的。每條測試都盯著一個
會安靜失敗的地方：狀態沒回報、退避沒發生、交接沒立旗標、取消沒殺到進程、
push 推了不是畫面上那幾顆。
"""

from __future__ import annotations

import asyncio
import json
import subprocess
import sys
from pathlib import Path

import pytest

from chatroom_runner import run as run_module
from chatroom_runner.run import RepoLocks, RunExecutor, resolve_repo
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
        text=True, capture_output=True,
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
    """同一個 repo 同時只有一個寫入型 run。

    PM 記憶裡「共用工作樹互相覆蓋」「commit 帶走別人的 index」發生過不只
    一次；遠端無人看著時代價更高。
    """
    _app, client = hub_app
    room_id, headers = ops_room
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "long")
    monkeypatch.setenv("FAKE_CLAUDE_SLEEP", "60")
    await runner_hub.register("test-host", "test", ["ai-website"], 2, "0.1")
    first = await create_run(client, room_id, headers, kind="ticket",
                             ref="task-lock-1")
    second = await create_run(client, room_id, headers, kind="ticket",
                              ref="task-lock-2")
    a = await runner_hub.claim()
    b = await runner_hub.claim()
    cfg = make_config(tmp_path, work_repo)
    locks = RepoLocks()
    cancel_a, cancel_b = asyncio.Event(), asyncio.Event()
    task_a = asyncio.ensure_future(
        _executor(cfg, runner_hub, locks=locks).execute(a, cancel_a))
    task_b = asyncio.ensure_future(
        _executor(cfg, runner_hub, locks=locks).execute(b, cancel_b))
    try:
        for _ in range(200):
            await asyncio.sleep(0.05)
            if locks.is_held("ai-website/JSAI-Web"):
                break
        await asyncio.sleep(0.5)
        holder = a if (cfg.runs_dir / a["id"] / "stream.jsonl").exists() else b
        other = b if holder is a else a
        assert not (cfg.runs_dir / other["id"] / "stream.jsonl").exists(), \
            "第二筆不該在第一筆還握著 repo 鎖時起進程"
        blocked = (await client.get(f"/api/runs/{other['id']}",
                                    headers=headers)).json()["run"]
        assert blocked["status"] == "claimed", "它連 running 都還不該報"
    finally:
        cancel_a.set()
        cancel_b.set()
        await asyncio.wait_for(asyncio.gather(task_a, task_b,
                                              return_exceptions=True),
                               timeout=90)
    assert first["id"] and second["id"]


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
    project = cfg.project("ai-website")
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
                        cfg.project("ai-website").repos["JSAI-Web"])
    settings = json.loads((run_dir / "settings.json").read_text("utf-8"))
    matcher = settings["hooks"]["PreToolUse"][0]["matcher"]
    assert "PowerShell" in matcher and "Bash" in matcher
    assert settings["hooks"]["PreCompact"]
    mcp = json.loads((run_dir / "mcp.json").read_text("utf-8"))
    env = mcp["mcpServers"]["chatroom"]["env"]
    assert env["PYTHONPATH"].endswith("bridge")
    assert env["CHATROOM_SESSION_KEY"] == "claude-run-r-files"
    assert env["CHATROOM_DEFAULT_NAME"].startswith("test-")
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
    argv = ex._argv("prompt", "contract", cfg.project("ai-website"),
                    tmp_path, "")
    assert "--verbose" in argv
    assert argv[argv.index("--output-format") + 1] == "stream-json"
    assert argv[argv.index("--permission-mode") + 1] == "auto"
    assert "--bare" not in argv, "--bare 只認 API key，本機是 OAuth 登入"
    assert FAKE_CLAUDE in argv[1]
    resumed = ex._argv("p", "c", cfg.project("ai-website"), tmp_path, "sid-1")
    assert resumed[resumed.index("--resume") + 1] == "sid-1"


def _allowed(argv: list[str]) -> list[str]:
    return argv[argv.index("--allowedTools") + 1].split(",")


def test_argv_preauthorizes_tools(tmp_path, work_repo):
    """`--permission-mode auto` 不會自動放行 MCP 工具：實測 run 9ee0fd48 裡
    `mcp__chatroom__chatroom_join` 停在權限提示，headless 沒有人能按允許。"""
    cfg = make_config(tmp_path, work_repo)
    ex = _executor(cfg, _NullHub())
    proj = cfg.project("ai-website")

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
    tools = _allowed(ex._argv("p", "c", cfg.project("ai-website"),
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
    """✔／!／✘ 三種狀態都要撈到，本機 stdio 伺服器不算連接器。"""
    found = dict(run_module.parse_mcp_list(MCP_LIST_SAMPLE))
    assert found["claude.ai Claude Docs"] == \
        "https://api.anthropic.com/v1/pages/mcp"
    assert found["claude.ai Notion"] == "https://mcp.notion.com/mcp"
    # 連不上的那行：錯誤訊息裡也有伺服器名，不能把 URL 或名字吃掉
    assert found["claude.ai Atlassian Rovo"] == \
        "https://mcp.atlassian.com/v1/mcp"
    assert "chatroom" not in found, "本機 stdio 伺服器不是要擋的東西"


def test_argv_denies_every_connector_except_the_allowed_ones(tmp_path,
                                                             work_repo):
    """預設拒絕：chatroom 以外的 claude.ai 連接器全部進 `--disallowedTools`。"""
    cfg = make_config(tmp_path, work_repo)
    ex = _executor(cfg, _NullHub())
    denied = _disallowed(ex._argv("p", "c", cfg.project("ai-website"),
                                  tmp_path, "", "ticket"))
    for name in ("mcp__claude_ai_Gmail__*", "mcp__claude_ai_Google_Drive__*",
                 "mcp__claude_ai_Canva__*", "mcp__claude_ai_Notion__*",
                 "mcp__claude_ai_Atlassian_Rovo__*"):
        assert name in denied
    assert "mcp__chatroom__*" not in denied
    assert not [x for x in denied if not x.startswith("mcp__claude_ai_")]


def test_extra_allowed_tools_keeps_that_server_out_of_the_deny_list(
        tmp_path, work_repo):
    """設定檔放行了 Atlassian 的工具，就不能反手把整台伺服器擋掉——
    一條規則兩端實作不一致只會湊出死局。"""
    cfg = make_config(
        tmp_path, work_repo,
        extra_allowed_tools=["mcp__claude_ai_Atlassian_Rovo__*"])
    ex = _executor(cfg, _NullHub())
    argv = ex._argv("p", "c", cfg.project("ai-website"), tmp_path, "",
                    "ticket")
    denied = _disallowed(argv)
    assert "mcp__claude_ai_Atlassian_Rovo__*" not in denied
    assert "mcp__claude_ai_Atlassian_Rovo__*" in _allowed(argv)
    assert "mcp__claude_ai_Gmail__*" in denied


def test_allowed_mcp_servers_opens_exactly_what_it_names(tmp_path, work_repo):
    cfg = make_config(tmp_path, work_repo,
                      allowed_mcp_servers=["chatroom", "claude.ai Gmail"])
    ex = _executor(cfg, _NullHub())
    denied = _disallowed(ex._argv("p", "c", cfg.project("ai-website"),
                                  tmp_path, "", "ticket"))
    assert "mcp__claude_ai_Gmail__*" not in denied
    assert "mcp__claude_ai_Canva__*" in denied


def test_selfcheck_probe_adds_newly_seen_connectors(tmp_path, work_repo):
    """保底名單沒有的連接器，自檢探到之後也要被擋。"""
    cfg = make_config(tmp_path, work_repo)
    ex = _executor(cfg, _NullHub())
    before = _disallowed(ex._argv("p", "c", cfg.project("ai-website"),
                                  tmp_path, "", "ticket"))
    assert "mcp__claude_ai_Brand_New_Thing__*" not in before
    run_module.remember_claude_ai_servers(
        run_module.parse_mcp_list(MCP_LIST_SAMPLE))
    after = _disallowed(ex._argv("p", "c", cfg.project("ai-website"),
                                 tmp_path, "", "ticket"))
    assert "mcp__claude_ai_Brand_New_Thing__*" in after


def test_run_settings_deny_the_connectors_at_both_layers(tmp_path, work_repo):
    """雙保險：`deniedMcpServers` 讓伺服器不載入，`permissions.deny` 是
    萬一它們仍然到齊時的第二道。"""
    cfg = make_config(tmp_path, work_repo)
    ex = _executor(cfg, _NullHub())
    run_dir = cfg.runs_dir / "r-deny"
    run_dir.mkdir(parents=True)
    ex._write_run_files(run_dir, {"id": "r-deny"},
                        cfg.project("ai-website").repos["JSAI-Web"])
    settings = json.loads((run_dir / "settings.json").read_text("utf-8"))
    # 有 URL 就用 serverUrl：文件說連接器的顯示名會改，serverName 會失效
    urls = [e["serverUrl"] for e in settings["deniedMcpServers"]
            if "serverUrl" in e]
    assert "https://gmailmcp.googleapis.com/mcp/v1" in urls
    assert "https://mcp.canva.com/mcp" in urls
    assert not [u for u in urls if "chatroom" in u]
    assert "mcp__claude_ai_Gmail__*" in settings["permissions"]["deny"]
    assert "mcp__chatroom__*" not in settings["permissions"]["deny"]


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
