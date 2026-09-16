"""主迴圈（REMOTE-OPS-PLAN §5.1／§5.7）。

用 stub executor 跑：這一層要驗的是「什麼時候領單、什麼時候停收、命令與取消
有沒有接上」，不是子進程怎麼跑（那在 `test_run.py`）。
"""

from __future__ import annotations

import asyncio
from datetime import datetime, timezone

import pytest

from chatroom_runner.loop import (EXIT_RESTART, EXIT_SELFCHECK_FAILED,
                                  RunnerLoop)

from ._fixtures import create_run, make_config


class StubExecutor:
    """假的執行器：不起進程，只記下拿到什麼、等到被放行才結束。"""

    seen: list[dict] = []

    def __init__(self, gate: asyncio.Event | None = None) -> None:
        self.gate = gate
        self.turns = 0
        self.context_peak = 0
        self.cancelled = False

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
def _clear_seen():
    StubExecutor.seen = []
    yield
    StubExecutor.seen = []


def _loop(cfg, hub, **kw):
    kw.setdefault("executor_factory", lambda: StubExecutor())
    return RunnerLoop(cfg, hub, **kw)


async def _register(loop):
    await loop.hub.register(loop.cfg.host, loop.cfg.label,
                            list(loop.cfg.projects), loop.cfg.max_parallel,
                            loop.cfg.version)


# ── 自檢 ────────────────────────────────────────────────────────

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
                          headers=headers)
    assert r.status_code == 200, r.text
    await loop.tick()
    assert loop.state.status == "paused"
    assert StubExecutor.seen == [], "暫停中還在領單"

    await client.post(f"/api/runners/{runner_id}/commands",
                      json={"command": "resume"}, headers=headers)
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
                      json={"command": "drain"}, headers=headers)

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
                      json={"command": "restart"}, headers=headers)
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
                      json={"command": "pause"}, headers=headers)
    first = await loop.heartbeat()
    second = await loop.heartbeat()
    assert [c["command"] for c in first["commands"]] == ["pause"]
    assert second["commands"] == []


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
    clock = [datetime(2026, 9, 16, 11, 0, tzinfo=timezone.utc)]
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


async def test_maintenance_does_not_fire_outside_the_window(
        hub_app, runner_hub, work_repo, tmp_path):
    cfg = make_config(tmp_path, work_repo, maintenance_hour=4)
    loop = _loop(cfg, runner_hub,
                 now=lambda: datetime(2026, 9, 16, 11, 0, tzinfo=timezone.utc))
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
