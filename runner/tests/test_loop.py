"""主迴圈（REMOTE-OPS-PLAN §5.1／§5.7）。

用 stub executor 跑：這一層要驗的是「什麼時候領單、什麼時候停收、命令與取消
有沒有接上」，不是子進程怎麼跑（那在 `test_run.py`）。
"""

from __future__ import annotations

import asyncio
import json
import time
from datetime import datetime, timezone

import pytest

from chatroom_runner import gitops
from chatroom_runner.config import load_config
from chatroom_runner.hub import HubError, RunnerHub, load_identity
from chatroom_runner.loop import (EXIT_RESTART, EXIT_SELFCHECK_FAILED,
                                  RunnerLoop)

from ._fixtures import ROOT_TOKEN, create_run, make_config, write_config


class StubExecutor:
    """假的執行器：不起進程，只記下拿到什麼、等到被放行才結束。"""

    seen: list[dict] = []

    def __init__(self, gate: asyncio.Event | None = None) -> None:
        self.gate = gate
        self.turns = 0
        self.context_peak = 0
        self.cancelled = False
        # 停滯判斷讀這個欄位；stub 預設「剛剛才說過話」
        self.last_event_at = time.monotonic()

    def mark_activity(self) -> None:
        self.last_event_at = time.monotonic()

    async def execute(self, run, cancel=None):
        StubExecutor.seen.append(run)
        if self.gate is not None:
            waiter = asyncio.ensure_future(self.gate.wait())
            canceller = asyncio.ensure_future(cancel.wait()) if cancel else None
            watch = {waiter} | ({canceller} if canceller else set())
            done, pending = await asyncio.wait(
                watch, return_when=asyncio.FIRST_COMPLETED)
            for task in pending:
                task.cancel()
            self.cancelled = bool(canceller and canceller in done)
        return None


@pytest.fixture(autouse=True)
def _claude_logged_in(tmp_path):
    """測試用的設定目錄預設「已登入」。

    啟動自檢會驗登入，而假 claude 的 `auth status` 吐不出可解析的 JSON，
    判準會退回憑證檔——不先放一份，每個 `start()` 都會卡在自檢。
    """
    cfg_dir = tmp_path / "claude-config"
    cfg_dir.mkdir(parents=True, exist_ok=True)
    (cfg_dir / ".credentials.json").write_text('{"claudeAiOauth": {}}',
                                               encoding="utf-8")


@pytest.fixture(autouse=True)
def _clear_seen():
    StubExecutor.seen = []
    yield
    StubExecutor.seen = []


def _loop(cfg, hub, **kw):
    kw.setdefault("executor_factory", lambda: StubExecutor())
    return RunnerLoop(cfg, hub, **kw)


async def _register(loop):
    await loop.hub.register(loop.cfg.host, loop.cfg.label,
                            list(loop.cfg.workspaces), loop.cfg.max_parallel,
                            loop.cfg.version)


# ── 自檢 ────────────────────────────────────────────────────────

def _host(headers: dict) -> dict:
    """執行器命令現在要驗「執行器服務的 ops 房人類成員」；這裡的房沒綁
    工作區，走主持人視角（主 token ＋ X-Host-View）這條唯一豁免。這些
    測試測的是 loop 對命令的反應，不是命令的授權。"""
    return {**headers, "X-Host-View": "1"}


async def test_selfcheck_failure_goes_offline_and_never_claims(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    """🚨 自檢沒過就**不領單**。

    一台 claude 叫不起來的執行器領到單，只會把佇列裡的票一張一張變成
    failed，而房裡看到的是「它在做事」。
    """
    _app, client = hub_app
    room_id, headers = ops_room
    cfg = make_config(tmp_path, work_repo,
                      claude_bin=[str(tmp_path / "no-such-claude.exe")])
    loop = _loop(cfg, runner_hub)
    await _register(loop)
    run = await create_run(client, room_id, headers)

    code = await loop.run_forever(max_ticks=3)

    assert code == EXIT_SELFCHECK_FAILED
    assert loop.state.status == "offline"
    assert loop.state.selfcheck_problems
    assert StubExecutor.seen == []
    still = (await client.get(f"/api/runs/{run['id']}",
                              headers=headers)).json()["run"]
    assert still["status"] == "queued", "自檢沒過的執行器把單領走了"


async def test_selfcheck_failure_is_written_to_the_local_log(
        hub_app, runner_hub, work_repo, tmp_path, caplog):
    """原因要留在本機 log。

    排程工作那邊只看得到「退出碼 1」；不寫 log 的話，原因只存在於下一次
    心跳的 payload 裡，而那個一被覆蓋就查不回來了。
    """
    cfg = make_config(tmp_path, work_repo,
                      claude_bin=[str(tmp_path / "no-such-claude.exe")])
    loop = _loop(cfg, runner_hub)
    await _register(loop)

    with caplog.at_level("ERROR", logger="chatroom_runner.loop"):
        assert await loop.start() is False

    assert [r for r in caplog.records if r.message.startswith("自檢：")]


# ── claude 有沒有登入 ──────────────────────────────────────────

class _FakeProc:
    """假的 `claude auth status`：只回一段 stdout 與退出碼。"""

    def __init__(self, stdout: bytes, returncode: int = 0) -> None:
        self._stdout = stdout
        self.returncode = returncode

    async def communicate(self):
        return self._stdout, b""


def _fake_auth_status(monkeypatch, stdout: bytes, returncode: int = 0):
    async def fake_exec(*argv, **kwargs):
        assert argv[-2:] == ("auth", "status") or argv[-3:-1] == ("auth",
                                                                  "status")
        return _FakeProc(stdout, returncode)

    monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec)


async def test_selfcheck_passes_when_claude_is_logged_in(
        runner_hub, work_repo, tmp_path, monkeypatch):
    cfg = make_config(tmp_path, work_repo)
    loop = _loop(cfg, runner_hub)
    _fake_auth_status(monkeypatch, b'{"loggedIn": true}')

    assert await loop._check_claude_login() == []


async def test_selfcheck_fails_when_claude_is_not_logged_in(
        runner_hub, work_repo, tmp_path, monkeypatch):
    """🚨 `claude --version` 沒登入也回 0，所以這一項要自己驗。

    沒過的訊息要帶得走：印出那個設定目錄的登入指令。
    """
    cfg = make_config(tmp_path, work_repo)
    loop = _loop(cfg, runner_hub)
    _fake_auth_status(monkeypatch, b'{"loggedIn": false}')

    problems = await loop._check_claude_login()

    assert problems and "沒登入" in problems[0]
    assert "claude auth login" in problems[0]
    assert str(cfg.claude_config_dir) in problems[0]


async def test_login_check_falls_back_to_the_credentials_file(
        runner_hub, work_repo, tmp_path, monkeypatch):
    """`claude auth status` 叫不起來時退回憑證檔（安裝器的判準）。"""
    cfg = make_config(tmp_path, work_repo)
    loop = _loop(cfg, runner_hub)

    async def fake_exec(*argv, **kwargs):
        raise OSError("探針不真的起 claude")

    monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec)
    (cfg.claude_config_dir / ".credentials.json").unlink()
    assert await loop._check_claude_login()

    (cfg.claude_config_dir / ".credentials.json").write_text(
        '{"claudeAiOauth": {}}', encoding="utf-8")
    assert await loop._check_claude_login() == []


# ── gpg 的來源 ──────────────────────────────────────────────────

async def _probe_gpg(loop, monkeypatch):
    """跑 `_check_gpg`，回它實際想叫起來的那支程式。"""
    seen = {}

    async def fake_exec(program, *args, **kwargs):
        seen["program"] = program
        raise OSError("探針不真的起 gpg")

    monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec)
    await loop._check_gpg()
    return seen.get("program")


async def test_gpg_falls_back_to_the_program_git_signs_with(
        runner_hub, work_repo, tmp_path, monkeypatch):
    """排程工作的 PATH 上可能根本沒有 gpg，但 git 一直簽得起來。

    要驗的是「commit 簽不簽得動」，所以探針要打 git 用的那一支。
    """
    signer = r"C:\Program Files\Git\usr\bin\gpg.exe"

    async def fake_git(repo, *args, **kwargs):
        assert args == ("config", "--get", "gpg.program")
        return gitops.GitResult(0, signer, "")

    monkeypatch.setattr(gitops, "git", fake_git)
    loop = _loop(make_config(tmp_path, work_repo), runner_hub)

    assert await _probe_gpg(loop, monkeypatch) == signer


async def test_gpg_falls_back_to_path_when_git_has_no_program(
        runner_hub, work_repo, tmp_path, monkeypatch):
    """git 沒設 `gpg.program` 時就照舊走 PATH。"""
    async def fake_git(repo, *args, **kwargs):
        return gitops.GitResult(0, "", "")

    monkeypatch.setattr(gitops, "git", fake_git)
    loop = _loop(make_config(tmp_path, work_repo), runner_hub)

    assert await _probe_gpg(loop, monkeypatch) == "gpg"


async def test_gpg_bin_overrides_git(runner_hub, work_repo, tmp_path,
                                     monkeypatch):
    """設定檔寫死的 `gpg_bin` 最優先——連 git 都不必問。"""
    async def fake_git(repo, *args, **kwargs):  # pragma: no cover
        raise AssertionError("gpg_bin 設了還去問 git")

    monkeypatch.setattr(gitops, "git", fake_git)
    loop = _loop(make_config(tmp_path, work_repo, gpg_bin="D:/gnupg/gpg.exe"),
                 runner_hub)

    assert await _probe_gpg(loop, monkeypatch) == "D:/gnupg/gpg.exe"


async def test_selfcheck_catches_a_repo_on_a_forbidden_branch(
        runner_hub, work_repo, tmp_path):
    from ._fixtures import git
    git(work_repo, "checkout", "-b", "master")
    cfg = make_config(tmp_path, work_repo)
    problems = await _loop(cfg, runner_hub).selfcheck()
    assert any("master" in p for p in problems)


# ── 領單 ────────────────────────────────────────────────────────

async def test_tick_claims_and_spawns(hub_app, ops_room, runner_hub,
                                      work_repo, tmp_path):
    _app, client = hub_app
    room_id, headers = ops_room
    cfg = make_config(tmp_path, work_repo)
    gate = asyncio.Event()
    loop = _loop(cfg, runner_hub, executor_factory=lambda: StubExecutor(gate))
    assert await loop.start()
    run = await create_run(client, room_id, headers)

    await loop.tick()

    assert [r["id"] for r in StubExecutor.seen] == [run["id"]]
    assert run["id"] in loop.active
    gate.set()
    await asyncio.gather(*[a.task for a in loop.active.values()])


async def test_local_max_parallel_is_enforced(hub_app, ops_room, runner_hub,
                                              work_repo, tmp_path):
    """本地也要守上限。

    Hub 那道用的是我們**上一次 heartbeat** 回報的數字，最多晚一個心跳；
    真正知道現在跑幾個的是這裡。
    """
    _app, client = hub_app
    room_id, headers = ops_room
    cfg = make_config(tmp_path, work_repo, max_parallel=1)
    gate = asyncio.Event()
    loop = _loop(cfg, runner_hub, executor_factory=lambda: StubExecutor(gate))
    assert await loop.start()
    await create_run(client, room_id, headers, ref="task-a")
    await create_run(client, room_id, headers, ref="task-b")

    await loop.tick()
    await loop.tick()

    assert len(StubExecutor.seen) == 1
    assert len(loop.active) == 1
    gate.set()
    await asyncio.gather(*[a.task for a in loop.active.values()])


# ── 命令 ────────────────────────────────────────────────────────

async def test_pause_stops_claiming_and_resume_restores_it(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    _app, client = hub_app
    room_id, headers = ops_room
    cfg = make_config(tmp_path, work_repo)
    gate = asyncio.Event()
    loop = _loop(cfg, runner_hub, executor_factory=lambda: StubExecutor(gate))
    assert await loop.start()
    await create_run(client, room_id, headers)
    runner_id = runner_hub.identity.runner_id

    r = await client.post(f"/api/runners/{runner_id}/commands",
                          json={"command": "pause", "room_id": room_id},
                          headers=_host(headers))
    assert r.status_code == 200, r.text
    await loop.tick()
    assert loop.state.status == "paused"
    assert StubExecutor.seen == [], "暫停中還在領單"

    await client.post(f"/api/runners/{runner_id}/commands",
                      json={"command": "resume"}, headers=_host(headers))
    await loop.tick()
    assert loop.state.status == "online"
    assert len(StubExecutor.seen) == 1
    gate.set()
    await asyncio.gather(*[a.task for a in loop.active.values()])


async def test_drain_stops_claiming_without_restarting(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    """drain＝停收、跑完手上的，然後停在 paused 等人叫醒。

    **不自我重啟**：重啟回來的執行器會立刻開始領單，那與「我要它安靜下來」
    正好相反。
    """
    _app, client = hub_app
    room_id, headers = ops_room
    cfg = make_config(tmp_path, work_repo)
    loop = _loop(cfg, runner_hub)
    assert await loop.start()
    await create_run(client, room_id, headers)
    await client.post(f"/api/runners/{runner_hub.identity.runner_id}/commands",
                      json={"command": "drain"}, headers=_host(headers))

    await loop.tick()

    assert loop.state.draining and loop.state.status == "paused"
    assert loop.exit_code == 0 and StubExecutor.seen == []


async def test_restart_command_waits_for_runs_then_exits_75(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    _app, client = hub_app
    room_id, headers = ops_room
    cfg = make_config(tmp_path, work_repo)
    gate = asyncio.Event()
    loop = _loop(cfg, runner_hub, executor_factory=lambda: StubExecutor(gate))
    assert await loop.start()
    await create_run(client, room_id, headers)
    await loop.tick()
    assert len(loop.active) == 1

    await client.post(f"/api/runners/{runner_hub.identity.runner_id}/commands",
                      json={"command": "restart"}, headers=_host(headers))
    await loop.tick()
    assert loop.exit_code == 0, "還有 run 在跑就重啟＝把它殺在半路"

    gate.set()
    await asyncio.gather(*[a.task for a in loop.active.values()])
    await loop.tick()
    assert loop.exit_code == EXIT_RESTART


async def test_commands_are_taken_once(hub_app, ops_room, runner_hub,
                                       work_repo, tmp_path):
    """命令是一次性的：重送一次 restart 等於重啟兩次。"""
    _app, client = hub_app
    room_id, headers = ops_room
    cfg = make_config(tmp_path, work_repo)
    loop = _loop(cfg, runner_hub)
    assert await loop.start()
    await client.post(f"/api/runners/{runner_hub.identity.runner_id}/commands",
                      json={"command": "pause"}, headers=_host(headers))
    first = await loop.heartbeat()
    second = await loop.heartbeat()
    assert [c["command"] for c in first["commands"]] == ["pause"]
    assert second["commands"] == []


async def _command_row(app, cmd_id):
    return await (await app.state.db.execute(
        "SELECT command, acked_at, applied_at, note FROM runner_command"
        " WHERE id=?", (cmd_id,))).fetchone()


async def test_pause_is_reported_back_without_waiting_a_heartbeat(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    """§5.7 回饋鏈：命令一生效就**立刻再報一次**，不等下一個心跳週期。

    等 30 秒的話，人按完鈕看到的是一個完全沒有變化的面板——而那 30 秒裡
    唯一合理的推論是「按了沒反應」，於是他再按五次。
    """
    app, client = hub_app
    room_id, headers = ops_room
    cfg = make_config(tmp_path, work_repo)
    loop = _loop(cfg, runner_hub)
    assert await loop.start()
    cmd = (await client.post(
        f"/api/runners/{runner_hub.identity.runner_id}/commands",
        json={"command": "pause", "room_id": room_id},
        headers=_host(headers))).json()["command"]

    await loop.heartbeat()

    row = await _command_row(app, cmd["id"])
    assert row["applied_at"], "命令生效了，Hub 上卻只有『已送達』"
    assert row["note"] == "已暫停"
    runner = await (await app.state.db.execute(
        "SELECT status FROM runner WHERE id=?",
        (runner_hub.identity.runner_id,))).fetchone()
    assert runner["status"] == "paused", "生效的狀態也要在同一輪上去"


async def test_restart_reports_waiting_then_restarting(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    """restart 的兩段：等 run 跑完（未生效、但有理由）→ 退出前標生效。

    少了前半段，面板停在「已送達」而人不知道它在等什麼；少了後半段，進程
    退出後 Hub 還寫著 online，要等 180 秒的 sweep 才變 offline——重啟只要
    1～2 分鐘，全程看不到任何「正在重啟」。
    """
    app, client = hub_app
    room_id, headers = ops_room
    cfg = make_config(tmp_path, work_repo)
    gate = asyncio.Event()
    loop = _loop(cfg, runner_hub, executor_factory=lambda: StubExecutor(gate))
    assert await loop.start()
    await create_run(client, room_id, headers)
    await loop.tick()
    assert len(loop.active) == 1
    cmd = (await client.post(
        f"/api/runners/{runner_hub.identity.runner_id}/commands",
        json={"command": "restart", "room_id": room_id},
        headers=_host(headers))).json()["command"]

    await loop.tick()
    row = await _command_row(app, cmd["id"])
    assert row["applied_at"] is None, "run 還在跑就說重啟好了"
    assert row["note"] == "等 1 筆 run 結束後重啟"
    assert loop.exit_code == 0

    gate.set()
    await asyncio.gather(*[a.task for a in loop.active.values()])
    await loop.tick()

    assert loop.exit_code == EXIT_RESTART
    row = await _command_row(app, cmd["id"])
    assert row["applied_at"], "退出前沒有把命令標成生效"
    assert row["note"] == "正在重啟，預計 1～2 分鐘完成"
    runner = await (await app.state.db.execute(
        "SELECT status FROM runner WHERE id=?",
        (runner_hub.identity.runner_id,))).fetchone()
    assert runner["status"] == "restarting"


async def test_a_waiting_restart_keeps_updating_its_count(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    """等待中的 restart 每一輪都重報一次：筆數要跟著手上的 run 變少。

    只 ack 一次的話，Hub 上會永遠停在「等 2 筆」，而人會以為它卡死了。
    """
    app, client = hub_app
    room_id, headers = ops_room
    cfg = make_config(tmp_path, work_repo)
    gate = asyncio.Event()
    loop = _loop(cfg, runner_hub, executor_factory=lambda: StubExecutor(gate))
    assert await loop.start()
    await create_run(client, room_id, headers, ref="task-1")
    await create_run(client, room_id, headers, ref="task-2")
    await loop.tick()
    assert len(loop.active) == 2
    cmd = (await client.post(
        f"/api/runners/{runner_hub.identity.runner_id}/commands",
        json={"command": "restart"}, headers=_host(headers))).json()["command"]
    await loop.tick()
    assert (await _command_row(app, cmd["id"]))["note"] ==         "等 2 筆 run 結束後重啟"

    # 一筆收工，另一筆還在：下一次心跳的數字要跟著改
    done = list(loop.active.values())[0]
    done.cancel.set()
    await asyncio.wait_for(done.task, timeout=10)
    await loop.heartbeat()
    assert (await _command_row(app, cmd["id"]))["note"] ==         "等 1 筆 run 結束後重啟"

    gate.set()
    await asyncio.gather(*[a.task for a in loop.active.values()])


async def test_the_exit_path_does_not_hang_on_an_unreachable_hub(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    """Hub 連不上的時候，「我要重啟了」送不出去也**照樣退出**。

    退出路徑卡在一個 socket 上的話，這台執行器連退場都做不到，而排程工作
    在等它結束才會把它拉起來。
    """
    from chatroom_runner.hub import HubError

    _app, client = hub_app
    room_id, headers = ops_room
    cfg = make_config(tmp_path, work_repo)
    loop = _loop(cfg, runner_hub)
    assert await loop.start()
    await client.post(f"/api/runners/{runner_hub.identity.runner_id}/commands",
                      json={"command": "restart"}, headers=_host(headers))
    await loop.heartbeat()
    assert loop.state.restart_pending

    async def broken(*a, **kw):
        raise HubError("連不上", code="unreachable")

    runner_hub.heartbeat = broken
    await asyncio.wait_for(loop.tick(), timeout=10)
    assert loop.exit_code == EXIT_RESTART


# ── 取消 ────────────────────────────────────────────────────────

async def test_cancel_request_from_heartbeat_reaches_the_run(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    _app, client = hub_app
    room_id, headers = ops_room
    cfg = make_config(tmp_path, work_repo)
    gate = asyncio.Event()
    holder = StubExecutor(gate)
    loop = _loop(cfg, runner_hub, executor_factory=lambda: holder)
    assert await loop.start()
    run = await create_run(client, room_id, headers)
    await loop.tick()

    r = await client.post(f"/api/runs/{run['id']}/cancel", headers=headers)
    assert r.json()["cancelled"] is False, "running 的取消不該直接改狀態"
    await loop.tick()

    await asyncio.wait_for(asyncio.gather(
        *[a.task for a in loop.active.values()]), timeout=10)
    assert holder.cancelled, "取消請求沒有傳到 run"


# ── 軟上限與維護窗 ──────────────────────────────────────────────

async def test_usage_soft_cap_stops_claiming(hub_app, ops_room, runner_hub,
                                             work_repo, tmp_path):
    """5 小時窗軟上限到了就停收。**這是自我約束，不是真實額度**（§10）。"""
    from chatroom_runner.usage import UsageStore

    _app, client = hub_app
    room_id, headers = ops_room
    cfg = make_config(tmp_path, work_repo, usage_soft_cap_tokens=1000)
    store = UsageStore(cfg.usage_db)
    store.record("earlier-run", 5000, 1.5)
    loop = _loop(cfg, runner_hub, usage_store=store)
    assert await loop.start()
    await create_run(client, room_id, headers)

    await loop.tick()

    assert loop.state.status == "limited"
    assert loop.state.limit_reason == "usage_soft_cap"
    assert StubExecutor.seen == []


async def test_maintenance_window_exits_75_only_when_idle(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    _app, client = hub_app
    room_id, headers = ops_room
    cfg = make_config(tmp_path, work_repo, maintenance_hour=4)
    clock = [datetime(2026, 9, 16, 2, 0, tzinfo=timezone.utc)]
    gate = asyncio.Event()
    loop = _loop(cfg, runner_hub, now=lambda: clock[0],
                 executor_factory=lambda: StubExecutor(gate))
    assert await loop.start()
    await create_run(client, room_id, headers)

    await loop.tick()
    assert len(loop.active) == 1
    clock[0] = datetime(2026, 9, 16, 4, 30, tzinfo=timezone.utc)
    await loop.tick()
    assert loop.exit_code == 0, "有 run 在跑就順延，不能把它殺在半路"

    gate.set()
    await asyncio.gather(*[a.task for a in loop.active.values()])
    await loop.tick()
    assert loop.exit_code == EXIT_RESTART
    assert loop.state.restart_reason == "maintenance_window"


async def test_maintenance_does_not_fire_before_the_window(
        hub_app, runner_hub, work_repo, tmp_path):
    cfg = make_config(tmp_path, work_repo, maintenance_hour=4)
    loop = _loop(cfg, runner_hub,
                 now=lambda: datetime(2026, 9, 16, 2, 0, tzinfo=timezone.utc))
    assert await loop.start()
    await loop.tick()
    assert loop.exit_code == 0


async def test_heartbeat_survives_an_unreachable_hub(work_repo, tmp_path):
    """Hub 連不上不該讓執行器自殺——手上的 run 還在跑。"""
    from chatroom_runner.hub import HubError

    class Broken:
        identity = type("I", (), {"runner_id": "r", "runner_token": ""})()

        async def heartbeat(self, *a, **kw):
            raise HubError("連不上", code="unreachable")

        async def claim(self):
            raise HubError("連不上", code="unreachable")

    cfg = make_config(tmp_path, work_repo)
    loop = _loop(cfg, Broken())
    assert await loop.heartbeat() == {}
    assert await loop.claim_once() is None


# ── run 的例外與落地回報（審查 09/16 Major）──────────────────────

async def test_a_task_that_raises_is_logged_not_swallowed(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, caplog):
    """🚨 `add_done_callback` 不取 `task.exception()` ＝例外被吃掉。

    那筆 run 從 active 消失、房裡停在 running，而本機一行紀錄都沒有。
    """
    import logging

    _app, client = hub_app
    room_id, headers = ops_room

    class Boom:
        turns = 0
        context_peak = 0

        async def execute(self, run, cancel=None):
            raise RuntimeError("執行器自己炸了")

    cfg = make_config(tmp_path, work_repo)
    loop = _loop(cfg, runner_hub, executor_factory=lambda: Boom())
    assert await loop.start()
    run = await create_run(client, room_id, headers)

    with caplog.at_level(logging.ERROR, logger="chatroom_runner.loop"):
        await loop.tick()
        await asyncio.gather(*[a.task for a in list(loop.active.values())],
                             return_exceptions=True)
        await asyncio.sleep(0)

    assert run["id"] not in loop.active
    mine = [r for r in caplog.records if r.name == "chatroom_runner.loop"]
    assert mine, "例外沒有進 log"
    assert any(run["id"][:8] in r.getMessage() for r in mine)


async def test_failed_report_on_disk_is_resent_on_the_next_heartbeat(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    """落地的回報要有人再送一次，否則它就只是一個沒人讀的檔案。"""
    _app, client = hub_app
    room_id, headers = ops_room
    cfg = make_config(tmp_path, work_repo)
    loop = _loop(cfg, runner_hub)
    assert await loop.start()
    run = await create_run(client, room_id, headers)
    claimed = await runner_hub.claim()
    assert claimed is not None

    run_dir = cfg.runs_dir / run["id"]
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "report_failed.json").write_text(json.dumps({
        "run_id": run["id"], "status": "failed", "reason": "boom",
        "result": "沒送出去的那一筆", "claude_session_id": "", "usage": None,
    }, ensure_ascii=False), encoding="utf-8")

    await loop.heartbeat()

    assert not (run_dir / "report_failed.json").exists(), "重送成功沒有清掉"
    final = (await client.get(f"/api/runs/{run['id']}",
                              headers=headers)).json()["run"]
    assert final["status"] == "failed"
    assert "沒送出去的那一筆" in (final["result"] or "")


def _land(cfg, run_id: str, status: str, result: str) -> "object":
    """在 run 目錄放一份送不出去的回報，回那個檔案的路徑。"""
    run_dir = cfg.runs_dir / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    path = run_dir / "report_failed.json"
    path.write_text(json.dumps(
        {"run_id": run_id, "status": status, "reason": "boom",
         "result": result, "claude_session_id": "", "usage": None},
        ensure_ascii=False), encoding="utf-8")
    return path


async def test_landed_report_is_discarded_when_the_hub_already_settled(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, caplog):
    """Hub 已經收場（這裡是 cancelled）⇒ 落地回報作廢並刪檔（裁決 09/22）。

    留著它的話，每一次 heartbeat 都會再撞一次同一個 409、再寫一行看起來像
    故障的 warning，而那筆 run 的結局早就定了，這一筆送不進去也送不出新的
    意義。
    """
    import logging

    _app, client = hub_app
    room_id, headers = ops_room
    cfg = make_config(tmp_path, work_repo)
    loop = _loop(cfg, runner_hub)
    assert await loop.start()
    run = await create_run(client, room_id, headers)
    assert await runner_hub.claim() is not None
    # 人類按了取消，執行器先把它收成 cancelled——Hub 從此沒有下一步
    await runner_hub.report(run["id"], "cancelled", reason="cancel_requested")
    path = _land(cfg, run["id"], "done", "來不及送出去的收工")

    with caplog.at_level(logging.WARNING, logger="chatroom_runner.loop"):
        await loop.heartbeat()

    assert not path.exists(), "Hub 已收場的落地回報要作廢，不能每次心跳重撞"
    assert any("已經收場為 cancelled" in r.getMessage()
               for r in caplog.records
               if r.name == "chatroom_runner.loop"), "作廢要留一行可查的紀錄"
    # 作廢的是那份檔案，不是 Hub 上的結局
    final = (await client.get(f"/api/runs/{run['id']}",
                              headers=headers)).json()["run"]
    assert final["status"] == "cancelled"


async def test_landed_report_is_kept_when_the_hub_has_not_settled(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    """Hub 還沒收場（這裡是 queued）的 409 ⇒ **保留**，等下一次心跳再送。

    非終局的 409 多半是這台執行器與 Hub 的狀態暫時對不上（run 被重排回
    queued、換了一台執行器領走）。把它當成作廢就是把這一輪的結果丟掉。
    """
    _app, client = hub_app
    room_id, headers = ops_room
    cfg = make_config(tmp_path, work_repo)
    loop = _loop(cfg, runner_hub)
    assert await loop.start()
    # 不領走：Hub 停在 queued，而 `queued → done` 是非法轉移
    run = await create_run(client, room_id, headers)
    path = _land(cfg, run["id"], "done", "送不進去的收工")

    await loop.heartbeat()

    assert path.exists(), "非終局的 409 把結果刪掉了"
    final = (await client.get(f"/api/runs/{run['id']}",
                              headers=headers)).json()["run"]
    assert final["status"] == "queued"


# ── 維護窗（審查 09/16 Major）───────────────────────────────────

async def test_maintenance_does_not_restart_while_paused_or_draining(
        hub_app, runner_hub, work_repo, tmp_path):
    """drain／pause 的語意是「安靜下來」，而重啟回來的執行器會立刻領單。"""
    cfg = make_config(tmp_path, work_repo, maintenance_hour=4)
    clock = [datetime(2026, 9, 16, 2, 0, tzinfo=timezone.utc)]
    loop = _loop(cfg, runner_hub, now=lambda: clock[0])
    assert await loop.start()
    clock[0] = datetime(2026, 9, 16, 4, 30, tzinfo=timezone.utc)

    loop.apply_command("drain")
    await loop.tick()
    assert loop.exit_code == 0, "draining 還是重啟了"

    loop.apply_command("pause")
    await loop.tick()
    assert loop.exit_code == 0, "paused 還是重啟了"

    loop.apply_command("resume")
    await loop.tick()
    assert loop.exit_code == EXIT_RESTART, "恢復之後該做的維護沒有做"


async def test_maintenance_runs_once_a_day_across_restarts(
        hub_app, runner_hub, work_repo, tmp_path):
    """🚨 一天一次，而且跨進程有效（實機 2026-09-18）。

    「今天做過沒」只記在記憶體裡的話，維護窗重啟回來的進程還在同一個小時
    內，於是再判一次「現在是 maintenance_hour」再退——實機上那一小時每 5
    分鐘循環了 12 次。
    """
    _app, client = hub_app
    cfg = make_config(tmp_path, work_repo, maintenance_hour=4)
    clock = [datetime(2026, 9, 18, 2, 0, tzinfo=timezone.utc)]
    loop = _loop(cfg, runner_hub, now=lambda: clock[0])
    assert await loop.start()

    clock[0] = datetime(2026, 9, 18, 4, 0, tzinfo=timezone.utc)
    await loop.tick()
    assert loop.exit_code == EXIT_RESTART
    saved = json.loads(cfg.state_file.read_text("utf-8"))
    assert saved["last_maintenance_day"] == "2026-09-18", (
        "維護窗日期沒有落地，重啟回來的進程會再退一次")

    # 重啟回來：還在窗裡，但今天做過了
    clock[0] = datetime(2026, 9, 18, 4, 5, tzinfo=timezone.utc)
    hub2 = RunnerHub("http://test", ROOT_TOKEN, client=client,
                     identity=load_identity(cfg.state_file))
    loop2 = _loop(cfg, hub2, now=lambda: clock[0])
    assert await loop2.start()
    await loop2.tick()
    assert loop2.exit_code == 0, "同一天第二次啟動又退了一次"

    # 隔天到點：照樣要做
    clock[0] = datetime(2026, 9, 19, 4, 0, tzinfo=timezone.utc)
    await loop2.tick()
    assert loop2.exit_code == EXIT_RESTART
    assert loop2.state.restart_reason == "maintenance_window"


async def test_a_runner_started_inside_the_window_does_not_exit_at_once(
        hub_app, runner_hub, work_repo, tmp_path):
    """啟動本身就等於重啟過了——沒有狀態檔也不該立刻再退一次。"""
    cfg = make_config(tmp_path, work_repo, maintenance_hour=4)
    clock = [datetime(2026, 9, 18, 4, 30, tzinfo=timezone.utc)]
    loop = _loop(cfg, runner_hub, now=lambda: clock[0])
    assert await loop.start()
    await loop.tick()
    assert loop.exit_code == 0
    clock[0] = datetime(2026, 9, 18, 4, 55, tzinfo=timezone.utc)
    await loop.tick()
    assert loop.exit_code == 0, "同一個維護窗裡又退了一次"


# ── 停滯提醒 ────────────────────────────────────────────────────

async def test_a_silent_run_is_marked_stalled_once(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, monkeypatch):
    """🚨 進行中卻長時間沒有任何 stream 事件的 run 要在面板上看得見。

    run 是單回合 headless 進程，房裡的人 mention 它不會讓它醒過來——一個掛住
    的 run 與一個正在思考的 run，在面板上長得一模一樣。這裡用假 claude 的
    `long`（吐兩行就長睡）＋注入的單調時鐘製造「長時間無輸出」。

    **標記只記一次**：每個心跳都記一次的話，log 與面板會被同一件事洗版，
    而「它什麼時候開始不說話的」反而看不出來。不殺進程，牆鐘上限照舊。
    """
    _app, client = hub_app
    room_id, headers = ops_room
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "long")
    monkeypatch.setenv("FAKE_CLAUDE_SLEEP", "60")
    clock = {"t": 0.0}
    cfg = make_config(tmp_path, work_repo, stall_warn_seconds=600)
    loop = RunnerLoop(cfg, runner_hub, monotonic=lambda: clock["t"])
    await _register(loop)
    await create_run(client, room_id, headers, kind="ticket", ref="task-stall")

    await loop.tick()
    assert loop.active, "沒領到單就驗不到停滯"
    active = next(iter(loop.active.values()))
    stream = cfg.runs_dir / active.run["id"] / "stream.jsonl"
    for _ in range(200):
        await asyncio.sleep(0.05)
        if stream.exists() and len(stream.read_text("utf-8").splitlines()) >= 2:
            break
    assert active.executor.events_seen >= 2, "子進程根本沒吐東西"

    # 執行器起的 run id 要立刻落地，崩潰之後才對得了帳
    saved = json.loads(cfg.state_file.read_text("utf-8"))
    assert saved["active_run_ids"] == [active.run["id"]]

    # 從這裡開始假 claude 只會睡：時鐘往前跳就是「長時間沒有輸出」
    clock["t"] = 1200.0
    for _ in range(3):
        await loop.heartbeat()

    assert active.stalled and active.stall_marks == 1, "重複標記會洗版"
    assert active.resume_marks == 0
    assert active.view().to_dict()["stalled_seconds"] >= 600
    assert active.run["id"] in loop.active, "只標記，不殺進程"

    # 標記那一刻對 Hub 報一次，房裡就看得到——只有儀表板看得到的話，
    # 人要先想到去開面板，才會知道有件事在等他
    msgs = (await client.get(f"/api/rooms/{room_id}/messages",
                             headers=headers)).json()["messages"]
    stalled_msgs = [m for m in msgs if m["system_event"] == "run_stalled"]
    assert len(stalled_msgs) == 1, "三個心跳報了三次＝把房間洗掉"
    assert "沒有輸出" in stalled_msgs[0]["content"]

    # 再收到事件就解除，一樣只記一次
    active.executor.mark_activity()
    for _ in range(3):
        await loop.heartbeat()
    assert not active.stalled and active.stalled_seconds == 0
    assert active.resume_marks == 1 and active.stall_marks == 1
    msgs = (await client.get(f"/api/rooms/{room_id}/messages",
                             headers=headers)).json()["messages"]
    assert len([m for m in msgs
                if m["system_event"] == "run_resumed"]) == 1
    assert len([m for m in msgs
                if m["system_event"] == "run_stalled"]) == 1

    await loop.shutdown()


async def test_stall_marking_is_off_when_the_threshold_is_zero(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    """門檻 0 ＝關掉。開關留白時該什麼都不做，不是「每個心跳都標」。"""
    cfg = make_config(tmp_path, work_repo, stall_warn_seconds=0)
    gate = asyncio.Event()
    loop = RunnerLoop(cfg, runner_hub, monotonic=lambda: 10_000.0,
                      executor_factory=lambda: StubExecutor(gate))
    await _register(loop)
    _app, client = hub_app
    room_id, headers = ops_room
    await create_run(client, room_id, headers, ref="task-nostall")
    await loop.tick()
    active = next(iter(loop.active.values()))
    await loop.heartbeat()
    assert not active.stalled and active.stall_marks == 0
    gate.set()
    await loop.shutdown()


# ── 身分落地（審查 09/21 P1）────────────────────────────────────

async def test_registration_is_persisted_before_any_run(
        hub_app, runner_hub, work_repo, tmp_path):
    """🚨 註冊一回來就要把 `runner_token` 寫進 ``state.json``。

    Hub 只在**建立那一次**回 token，而且沒有補發端點。等到有 run 或正常
    退出才寫的話，第一次註冊完就被殺掉（斷電、關機、工作被砍）的執行器，
    token 只活在那個進程的記憶體裡——下一次同 host+label 啟動會被 403
    `runner_token_required` 擋下來，只能換一組 label 才回得來。
    """
    _app, client = hub_app
    cfg = make_config(tmp_path, work_repo)
    loop = _loop(cfg, runner_hub)

    # 註冊之後、任何 run 之前就把進程砍掉：`start()` 的下一步是心跳
    async def _killed(*_a, **_kw):
        raise RuntimeError("進程在註冊之後、領單之前被殺掉")

    runner_hub.heartbeat = _killed
    with pytest.raises(RuntimeError):
        await loop.start()

    saved = json.loads(cfg.state_file.read_text("utf-8"))
    assert saved["runner_token"], "token 只留在記憶體，這台再也註冊不回去"
    assert saved["runner_id"] == runner_hub.identity.runner_id
    assert saved["active_run_ids"] == []

    # 沒有那把 token 的話，同 host+label 註冊就是被擋在門外
    blind = RunnerHub("http://test", ROOT_TOKEN, client=client)
    with pytest.raises(HubError) as blocked:
        await blind.register(cfg.host, cfg.label, [], cfg.max_parallel,
                             cfg.version)
    assert blocked.value.code == "runner_token_required"

    # 讀回落地的身分：重新起來的是同一台，心跳照樣打得出去
    hub2 = RunnerHub("http://test", ROOT_TOKEN, client=client,
                     identity=load_identity(cfg.state_file))
    loop2 = _loop(cfg, hub2)
    assert await loop2.start()
    assert hub2.identity.runner_id == saved["runner_id"]
    assert await loop2.heartbeat() != {}


# ── 啟動對帳（孤兒 run）──────────────────────────────────────────

async def _orphan(client, room_id, headers, runner_hub, ref):
    """造一筆「Hub 說在跑、本機沒有進程」的 run。"""
    await create_run(client, room_id, headers, kind="ticket", ref=ref)
    claimed = await runner_hub.claim()
    await runner_hub.report(claimed["id"], "running", reason="spawn")
    return claimed["id"]


async def test_startup_reconciles_a_run_with_no_process(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    """🚨 上一次崩潰留下的 run 要在啟動時收掉。

    2026-09-17：執行任務炸掉、claude 進程消失，而 Hub 上那筆 run 停在
    running。面板上是一筆正在做事的派工，實際上沒有任何東西在動，人類按取消
    也沒有人處理——因為已經沒有人在處理它了。
    """
    _app, client = hub_app
    room_id, headers = ops_room
    cfg = make_config(tmp_path, work_repo)
    loop = _loop(cfg, runner_hub)
    await _register(loop)
    run_id = await _orphan(client, room_id, headers, runner_hub, "task-orphan")
    # 上一個執行器進程死掉：狀態檔還記著它，但本機一個進程都沒有
    runner_hub.identity.active_run_ids = [run_id]

    recovered = await loop.reconcile()

    assert recovered == [run_id]
    body = (await client.get(f"/api/runs/{run_id}", headers=headers)).json()
    assert body["run"]["status"] == "failed"
    assert body["run"]["reason"] == "runner_restarted"
    # 收完就把清單清掉，下一次啟動不會再對同一筆
    assert json.loads(cfg.state_file.read_text("utf-8"))["active_run_ids"] == []


async def test_reconcile_honours_a_pending_cancel(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    """人類已經按過取消的孤兒收成 cancelled，不是 failed。

    收成 failed 的話，稽核串會說「執行器把它做壞了」，而事實是人類要它停。
    """
    _app, client = hub_app
    room_id, headers = ops_room
    cfg = make_config(tmp_path, work_repo)
    loop = _loop(cfg, runner_hub)
    await _register(loop)
    run_id = await _orphan(client, room_id, headers, runner_hub, "task-cancel")
    r = await client.post(f"/api/runs/{run_id}/cancel", headers=headers)
    assert r.status_code == 200 and r.json()["cancelled"] is False
    runner_hub.identity.active_run_ids = [run_id]

    assert await loop.reconcile() == [run_id]

    body = (await client.get(f"/api/runs/{run_id}", headers=headers)).json()
    assert body["run"]["status"] == "cancelled"


async def test_cancel_of_a_run_we_do_not_hold_is_reported_once(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    """🚨 手上沒有那個進程也要收場（實機 2026-09-18）。

    `cancel_requested_run_ids` 只對 `self.active` 動作的話，上一個執行器進程
    留下的 run 會永遠停在 `claimed`＋`cancel_requested=1`：人按了取消，而
    Hub 那端永遠等不到回報——正式 Hub 上有一筆從 09-17 掛到隔天。

    同一筆**只報一次**：每次心跳都報的話，那筆 run 的稽核串會被同一句話
    洗滿，而 Hub 回的 409 也讓它看不出有什麼不對。
    """
    _app, client = hub_app
    room_id, headers = ops_room
    cfg = make_config(tmp_path, work_repo)
    loop = _loop(cfg, runner_hub)
    assert await loop.start()
    await create_run(client, room_id, headers, kind="ticket", ref="task-ghost")
    claimed = await runner_hub.claim()
    run_id = claimed["id"]
    r = await client.post(f"/api/runs/{run_id}/cancel", headers=headers)
    assert r.status_code == 200 and r.json()["cancelled"] is False
    assert run_id not in loop.active, "這條測試要的正是「不在手上」"

    reports: list[tuple] = []
    real_report = runner_hub.report

    async def counting_report(rid, status, **kw):
        reports.append((rid, status))
        return await real_report(rid, status, **kw)

    runner_hub.report = counting_report
    try:
        await loop.heartbeat()
        body = (await client.get(f"/api/runs/{run_id}",
                                 headers=headers)).json()
        assert body["run"]["status"] == "cancelled", (
            "取消請求沒有人收，那筆 run 會一直掛在 claimed")
        await loop.heartbeat()
    finally:
        runner_hub.report = real_report
    assert reports == [(run_id, "cancelled")], (
        f"同一筆 run 報了不只一次：{reports}")


async def test_reconcile_leaves_a_finished_run_alone(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    """已經收場的 run 不再動它——狀態機不允許，硬打也只是每次啟動多一輪 409。"""
    _app, client = hub_app
    room_id, headers = ops_room
    cfg = make_config(tmp_path, work_repo)
    loop = _loop(cfg, runner_hub)
    await _register(loop)
    run_id = await _orphan(client, room_id, headers, runner_hub, "task-done")
    await runner_hub.report(run_id, "done", reason="finished")
    runner_hub.identity.active_run_ids = [run_id]

    assert await loop.reconcile() == []

    body = (await client.get(f"/api/runs/{run_id}", headers=headers)).json()
    assert body["run"]["status"] == "done"


async def test_reconcile_works_without_read_access_to_the_run(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, monkeypatch):
    """🚨 對帳**不能依賴讀得到那筆 run**。

    實測 2026-09-17：`GET /api/runs/{id}` 的主持人視角只認人類憑證
    （`human_token_required`），執行器的 agent token 借不到那個身分。查不到
    現況時要直接回報，讓 Hub 的狀態機當裁判——不然這條保護在正式環境永遠
    是空轉的，而那正是它要救的那一次。
    """
    _app, client = hub_app
    room_id, headers = ops_room
    cfg = make_config(tmp_path, work_repo)
    loop = _loop(cfg, runner_hub)
    await _register(loop)
    run_id = await _orphan(client, room_id, headers, runner_hub, "task-blind")
    runner_hub.identity.active_run_ids = [run_id]
    # 模擬正式環境：查不到就是 None
    monkeypatch.setattr(type(runner_hub), "get_run",
                        lambda self, rid: _none())

    assert await loop.reconcile() == [run_id]

    body = (await client.get(f"/api/runs/{run_id}", headers=headers)).json()
    assert body["run"]["status"] == "failed"
    assert body["run"]["reason"] == "runner_restarted"


async def _none():
    return None


async def test_reconcile_uses_the_heartbeat_cancel_list_when_it_cannot_read(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, monkeypatch):
    """讀不到 run 時，取消與否改認 heartbeat 的 `cancel_requested_run_ids`。"""
    _app, client = hub_app
    room_id, headers = ops_room
    cfg = make_config(tmp_path, work_repo)
    loop = _loop(cfg, runner_hub)
    await _register(loop)
    run_id = await _orphan(client, room_id, headers, runner_hub, "task-blindc")
    await client.post(f"/api/runs/{run_id}/cancel", headers=headers)
    runner_hub.identity.active_run_ids = [run_id]
    monkeypatch.setattr(type(runner_hub), "get_run",
                        lambda self, rid: _none())

    assert await loop.reconcile({run_id}) == [run_id]

    body = (await client.get(f"/api/runs/{run_id}", headers=headers)).json()
    assert body["run"]["status"] == "cancelled"


async def test_reconcile_swallows_a_run_that_already_finished(
        hub_app, ops_room, runner_hub, work_repo, tmp_path, monkeypatch):
    """讀不到現況又盲報時，Hub 的 409 是**正常結果**，不是錯誤。"""
    _app, client = hub_app
    room_id, headers = ops_room
    cfg = make_config(tmp_path, work_repo)
    loop = _loop(cfg, runner_hub)
    await _register(loop)
    run_id = await _orphan(client, room_id, headers, runner_hub, "task-blindd")
    await runner_hub.report(run_id, "done", reason="finished")
    runner_hub.identity.active_run_ids = [run_id]
    monkeypatch.setattr(type(runner_hub), "get_run",
                        lambda self, rid: _none())

    assert await loop.reconcile() == []

    body = (await client.get(f"/api/runs/{run_id}", headers=headers)).json()
    assert body["run"]["status"] == "done"


# ── 軟停止與 @ 轉達 ─────────────────────────────────────────────

async def _soft_stop(client, headers, run_id):
    r = await client.post(f"/api/runs/{run_id}/soft-stop", headers=headers)
    assert r.status_code == 200, r.text
    return r.json()


async def test_soft_stop_raises_the_flag_without_killing_the_process(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    """收尾請求立旗標就好。**這一刻不殺進程**——agent 要有機會把目前這一步
    做完、寫完摘要；殺掉的話那份摘要就不存在了，而它才是遠端唯一看得到的
    東西。
    """
    _app, client = hub_app
    room_id, headers = ops_room
    cfg = make_config(tmp_path, work_repo)
    gate = asyncio.Event()
    holder = StubExecutor(gate)
    loop = _loop(cfg, runner_hub, executor_factory=lambda: holder)
    assert await loop.start()
    run = await create_run(client, room_id, headers)
    await loop.tick()

    await _soft_stop(client, headers, run["id"])
    await loop.tick()

    flag = cfg.runs_dir / run["id"] / "soft_stop.flag"
    assert flag.exists(), "收尾旗標沒立起來，hook 永遠看不到這件事"
    assert not holder.cancelled, "收尾不該直接終止進程"

    gate.set()
    await asyncio.wait_for(asyncio.gather(
        *[a.task for a in loop.active.values()]), timeout=10)


async def test_soft_stop_falls_back_to_a_hard_kill_after_the_timeout(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    """一個**已經不再呼叫工具**的 run 永遠讀不到旗標。沒有逾時的話，它會把
    那個併發位置佔到牆鐘上限，而房裡的人以為它在收尾。
    """
    _app, client = hub_app
    room_id, headers = ops_room
    cfg = make_config(tmp_path, work_repo, soft_stop_timeout=60)
    clock = {"t": 1000.0}
    gate = asyncio.Event()
    holder = StubExecutor(gate)
    loop = _loop(cfg, runner_hub, executor_factory=lambda: holder,
                 monotonic=lambda: clock["t"])
    assert await loop.start()
    run = await create_run(client, room_id, headers)
    await loop.tick()
    await _soft_stop(client, headers, run["id"])
    await loop.tick()
    assert not holder.cancelled, "還沒到期就殺了"

    clock["t"] += 61
    await loop.tick()

    await asyncio.wait_for(asyncio.gather(
        *[a.task for a in loop.active.values()]), timeout=10)
    assert holder.cancelled, "逾時之後沒有改為終止進程"
    assert (cfg.runs_dir / run["id"] / "soft_stop_timeout.flag").exists(), \
        "沒有留下逾時的痕跡，回報的理由會說成「有人按了取消」"


async def test_mentions_are_appended_once_for_the_hook_to_pick_up(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    """@ 落到 `inject.jsonl`，由 `PreToolUse` 交到模型面前。

    同一則**只追加一次**：重複追加的話，agent 每一次工具呼叫都會再讀到同一
    句話，而它分不出那是新的還是剛才那則。
    """
    _app, client = hub_app
    room_id, headers = ops_room
    cfg = make_config(tmp_path, work_repo)
    gate = asyncio.Event()
    holder = StubExecutor(gate)
    loop = _loop(cfg, runner_hub, executor_factory=lambda: holder)
    assert await loop.start()
    run = await create_run(client, room_id, headers)
    await loop.tick()

    joined = await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": "claude", "role": "agent",
              "session_key": f"claude-run-{run['id']}",
              "preferred_name": "派工執行者"})
    assert joined.status_code == 200, joined.text
    name = joined.json()["display_name"]
    # 第一次心跳把游標補到現況（加入之前的 @ 不補送）
    await loop.tick()
    await client.post(f"/api/rooms/{room_id}/messages",
                      json={"content": f"@{name} 先停一下", "mentions": [name]},
                      headers=headers)
    await loop.tick()

    inject = cfg.runs_dir / run["id"] / "inject.jsonl"
    lines = [ln for ln in inject.read_text(encoding="utf-8").splitlines()
             if ln.strip()]
    assert len(lines) == 1
    assert json.loads(lines[0])["text"] == f"@{name} 先停一下"

    await loop.tick()
    again = [ln for ln in inject.read_text(encoding="utf-8").splitlines()
             if ln.strip()]
    assert len(again) == 1, "同一則被轉達了第二次"

    gate.set()
    await asyncio.wait_for(asyncio.gather(
        *[a.task for a in loop.active.values()]), timeout=10)


# ── reload（執行器分頁改完設定按套用）────────────────────────────

async def test_reload_rereads_the_config_without_touching_running_runs(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    """reload：換掉設定與專案表，**手上的 run 照舊跑完**。

    改一次設定就把正在跑的 run 殺掉的話，沒有人敢在白天改設定。
    """
    app, client = hub_app
    room_id, headers = ops_room
    path = write_config(tmp_path / "config.json", tmp_path, work_repo)
    cfg = load_config(path)
    gate = asyncio.Event()
    loop = _loop(cfg, runner_hub, config_path=path,
                 executor_factory=lambda: StubExecutor(gate))
    assert await loop.start()
    await create_run(client, room_id, headers)
    await loop.tick()
    assert len(loop.active) == 1

    # 設定檔換掉：多一個專案，原本那個改成不公開
    repos = {"r": {"path": str(work_repo), "allowed_branches": ["*"]}}
    write_config(path, tmp_path, work_repo, workspaces={
        "ai-website": {"public": False, "projects": repos},
        "chatroom": {"projects": repos},
    })
    cmd = (await client.post(
        f"/api/runners/{runner_hub.identity.runner_id}/commands",
        json={"command": "reload", "room_id": room_id},
        headers=_host(headers))).json()["command"]
    await loop.heartbeat()

    assert set(loop.cfg.workspaces) == {"ai-website", "chatroom"}
    assert loop.cfg.workspace("ai-website").public is False
    assert len(loop.active) == 1, "reload 不該動到正在跑的 run"

    row = await _command_row(app, cmd["id"])
    assert row["acked_at"] is not None
    assert row["applied_at"] is not None, "生效了就要說生效"
    assert "重讀" in row["note"]

    gate.set()
    await asyncio.gather(*[a.task for a in loop.active.values()])


async def test_reload_reports_the_new_public_projects_to_the_hub(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    """公開清單是在 register 送的——reload 之後要補報一次。

    不補的話，別人的派工對話框會一直列著已經取消公開的專案，而沒有任何
    地方會說那份清單是舊的。
    """
    app, client = hub_app
    room_id, headers = ops_room
    repos = {"r": {"path": str(work_repo), "allowed_branches": ["*"]}}
    path = write_config(tmp_path / "config.json", tmp_path, work_repo,
                        workspaces={"ai-website": {"projects": repos}})
    loop = _loop(load_config(path), runner_hub, config_path=path)
    assert await loop.start()

    async def _hub_projects() -> list[str]:
        row = await (await app.state.db.execute(
            "SELECT projects FROM runner WHERE id=?",
            (runner_hub.identity.runner_id,))).fetchone()
        return json.loads(row["projects"])

    assert await _hub_projects() == ["ai-website"]

    write_config(path, tmp_path, work_repo, workspaces={
        "ai-website": {"public": False, "projects": repos},
        "chatroom": {"projects": repos},
    })
    await client.post(f"/api/runners/{runner_hub.identity.runner_id}/commands",
                      json={"command": "reload"}, headers=_host(headers))
    await loop.heartbeat()

    assert await _hub_projects() == ["chatroom"]
    assert loop.state.reregister_pending is False


async def test_a_broken_config_is_rejected_and_the_old_one_stays(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    """解析失敗**維持舊設定**，並把原因寫進命令的 note。

    套一半的設定比舊設定更難收拾，而「沒生效」要看得見——applied_at 留空
    正是那條回報鏈存在的理由。
    """
    app, client = hub_app
    room_id, headers = ops_room
    path = write_config(tmp_path / "config.json", tmp_path, work_repo)
    loop = _loop(load_config(path), runner_hub, config_path=path)
    assert await loop.start()
    before = loop.cfg

    path.write_text("{ 這不是 JSON", encoding="utf-8")
    cmd = (await client.post(
        f"/api/runners/{runner_hub.identity.runner_id}/commands",
        json={"command": "reload"}, headers=_host(headers))).json()["command"]
    await loop.heartbeat()

    assert loop.cfg is before, "重讀失敗還換掉設定＝把執行器弄啞"
    row = await _command_row(app, cmd["id"])
    assert row["acked_at"] is not None
    assert row["applied_at"] is None
    assert "維持舊設定" in row["note"]


async def test_only_public_projects_are_registered(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    """啟動時報給 Hub 的清單就只有公開的那些。"""
    app, _client = hub_app
    repos = {"r": {"path": str(work_repo), "allowed_branches": ["*"]}}
    cfg = make_config(tmp_path, work_repo, workspaces={
        "open": {"projects": repos},
        "secret": {"public": False, "projects": repos},
    })
    loop = _loop(cfg, runner_hub)
    assert await loop.start()
    row = await (await app.state.db.execute(
        "SELECT projects FROM runner WHERE id=?",
        (runner_hub.identity.runner_id,))).fetchone()
    assert json.loads(row["projects"]) == ["open"]
def _spy_uplink(loop) -> tuple[list[dict], list[dict]]:
    """側錄送給 Hub 的清單。

    不看 Hub 的 DB：`private_projects` 那一欄是 Hub 那邊同時在做的事，
    執行器送了什麼跟 Hub 存不存得下來是兩件事，這裡只驗前者。
    """
    registers: list[dict] = []
    beats: list[dict] = []
    real_register = loop.hub.register
    real_heartbeat = loop.hub.heartbeat

    async def register(host, label, projects, max_parallel, version,
                       private_projects=None):
        registers.append({"projects": list(projects),
                          "private_projects": list(private_projects or [])})
        return await real_register(host, label, projects, max_parallel,
                                   version,
                                   private_projects=private_projects)

    async def heartbeat(*args, private_projects=None, **kw):
        beats.append({"private_projects": list(private_projects or [])})
        return await real_heartbeat(*args, private_projects=private_projects,
                                    **kw)

    loop.hub.register = register
    loop.hub.heartbeat = heartbeat
    return registers, beats


async def test_private_projects_are_reported_on_their_own_list(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    """沒標公開的工作區進 `private_projects`，**不進 `projects`**。

    兩份清單互斥：混進 `projects` 的話，公開房的派工對話框就列得出私人
    工作區，而那一步在 Hub 看起來是一筆再正常不過的派工。
    """
    app, _client = hub_app
    repos = {"r": {"path": str(work_repo), "allowed_branches": ["*"]}}
    cfg = make_config(tmp_path, work_repo, workspaces={
        "open": {"projects": repos},
        "secret": {"public": False, "projects": repos},
    })
    loop = _loop(cfg, runner_hub)
    registers, beats = _spy_uplink(loop)
    assert await loop.start()

    assert registers[0] == {"projects": ["open"],
                            "private_projects": ["secret"]}
    assert beats and beats[0]["private_projects"] == ["secret"], (
        "心跳也要帶私人清單")
    row = await (await app.state.db.execute(
        "SELECT projects FROM runner WHERE id=?",
        (runner_hub.identity.runner_id,))).fetchone()
    assert json.loads(row["projects"]) == ["open"]


async def test_reload_reports_both_lists_again(
        hub_app, ops_room, runner_hub, work_repo, tmp_path):
    """reload 之後兩份清單一起補報——一邊新一邊舊比兩邊都舊更難看出來。"""
    _app, client = hub_app
    _room_id, headers = ops_room
    repos = {"r": {"path": str(work_repo), "allowed_branches": ["*"]}}
    path = write_config(tmp_path / "config.json", tmp_path, work_repo,
                        workspaces={"ai-website": {"projects": repos}})
    loop = _loop(load_config(path), runner_hub, config_path=path)
    registers, beats = _spy_uplink(loop)
    assert await loop.start()
    assert registers[0] == {"projects": ["ai-website"],
                            "private_projects": []}

    write_config(path, tmp_path, work_repo, workspaces={
        "ai-website": {"public": False, "projects": repos},
        "chatroom": {"projects": repos},
    })
    await client.post(f"/api/runners/{runner_hub.identity.runner_id}/commands",
                      json={"command": "reload"}, headers=_host(headers))
    await loop.heartbeat()

    assert registers[-1] == {"projects": ["chatroom"],
                             "private_projects": ["ai-website"]}
    assert loop.state.reregister_pending is False
    await loop.heartbeat()
    assert beats[-1]["private_projects"] == ["ai-website"]
