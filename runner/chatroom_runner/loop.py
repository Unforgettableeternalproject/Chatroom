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
from .config import (INJECT_FILE_NAME, SOFT_STOP_FLAG_NAME,
                     SOFT_STOP_TIMEOUT_FLAG_NAME, RunnerConfig)
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

# 退出前那一次「我要重啟了」的心跳最多等這麼久。**一定要有上限**：
# Hub 連不上的時候，退出路徑不能卡在一個 socket 上——重啟本來就是
# 排程工作在收尾，卡住的話那台執行器連退場都做不到
RESTART_HEARTBEAT_TIMEOUT = 15.0


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
    # 最後一次維護窗重啟的本地日期。開機時從 ``state.json`` 讀回來
    last_maintenance_day: str = ""
    # 收到了、但還沒生效的 restart 命令 id。**要一直帶著**：只在收到那一刻
    # ack 一次的話，Hub 上會永遠停在「等 3 筆 run 結束後重啟」，而手上其實
    # 只剩一筆了
    pending_restart_ids: list[str] = field(default_factory=list)


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
        # 還沒送出去的命令回報（§5.7）。送成功才清空：Hub 連不上的那一輪
        # 丟掉的話，那筆命令在面板上永遠停在「已送達」
        self._pending_acks: list[dict] = []
        # 正在送「命令已生效」的補心跳，避免它自己再觸發一次
        self._flushing_ack = False
        # 已經替「不在手上的 run」報過取消的 id。沒有它的話，每一次心跳都會
        # 對同一筆已經收場的 run 再報一次
        self._cancelled_orphans: set[str] = set()
        # 已經立了收尾旗標的 run → 逾時硬殺的期限（monotonic 秒）。
        # **放記憶體不落檔**：它只在「這個執行器進程手上還有那筆 run」
        # 期間有意義，進程重啟之後那個 run 已經被 `reconcile` 收掉了
        self._soft_stop_deadline: dict[str, float] = {}
        self._restore_maintenance_day()

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
        problems += self._check_skill_dirs()
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

    def _check_skill_dirs(self) -> list[str]:
        """`--add-dir` 進來的 skill 目錄要真的在。

        目錄不在時 claude 那一行參數會失效，而契約仍然叫 run 去跑那個 skill
        ——遠端只會看到一筆「照自己的想法做完」的 run，沒有任何錯誤。
        """
        problems: list[str] = []
        for project in self.cfg.projects.values():
            for d in project.skill_dirs:
                if not Path(d).is_dir():
                    problems.append(
                        f"{project.key}：skill_dirs 的「{d}」不是目錄")
        return problems

    # ---------- 啟動對帳（孤兒 run）----------

    def _persist_active(self) -> None:
        """把「我手上有哪幾筆 run」立刻落地。

        🚨 **在 spawn／結束的當下就寫**，不是收工時才寫：要對帳的正是「執行器
        沒有機會收工」的那一次。進程被殺、任務炸掉、機器斷電——那時只有這個
        檔案記得曾經有一筆 run 在跑。
        """
        self._persist_identity()

    def _persist_identity(self) -> None:
        """把本機狀態（手上的 run、維護窗日期）寫回 ``state.json``。"""
        identity = getattr(self.hub, "identity", None)
        if identity is None:
            return
        identity.active_run_ids = sorted(self.active)
        identity.last_maintenance_day = self.state.last_maintenance_day
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
                    result="執行器重新啟動後，這筆 run 沒有對應的進程，"
                           "已在此收場。")
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

    def _restore_maintenance_day(self) -> None:
        """從狀態檔接回「今天做過維護窗了沒」，並處理「一起來就在窗裡」。

        在 `__init__` 跑，不是在 `start()`：判維護窗的是 `tick`，而不是每一
        條路徑都會先經過 `start()`。

        🚨 **啟動本身就等於重啟過了**（實測 2026-09-18）：這一段少了的話，
        04:00 起在維護窗裡被排程工作拉起來的進程，會在第一輪就判「現在是
        maintenance_hour」再退一次，整個小時每 5 分鐘循環一遍。
        """
        identity = getattr(self.hub, "identity", None)
        if identity is not None:
            self.state.last_maintenance_day = getattr(
                identity, "last_maintenance_day", "") or ""
        now = self.now()
        today = now.date().isoformat()
        if (now.hour >= self.cfg.maintenance_hour
                and self.state.last_maintenance_day != today):
            # 只改記憶體，不寫檔：這一筆是「這個進程剛起來」推出來的，不是
            # 真的做過一次維護。寫下去的話，凌晨 00:30 開機的人會讓當天的
            # 維護窗整個被跳過
            self.state.last_maintenance_day = today

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

    async def check_stalls(self) -> None:
        """進行中的 run 多久沒說話。**每次心跳看一眼，狀態轉換各記一次。**

        標記與解除**各對 Hub 報一次**（`running → running` 帶
        `reason=stalled`／`resumed`，Hub 那端不轉移狀態、只留事件並在房裡
        講一句）。報的時機跟著 `stall_marks`／`resume_marks` 走：每個心跳
        都報的話，一筆卡住的 run 會把整間房洗掉，而洗掉的正是要人看的那則。

        報不出去**不影響標記**：dashboard 仍然說得出停滯（App 讀得到），
        而 Hub 的訊息流少一則比執行器的心跳整個斷掉好。

        不殺進程：牆鐘上限照舊管終止，這裡只負責讓遠端的人看得見。
        """
        threshold = self.cfg.stall_warn_seconds
        if threshold <= 0:
            return
        now = self.monotonic()
        notices: list[tuple[str, str, int]] = []
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
                    notices.append((run_id, "stalled", active.stalled_seconds))
            elif active.stalled:
                active.stalled = False
                active.stalled_seconds = 0
                active.resume_marks += 1
                log.info("run %s 又開始吐事件了", run_id)
                notices.append((run_id, "resumed", 0))
        for run_id, reason, seconds in notices:
            try:
                await self.hub.report(run_id, "running", reason=reason,
                                      stalled_seconds=seconds)
            except HubError as exc:  # pragma: no cover - 視 Hub 版本
                log.warning("停滯回報沒送成（run %s，%s）：%s",
                            run_id, reason, exc)

    async def heartbeat(self) -> dict:
        await self._flush_failed_reports()
        await self.check_stalls()
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
        acks = self._collect_acks()
        try:
            reply = await self.hub.heartbeat(
                self.state.status, len(self.active), board, window_dict,
                self.state.limited_until, self.state.limit_reason,
                command_acks=acks) or {}
        except HubError:
            # Hub 連不上不是執行器的錯，也不該讓它自殺：下一次心跳再試。
            # 期間照樣不領單（claim 也會失敗），但手上的 run 繼續跑完。
            # `_pending_acks` **不清**：這一輪沒送到，下一輪要再送一次
            return {}
        self._pending_acks = []
        fresh = False
        for cmd in reply.get("commands", []):
            cmd_id = str(cmd.get("id") or "")
            applied, note = self.apply_command(
                str(cmd.get("command") or ""), cmd_id)
            if not cmd_id or not note:
                continue
            self._pending_acks.append(
                {"id": cmd_id,
                 "applied_at": self.now().isoformat() if applied else None,
                 "note": note})
            fresh = True
        for run_id in reply.get("cancel_requested_run_ids", []):
            await self._apply_cancel(str(run_id))
        for run_id in reply.get("soft_stop_requested_run_ids", []):
            self._apply_soft_stop(str(run_id))
        self._deliver_mentions(reply.get("pending_mentions") or {})
        self._check_soft_stop_timeouts()
        if fresh and not self._flushing_ack:
            # 收到命令就**立刻再報一次**：等下一次心跳的話，人按完鈕要盯著
            # 一個沒有變化的面板 30 秒，而那 30 秒裡唯一合理的推論是「壞了」
            self._flushing_ack = True
            try:
                await self.heartbeat()
            finally:
                self._flushing_ack = False
        return reply

    def _restart_wait_note(self) -> str:
        return f"等 {len(self.active)} 筆 run 結束後重啟"

    def _collect_acks(self) -> list[dict]:
        """這一次心跳要帶的命令回報。

        等待中的 restart **每一輪都重帶一次**，note 裡的筆數跟著手上的 run
        變少——只 ack 一次的話，面板會一直說「等 3 筆」，而人會以為它卡住了。
        """
        acks = list(self._pending_acks)
        seen = {a["id"] for a in acks}
        for cmd_id in self.state.pending_restart_ids:
            if cmd_id in seen:
                continue
            acks.append({"id": cmd_id, "applied_at": None,
                         "note": self._restart_wait_note()})
        return acks

    def apply_command(self, command: str,
                      command_id: str = "") -> tuple[bool, str]:
        """人類下的命令（§5.7）。命令是一次性的，Hub 取走時就標 acked。

        回傳 ``(生效了沒, 給人看的一句話)``：這兩個值會在下一次心跳寫回
        Hub 的 `runner_command`。restart **收到時一律不算生效**——真正生效
        是在手上的 run 清空、進程要退出的那一刻（見 `_restarting_heartbeat`）。
        """
        if command == "pause":
            self.state.status = "paused"
            self.state.limit_reason = "paused_by_human"
            return True, "已暫停"
        if command == "resume":
            self.state.status = "online"
            self.state.limit_reason = ""
            self.state.limited_until = None
            self.state.draining = False
            return True, "已恢復"
        if command == "restart":
            self.state.restart_pending = True
            self.state.restart_reason = "restart_command"
            if command_id and command_id not in self.state.pending_restart_ids:
                self.state.pending_restart_ids.append(command_id)
            return False, self._restart_wait_note()
        if command == "drain":
            # drain＝停收新單、跑完手上的，然後停在 paused 等人叫醒。
            # **不自我重啟**：drain 的語意是「我要它安靜下來」，
            # 而重啟回來的執行器會立刻開始領單
            self.state.draining = True
            self.state.status = "paused"
            self.state.limit_reason = "draining"
            return True, f"停收新單，跑完手上 {len(self.active)} 筆後暫停"
        return False, ""

    def run_dir(self, run_id: str) -> Path:
        return self.cfg.runs_dir / run_id

    def _apply_soft_stop(self, run_id: str) -> None:
        """收尾請求：在 run 目錄立旗標，下一次工具呼叫由 `PreToolUse` 擋下。

        **手上沒有那個進程就什麼都不做**：沒有進程會去讀那個旗標，立了只是
        在硬碟上留一個沒有人看的檔。那種 run 由取消那條路收場。

        已經立過的不重立，也不重新起算逾時——重按一次收尾不該把硬殺的時限
        往後推，那正是人第二次按的時候最不想要的效果。
        """
        if run_id not in self.active or run_id in self._soft_stop_deadline:
            return
        run_dir = self.run_dir(run_id)
        try:
            run_dir.mkdir(parents=True, exist_ok=True)
            (run_dir / SOFT_STOP_FLAG_NAME).write_text(
                json.dumps({"requested_at": self.now().isoformat()},
                           ensure_ascii=False), encoding="utf-8")
        except OSError as exc:
            log.warning("收尾旗標寫不進去（run %s）：%s", run_id, exc)
            return
        self._soft_stop_deadline[run_id] = (self.monotonic()
                                            + self.cfg.soft_stop_timeout)
        log.info("run %s 收到收尾請求，%.0f 秒後仍未結束就硬殺",
                 run_id, self.cfg.soft_stop_timeout)

    def _check_soft_stop_timeouts(self) -> None:
        """收尾請求逾時 → 走既有的取消路徑硬殺。

        沒有這一步的話，一個**已經不再呼叫工具**的 run（旗標永遠沒有機會被
        讀到）會把那個併發位置佔到牆鐘上限為止，而房裡的人以為它在收尾。
        """
        now = self.monotonic()
        for run_id, deadline in list(self._soft_stop_deadline.items()):
            if run_id not in self.active:
                self._soft_stop_deadline.pop(run_id, None)
                continue
            if now < deadline:
                continue
            self._soft_stop_deadline.pop(run_id, None)
            try:
                (self.run_dir(run_id) / SOFT_STOP_TIMEOUT_FLAG_NAME
                 ).write_text("", encoding="utf-8")
            except OSError:  # pragma: no cover - 只影響回報的理由
                pass
            log.warning("run %s 收尾逾時，改為終止進程", run_id)
            self.request_cancel(run_id)

    def _deliver_mentions(self, mapping) -> None:
        """房裡 @ 這筆 run 的訊息 → 追加到 run 目錄的 ``inject.jsonl``。

        Hub 已經保證同一則只送一次（`mention_cursor_seq`），所以這裡只管
        追加；真正把它交到模型面前的是 `PreToolUse` hook。
        """
        if not isinstance(mapping, dict):
            return
        for raw_id, items in mapping.items():
            run_id = str(raw_id)
            if run_id not in self.active or not items:
                continue
            run_dir = self.run_dir(run_id)
            try:
                run_dir.mkdir(parents=True, exist_ok=True)
                with (run_dir / INJECT_FILE_NAME).open(
                        "a", encoding="utf-8") as fh:
                    for item in items:
                        fh.write(json.dumps(
                            {"seq": item.get("seq"),
                             "from": item.get("from", ""),
                             "text": item.get("text", "")},
                            ensure_ascii=False) + "\n")
            except OSError as exc:
                log.warning("@ 轉達寫不進去（run %s）：%s", run_id, exc)

    def request_cancel(self, run_id: str) -> bool:
        active = self.active.get(run_id)
        if active is None:
            return False
        active.cancel.set()
        return True

    async def _apply_cancel(self, run_id: str) -> None:
        """套用一筆取消請求。**手上沒有那個進程也要收場**（實機 2026-09-18）。

        只對 `self.active` 動作的話，上一個執行器進程留下的 run 會永遠停在
        `claimed`＋`cancel_requested=1`：人按了取消，而 Hub 那端永遠等不到
        回報——正式 Hub 上有一筆從 09-17 掛到隔天。這裡直接回報，讓 Hub 的
        狀態機當裁判（已經收場的回 409，`hub.report` 當成「這一步套用過」
        回 `None`）。

        送不出去就**不記進 set**：下一次心跳再試一次。
        """
        if self.request_cancel(run_id):
            return
        if run_id in self._cancelled_orphans:
            return
        self._cancelled_orphans.add(run_id)
        try:
            await self.hub.report(
                run_id, "cancelled", reason="cancel_requested",
                result="執行器手上沒有這筆 run 的進程，依取消請求收場。")
        except HubError as exc:
            self._cancelled_orphans.discard(run_id)
            log.warning("取消請求收不掉（run %s）：%s", run_id, exc)
            return
        log.warning("run %s 不在手上，依取消請求直接收場", run_id)

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
        """一天一次：過了點、沒有 run 在跑、今天還沒做過。

        比的是 ``>= maintenance_hour`` 而不是 ``== maintenance_hour``：整點
        那一小時剛好在跑 run（或剛好是 paused）就順延，不會因為錯過那一個
        小時就整天不重啟。「今天做過沒」存在 ``state.json``，跨進程有效。

        🚨 ``draining``／``paused`` 時**不重啟**（審查 09/16）：那兩個狀態的
        語意都是「我要它安靜下來」，而重啟回來的執行器會立刻開始領單。
        """
        now = self.now()
        if now.hour < self.cfg.maintenance_hour or self.active:
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
            await self._restarting_heartbeat()
            self._request_exit(EXIT_RESTART, self.state.restart_reason
                               or "restart_command")
            return
        if self.maintenance_due():
            self.state.last_maintenance_day = self.now().date().isoformat()
            # 退出前一定要落地：只寫記憶體的話，重啟回來的進程還在窗裡，
            # 會立刻再退一次
            self._persist_identity()
            await self._restarting_heartbeat()
            self._request_exit(EXIT_RESTART, "maintenance_window")
            return
        while self.can_claim():
            if await self.claim_once() is None:
                break

    async def _restarting_heartbeat(self) -> None:
        """退出前的最後一次心跳：狀態 ``restarting``，restart 命令標生效。

        沒有這一次的話，進程退出後 Hub 手上還寫著 online，要等
        `runner_offline_after`（180 秒）掃到才變 offline——而重啟只要 1～2
        分鐘，人從頭到尾看不到任何「正在重啟」。

        **送不出去也要退**：整段包在 `wait_for` 裡，Hub 連不上時逾時就走。
        退出路徑卡在一個 socket 上的話，這台執行器連退場都做不到。
        """
        now = self.now().isoformat()
        for cmd_id in self.state.pending_restart_ids:
            self._pending_acks.append(
                {"id": cmd_id, "applied_at": now,
                 "note": "正在重啟，預計 1～2 分鐘完成"})
        self.state.pending_restart_ids = []
        self.state.status = "restarting"
        # 這一次不要再因為回應裡的新命令去補一次心跳：下一秒就退出了
        self._flushing_ack = True
        try:
            await asyncio.wait_for(self.heartbeat(),
                                   RESTART_HEARTBEAT_TIMEOUT)
        except asyncio.TimeoutError:
            log.warning("送不出「正在重啟」的心跳（逾時），照樣退出")
        except Exception:  # pragma: no cover - 退出路徑不因任何例外卡住
            log.warning("送不出「正在重啟」的心跳，照樣退出", exc_info=True)
        finally:
            self._flushing_ack = False

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
