"""執行器主迴圈（REMOTE-OPS-PLAN §5.1／§5.7）。

```
啟動自檢 → register → 迴圈：heartbeat（帶儀表板）→ 處理命令 → 處理取消
        → 有空位且沒被停收 → claim → 起 run → 回到 heartbeat
```

幾條刻意的選擇：

- **自檢沒過就不領單**，狀態報 ``offline`` 並把原因寫進儀表板。一台 claude
  叫不起來、或 repo 停在不允許分支的執行器，領到單只會製造一串 failed。
- **停收就是停收**：paused／limited 一律不 claim。Hub 那端也會擋，但兩端都擋
  才不會因為某一端漏掉而整晚燒額度。
- **本地也守 ``max_parallel``**：Hub 的那道用的是我們上次 heartbeat 回報的
  數字，最多晚一個心跳；真正知道現在跑幾個的是這裡。
- 維護窗與 restart 命令都用**退出碼 75** 收工，由排程工作把進程重新拉起來。
  自己 re-exec 的話，壞掉的那一次就沒有人重試了。
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Awaitable, Callable

from . import dashboard, gitops
from .config import RunnerConfig
from .hub import HubError, save_identity
from .procs import no_window_kwargs
from .run import (MCP_LIST_TIMEOUT_SECONDS, REPORT_FAILED_NAME, RepoLocks,
                  RunExecutor, parse_mcp_list, remember_claude_ai_servers)
from .usage import UsageStore

log = logging.getLogger(__name__)

# 排程工作看到這個碼就把執行器重新拉起來（維護窗／restart 命令）
EXIT_RESTART = 75
EXIT_OK = 0
EXIT_SELFCHECK_FAILED = 1


@dataclass
class ActiveRun:
    run: dict
    task: asyncio.Task
    cancel: asyncio.Event
    executor: RunExecutor
    started_at: str
    repo: str = ""
    # 停滯標記。`stall_marks`／`resume_marks` 是**次數**，不是布林：
    # 「只報一次」這件事要驗得出來，計數器才看得到重複
    stalled: bool = False
    stalled_seconds: int = 0
    stall_marks: int = 0
    resume_marks: int = 0

    def view(self) -> dashboard.RunView:
        return dashboard.RunView(
            run_id=self.run["id"], kind=self.run.get("kind", ""),
            ref=self.run.get("ref", ""), project=self.run.get("project", ""),
            repo=self.repo, started_at=self.started_at,
            turns=self.executor.turns,
            context_tokens=self.executor.context_peak,
            stalled_seconds=self.stalled_seconds)


@dataclass
class LoopState:
    status: str = "online"
    limit_reason: str = ""
    limited_until: str | None = None
    restart_pending: bool = False
    restart_reason: str = ""
    draining: bool = False
    selfcheck_problems: list[str] = field(default_factory=list)
    last_maintenance_day: str = ""


class RunnerLoop:
    def __init__(self, cfg: RunnerConfig, hub, usage_store: UsageStore | None
                 = None, executor_factory: Callable[[], RunExecutor] | None
                 = None, sleep: Callable[[float], Awaitable[None]] | None
                 = None, now: Callable[[], datetime] | None = None,
                 monotonic: Callable[[], float] | None = None) -> None:
        self.cfg = cfg
        self.hub = hub
        self.usage = usage_store
        self.locks = RepoLocks()
        self.sleep = sleep or asyncio.sleep
        self.now = now or (lambda: datetime.now(timezone.utc).astimezone())
        self.monotonic = monotonic or time.monotonic
        self.state = LoopState()
        self.active: dict[str, ActiveRun] = {}
        self.started_at = self.now().isoformat()
        self._executor_factory = executor_factory or self._default_executor
        self._stop = False
        self.exit_code = EXIT_OK
        # 上一次 heartbeat 送出去的狀態。命令是在心跳的**回應**裡拿到的，
        # 所以套用之後 Hub 手上還是舊狀態——那一輪的 claim 會被它擋掉
        self._sent_status = ""

    def _default_executor(self) -> RunExecutor:
        return RunExecutor(self.cfg, self.hub, usage_store=self.usage,
                           locks=self.locks, sleep=self.sleep,
                           on_runner_limited=self.mark_limited,
                           monotonic=self.monotonic)

    # ---------- 自檢（§5.7）----------

    async def selfcheck(self) -> list[str]:
        problems: list[str] = []
        problems += await self._check_claude()
        if self.cfg.require_gpg:
            problems += await self._check_gpg()
        problems += await self._check_repos()
        await self._probe_claude_ai_connectors()
        return problems

    async def _probe_claude_ai_connectors(self) -> None:
        """在執行器的設定目錄下跑一次 `claude mcp list`，把實際看到的
        claude.ai 連接器併進封鎖名單（`run.KNOWN_CLAUDE_AI_SERVERS` 只是保底）。

        **探不到不算自檢失敗**：保底名單仍然會產生 deny，這裡只是讓新長出來
        的連接器也被擋。連不上的連接器一個要等 30 秒健康檢查，所以逾時很常
        見——那時只留一句 warning，不要拿它擋住整台執行器領單。
        """
        argv = list(self.cfg.claude_bin) + ["mcp", "list"]
        env = dict(os.environ)
        env["CLAUDE_CONFIG_DIR"] = str(self.cfg.claude_config_dir)
        try:
            proc = await asyncio.create_subprocess_exec(
                *argv, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE, env=env, **no_window_kwargs())
        except (OSError, ValueError) as exc:
            log.warning("claude mcp list 叫不起來（%s）：%s；"
                        "連接器封鎖只用保底名單", argv[0], exc)
            return
        try:
            out, _ = await asyncio.wait_for(
                proc.communicate(), timeout=MCP_LIST_TIMEOUT_SECONDS)
        except asyncio.TimeoutError:
            proc.kill()
            log.warning("claude mcp list 逾時（%s 秒）；"
                        "連接器封鎖只用保底名單", MCP_LIST_TIMEOUT_SECONDS)
            return
        servers = parse_mcp_list(out.decode("utf-8", "replace"))
        remember_claude_ai_servers(servers)
        log.info("claude mcp list 探到 %d 個 claude.ai 連接器", len(servers))

    async def _check_claude(self) -> list[str]:
        argv = list(self.cfg.claude_bin) + ["--version"]
        try:
            proc = await asyncio.create_subprocess_exec(
                *argv, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE, **no_window_kwargs())
        except (OSError, ValueError) as exc:
            return [f"claude 叫不起來（{argv[0]}）：{exc}"]
        try:
            out, err = await asyncio.wait_for(proc.communicate(), timeout=60)
        except asyncio.TimeoutError:  # pragma: no cover
            proc.kill()
            return ["claude --version 逾時"]
        if proc.returncode != 0:
            return [f"claude --version 失敗："
                    f"{(err or out).decode('utf-8', 'replace').strip()[:200]}"]
        return []

    async def _gpg_program(self) -> str:
        """挑一支 gpg。**跟 git 同源**，因為要驗的就是「commit 簽不簽得起來」。

        排程工作拿到的 PATH 跟互動 shell 不一樣（2026-09-17：PATH 上根本
        沒有 gpg，自檢每次都 `[WinError 2]`，而同一台機器的 commit 一直簽
        得好好的——因為 git 用的是 `gpg.program` 指的那支）。順序：
        設定檔的 `gpg_bin` → `git config --get gpg.program` → PATH 上的 `gpg`。
        """
        if self.cfg.gpg_bin:
            return self.cfg.gpg_bin
        res = await gitops.git(self.cfg.state_dir,
                               "config", "--get", "gpg.program")
        program = res.out.strip().strip('"') if res.ok else ""
        return program or "gpg"

    async def _check_gpg(self) -> list[str]:
        """簽章探針。**只驗、不代管 passphrase**（裁決 #1）。

        卡在 pinentry 就是「現在簽不了」——那時 commit 會停在同一個地方，
        而遠端沒有人能按那個視窗。
        """
        program = await self._gpg_program()
        try:
            proc = await asyncio.create_subprocess_exec(
                program, "--clearsign", "--batch", "--yes",
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE, **no_window_kwargs())
        except (OSError, ValueError) as exc:
            return [f"gpg 叫不起來（{program}）：{exc}"]
        try:
            out, err = await asyncio.wait_for(
                proc.communicate(b"chatroom-runner probe\n"), timeout=60)
        except asyncio.TimeoutError:
            proc.kill()
            return ["gpg --clearsign 逾時（多半卡在 pinentry；"
                    "遠端沒有人能按那個視窗）"]
        if proc.returncode != 0 or b"BEGIN PGP SIGNED MESSAGE" not in out:
            return [f"GPG 簽章不可用："
                    f"{err.decode('utf-8', 'replace').strip()[:200]}"]
        return []

    async def _check_repos(self) -> list[str]:
        problems: list[str] = []
        for project in self.cfg.projects.values():
            for name, repo in project.repos.items():
                if not Path(repo.path).is_dir():
                    problems.append(f"{project.key}/{name}：路徑不存在"
                                    f"（{repo.path}）")
                    continue
                res = await gitops.git(repo.path, "status", "--porcelain")
                if not res.ok:
                    problems.append(f"{project.key}/{name}：git status 失敗"
                                    f"（{res.err[:120]}）")
                    continue
                branch = await gitops.current_branch(repo.path)
                if not repo.allows(branch):
                    problems.append(
                        f"{project.key}/{name}：目前在分支「{branch}」，"
                        f"不在允許清單（{'、'.join(repo.allowed_branches)}）裡")
        return problems

    # ---------- 啟動對帳（孤兒 run）----------

    def _persist_active(self) -> None:
        """把「我手上有哪幾筆 run」立刻落地。

        🚨 **在 spawn／結束的當下就寫**，不是收工時才寫：要對帳的正是「執行器
        沒有機會收工」的那一次。進程被殺、任務炸掉、機器斷電——那時只有這個
        檔案記得曾經有一筆 run 在跑。
        """
        identity = getattr(self.hub, "identity", None)
        if identity is None:
            return
        identity.active_run_ids = sorted(self.active)
        try:
            save_identity(self.cfg.state_file, identity)
        except OSError as exc:  # pragma: no cover - 寫不進去只少了對帳
            log.warning("本機狀態檔寫不進去（%s）：%s",
                        self.cfg.state_file, exc)

    async def reconcile(self, cancel_requested: set[str] | None = None
                        ) -> list[str]:
        """收拾上一次崩潰留下的孤兒 run。

        判準是**「狀態檔記著、本機卻沒有那個進程」**。啟動時 `self.active`
        必然是空的，所以檔案裡的每一筆都算孤兒：它們的 claude 進程隨著上一個
        執行器進程一起沒了，而 Hub 那邊永遠等不到回報——面板上是一筆正在做事
        的 run，實際上沒有任何東西在動。

        🚨 **不先讀 Hub 再決定要不要報**：`GET /api/runs/{id}` 的門檻是「房內
        成員或主持人視角」，而主持人視角只認**人類**憑證（`human_token_required`，
        實測 2026-09-17），執行器的 agent token 借不到那個身分。所以這裡直接
        回報，讓 Hub 的狀態機當裁判：run 已經收場的話會回 409
        `run_bad_transition`，而 `hub.report` 把它當成「這一步已經套用過」回
        `None`——那正是我們要的語意，不是錯誤。有讀得到的環境（測試裡的
        host view）就順便查一次，省下一次沒必要的回報。

        已經有取消請求的（heartbeat 的 `cancel_requested_run_ids`）收成
        `cancelled`，其餘收成 `failed`（`runner_restarted`）：收成 failed 的話，
        稽核串會說「執行器把它做壞了」，而事實是人類要它停。
        """
        identity = getattr(self.hub, "identity", None)
        stale = list(getattr(identity, "active_run_ids", []) or [])
        cancelled_ids = set(cancel_requested or ())
        recovered: list[str] = []
        for run_id in stale:
            if run_id in self.active:
                continue
            run = None
            try:
                run = await self.hub.get_run(run_id)
            except HubError as exc:
                log.warning("對帳：run %s 查不到現況（%s）；改用直接回報",
                            run_id, exc)
            if run is not None:
                if run.get("status") not in ("claimed", "running", "limited"):
                    continue
                if (run.get("runner_id")
                        and run["runner_id"] != identity.runner_id):
                    continue
                if run.get("cancel_requested"):
                    cancelled_ids.add(run_id)
            cancelled = run_id in cancelled_ids
            status = "cancelled" if cancelled else "failed"
            reason = "cancel_requested" if cancelled else "runner_restarted"
            try:
                applied = await self.hub.report(
                    run_id, status, reason=reason,
                    result="執行器重新啟動時發現這筆 run 沒有對應的進程"
                           "（上一個執行器進程已經不在）。它不會自己繼續，"
                           "所以在這裡收場。")
            except HubError as exc:
                log.warning("對帳：run %s 收不掉（%s）", run_id, exc)
                continue
            if applied is None:
                # 409＝Hub 那邊早就不是進行中了，沒有東西要收
                log.info("對帳：run %s 在 Hub 上已經收場了", run_id)
                continue
            log.warning("對帳：run %s 沒有對應進程，收成 %s（%s）",
                        run_id, status, reason)
            recovered.append(run_id)
        if stale:
            self._persist_active()
        return recovered

    # ---------- 生命週期 ----------

    async def start(self) -> bool:
        """自檢 → 註冊 → 對帳。回傳「可不可以開始領單」。"""
        self.state.selfcheck_problems = await self.selfcheck()
        await self.hub.register(self.cfg.host, self.cfg.label,
                                list(self.cfg.projects), self.cfg.max_parallel,
                                self.cfg.version)
        failed = bool(self.state.selfcheck_problems)
        if failed:
            # 一定要留在本機 log：問題只上報 Hub 的話，排程工作那邊看到的
            # 只有「退出碼 1」，而原因在下一次心跳就被覆蓋掉
            for problem in self.state.selfcheck_problems:
                log.error("自檢：%s", problem)
            self.state.status = "offline"
            self.state.limit_reason = "selfcheck_failed"
        else:
            self.state.status = "online"
        # 對帳要在領新單之前，而且**自檢沒過也要做**：孤兒掛在 Hub 上跟這台
        # 起不起得來無關，不收的話它會一直是一筆正在做事的 run。
        # 取消清單只有 heartbeat 拿得到，所以先敲一次心跳再對帳
        reply = await self.heartbeat()
        await self.reconcile(
            {str(x) for x in reply.get("cancel_requested_run_ids", [])})
        return not failed

    def mark_limited(self, reason: str) -> None:
        """撞到額度：停收新單。``weekly_limit`` 要等人類解除（§5.3）。"""
        self.state.status = "limited"
        self.state.limit_reason = reason

    # ---------- 心跳與命令 ----------

    async def _flush_failed_reports(self) -> None:
        """把送不出去、落地在 run 目錄的回報再送一次（審查 09/16）。

        送成功才刪檔：刪了又沒送到的話，那筆 run 的結果就真的不見了。
        """
        runs_dir = self.cfg.runs_dir
        if not runs_dir.is_dir():
            return
        for path in sorted(runs_dir.glob(f"*/{REPORT_FAILED_NAME}")):
            try:
                payload = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                log.warning("落地的回報讀不回來（%s）：%s", path, exc)
                continue
            run_id = str(payload.get("run_id") or path.parent.name)
            try:
                await self.hub.report(
                    run_id, str(payload.get("status") or ""),
                    result=str(payload.get("result") or ""),
                    reason=str(payload.get("reason") or ""),
                    claude_session_id=str(payload.get("claude_session_id")
                                          or ""),
                    usage=payload.get("usage") or None)
            except HubError as exc:
                log.warning("run %s 的落地回報重送失敗：%s", run_id, exc)
                continue
            log.info("run %s 的落地回報已補送", run_id)
            try:
                path.unlink()
            except OSError:  # pragma: no cover
                pass

    def check_stalls(self) -> None:
        """進行中的 run 多久沒說話。**每次心跳看一眼，狀態轉換各記一次。**

        🚨 **不對 Hub `report`**：Hub 的狀態機（`app._RUN_TRANSITIONS`）沒有
        `running → running`，同狀態回報會被 409 `run_bad_transition` 擋掉，
        而那個 code 在 `hub.report` 裡被當成「這一步已經套用過」安靜吞掉——
        打了等於什麼都沒發生，只是每個心跳多一次往返。停滯目前**只走
        `dashboard_json`**（App 讀得到），要讓它進訊息流得等 Hub 那端允許
        帶 `reason` 的同狀態回報。

        不殺進程：牆鐘上限照舊管終止，這裡只負責讓遠端的人看得見。
        """
        threshold = self.cfg.stall_warn_seconds
        if threshold <= 0:
            return
        now = self.monotonic()
        for run_id, active in self.active.items():
            idle = now - active.executor.last_event_at
            if idle >= threshold:
                active.stalled_seconds = int(idle)
                if not active.stalled:
                    active.stalled = True
                    active.stall_marks += 1
                    log.warning("run %s 已經 %d 秒沒有任何 stream 事件"
                                "（門檻 %s 秒）；不殺進程，只標記",
                                run_id, active.stalled_seconds, int(threshold))
            elif active.stalled:
                active.stalled = False
                active.stalled_seconds = 0
                active.resume_marks += 1
                log.info("run %s 又開始吐事件了", run_id)

    async def heartbeat(self) -> dict:
        await self._flush_failed_reports()
        self.check_stalls()
        usage_window =(self.usage.window(self.cfg.usage_window_hours,
                                          self.cfg.usage_soft_cap_tokens,
                                          self.cfg.usage_soft_cap_usd)
                        if self.usage else None)
        window_dict = usage_window.to_dict() if usage_window else {}
        if (usage_window is not None and usage_window.over_soft_cap
                and self.state.status == "online"):
            self.mark_limited("usage_soft_cap")
        runtime = dashboard.RunnerRuntime(
            version=self.cfg.version, started_at=self.started_at,
            last_restart_reason=self.state.restart_reason,
            selfcheck=self.state.selfcheck_problems)
        board = await dashboard.build(
            self.cfg, window_dict, self.state.status, self.state.limited_until,
            self.state.limit_reason,
            [a.view() for a in self.active.values()], 0, runtime)
        self._sent_status = self.state.status
        try:
            reply = await self.hub.heartbeat(
                self.state.status, len(self.active), board, window_dict,
                self.state.limited_until, self.state.limit_reason) or {}
        except HubError:
            # Hub 連不上不是執行器的錯，也不該讓它自殺：下一次心跳再試。
            # 期間照樣不領單（claim 也會失敗），但手上的 run 繼續跑完
            return {}
        for cmd in reply.get("commands", []):
            self.apply_command(str(cmd.get("command") or ""))
        for run_id in reply.get("cancel_requested_run_ids", []):
            self.request_cancel(str(run_id))
        return reply

    def apply_command(self, command: str) -> None:
        """人類下的命令（§5.7）。命令是一次性的，Hub 取走時就標 acked。"""
        if command == "pause":
            self.state.status = "paused"
            self.state.limit_reason = "paused_by_human"
        elif command == "resume":
            self.state.status = "online"
            self.state.limit_reason = ""
            self.state.limited_until = None
            self.state.draining = False
        elif command == "restart":
            self.state.restart_pending = True
            self.state.restart_reason = "restart_command"
        elif command == "drain":
            # drain＝停收新單、跑完手上的，然後停在 paused 等人叫醒。
            # **不自我重啟**：drain 的語意是「我要它安靜下來」，
            # 而重啟回來的執行器會立刻開始領單
            self.state.draining = True
            self.state.status = "paused"
            self.state.limit_reason = "draining"

    def request_cancel(self, run_id: str) -> bool:
        active = self.active.get(run_id)
        if active is None:
            return False
        active.cancel.set()
        return True

    # ---------- 領單與執行 ----------

    @property
    def slots_free(self) -> int:
        return max(0, self.cfg.max_parallel - len(self.active))

    def can_claim(self) -> bool:
        return (self.state.status == "online" and not self.state.draining
                and not self.state.restart_pending and self.slots_free > 0)

    async def claim_once(self) -> dict | None:
        if not self.can_claim():
            return None
        try:
            run = await self.hub.claim()
        except HubError:
            return None
        if run is None:
            return None
        self.spawn(run)
        return run

    def spawn(self, run: dict) -> ActiveRun:
        cancel = asyncio.Event()
        executor = self._executor_factory()
        task = asyncio.ensure_future(executor.execute(run, cancel))
        active = ActiveRun(run=run, task=task, cancel=cancel,
                           executor=executor,
                           started_at=self.now().isoformat())
        self.active[run["id"]] = active
        self._persist_active()
        task.add_done_callback(lambda t, rid=run["id"]: self._finish(rid, t))
        return active

    def _finish(self, run_id: str, task: asyncio.Task | None = None) -> None:
        """🚨 一定要取 ``task.exception()``（審查 09/16）。

        不取的話，executor 自己炸掉的例外會被吃掉：那筆 run 從 active 消失、
        房裡停在 running，而本機一行紀錄都沒有。
        """
        self.active.pop(run_id, None)
        self._persist_active()
        if task is None or task.cancelled():
            return
        exc = task.exception()
        if exc is not None:
            log.error("run %s 的執行 task 以例外結束", run_id, exc_info=exc)

    # ---------- 維護窗 ----------

    def maintenance_due(self) -> bool:
        """到點、沒有 run 在跑、今天還沒做過。有 run 就順延到下一次心跳。

        🚨 ``draining``／``paused`` 時**不重啟**（審查 09/16）：那兩個狀態的
        語意都是「我要它安靜下來」，而重啟回來的執行器會立刻開始領單。
        """
        now = self.now()
        if now.hour != self.cfg.maintenance_hour or self.active:
            return False
        if self.state.draining or self.state.status == "paused":
            return False
        return self.state.last_maintenance_day != now.date().isoformat()

    # ---------- 一輪 ----------

    async def tick(self) -> None:
        await self.heartbeat()
        if self.state.status != self._sent_status:
            # 命令改了狀態就**立刻再報一次**：resume 之後 Hub 手上還寫著
            # paused，而它對 paused 的執行器一律回 204——人按了恢復，
            # 畫面上卻要再等一個心跳才動
            await self.heartbeat()
        if self.state.restart_pending and not self.active:
            self._request_exit(EXIT_RESTART, self.state.restart_reason
                               or "restart_command")
            return
        if self.maintenance_due():
            self.state.last_maintenance_day = self.now().date().isoformat()
            self._request_exit(EXIT_RESTART, "maintenance_window")
            return
        while self.can_claim():
            if await self.claim_once() is None:
                break

    def _request_exit(self, code: int, reason: str) -> None:
        self.state.restart_reason = reason
        self.exit_code = code
        self._stop = True

    async def run_forever(self, max_ticks: int | None = None) -> int:
        ok = await self.start()
        if not ok:
            # 自檢失敗就退場，讓排程工作照原本的節奏再拉一次——
            # 在這裡空轉的話，人類看到的是一台「在線但什麼都不做」的執行器
            return EXIT_SELFCHECK_FAILED
        ticks = 0
        while not self._stop:
            await self.tick()
            ticks += 1
            if max_ticks is not None and ticks >= max_ticks:
                break
            if self._stop:
                break
            await self.sleep(self.cfg.heartbeat_seconds)
        return self.exit_code

    async def shutdown(self) -> None:
        """收工：手上的 run 全部取消並等它們回報完。"""
        for active in list(self.active.values()):
            active.cancel.set()
        tasks = [a.task for a in self.active.values()]
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
