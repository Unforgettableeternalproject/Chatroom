"""一筆 run 的執行（REMOTE-OPS-PLAN §5.2～§5.6）。

這個模組決定「一筆單怎麼變成一個子進程，以及它結束時算成功還是失敗」。
幾條不變式，每一條都對應一個安靜的失敗：

- **成敗看 exit code 與 ``is_error``，不是只看 ``subtype``**（實測 2.1.273：
  未登入時 ``subtype`` 照樣是 ``success``）。
- **同一個 repo 同時只允許一個寫入型 run**（investigate 不算）：兩個 agent 動
  同一份工作樹會互相覆蓋，遠端無人看著時代價更高。
- **工作樹守衛**：run 前後各拍一張 `git status --porcelain` + HEAD，差異寫進
  result。不自動 stash、不自動還原——那會把人類唯一能看到的線索抹掉。
- **push 不經模型**：push 沒有需要判斷的事，經模型只是多一個出錯的地方。
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Awaitable, Callable

from . import gitops, prompts
from .config import ProjectConfig, RepoConfig, RunnerConfig
from .guard import TOOL_MATCHER, GuardContext
from .hub import HubError
from .procs import no_window_kwargs
from .stream import StreamWatcher

log = logging.getLogger(__name__)

HOOKS_DIR = Path(__file__).resolve().parent / "hooks"
# 永遠 exit 1 的 askpass：git 問不到密碼就直接失敗，不會停在那裡等人
ASKPASS_SCRIPT = HOOKS_DIR / ("askpass-deny.cmd" if os.name == "nt"
                              else "askpass-deny.sh")
# push run 用的憑證 helper（艾斯維爾裁決 09/16：推送憑證隔離）。
# 一般 run 的環境把 helper 清單清空，只有 push run 明確把它加回來
PUSH_CREDENTIAL_HELPER = "manager"
# run 進程一律是 claude 執行器；bridge 沒拿到這個鍵會落回 other
AGENT_KIND = "claude"
# 回報的重試（審查 09/16）。三次嘗試、兩段退避；還是送不出去就落地
REPORT_ATTEMPTS = 3
REPORT_BACKOFF_SECONDS = (2, 5)
REPORT_FAILED_NAME = "report_failed.json"
# run 目錄底下放 chatroom 附件的資料夾。**不落在 repo 裡**：實測附件會掉進
# cwd 的 `.chatroom/downloads/`，把人類的工作樹弄髒，而那些檔案跟這次改動
# 一點關係也沒有。跟著 run 目錄留著，事後還查得到
DOWNLOADS_DIR_NAME = "downloads"
# stream-json 的單行上限。asyncio 的 StreamReader 預設只有 64 KiB，而一行
# `tool_result` 只要含一張圖的 base64 就會超過——實測 2026-09-17：模型 Read
# 了一張 141 KB 的 PNG，`readline()` 丟 `ValueError: Separator is not found,
# and chunk exceed the limit`，pump 整個炸掉、執行任務跟著死，claude 進程沒了
# 而 Hub 上那筆 run 永遠停在 running。放大到 64 MiB：一行事件再大也是記憶體
# 裡的一份字串，比「一筆 run 從此無人收屍」便宜太多
STREAM_LINE_LIMIT = 64 * 1024 * 1024
# 會寫檔的 kind。investigate 只讀，不必排隊等 repo 鎖
WRITE_KINDS = {"ticket", "stage", "push"}

# `--allowedTools` 的預授權清單。
#
# 🚨 實測（run 9ee0fd48 的 stream.jsonl）：只給 `--permission-mode auto` **不夠**。
# agent 呼叫 `mcp__chatroom__chatroom_join` 時 CLI 回
# 「Claude requested permissions to use mcp__chatroom__chatroom_join, but you
# haven't granted it yet.」——`auto` 不會自動放行 MCP 工具，而 headless 這邊
# 沒有人能按那個「允許」，整筆 run 就以「沒有權限」收工。
#
# 這裡放行的只是「不要停在權限提示」。真正的硬限制仍然在 PreToolUse hook
# （見 guard.py）：hook 先於權限判定跑，被 deny 的指令不會因為列在這裡就通過。
BASE_ALLOWED_TOOLS = (
    "ToolSearch", "Read", "Glob", "Grep", "Bash", "PowerShell",
    "mcp__chatroom__*",
)
# 只有會寫東西的 kind 才給編輯工具；`investigate` 是唯讀的
WRITE_ALLOWED_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit")


def allowed_tools(kind: str, extra: list[str] | None = None) -> list[str]:
    """這筆 run 要預先授權哪些工具。順序穩定，方便測試與 log 比對。"""
    tools = list(BASE_ALLOWED_TOOLS)
    if kind in WRITE_KINDS:
        tools += list(WRITE_ALLOWED_TOOLS)
    for name in extra or []:
        if name and name not in tools:
            tools.append(name)
    return tools


# ---------- claude.ai 連接器的封鎖（預設拒絕）----------
#
# 問題：執行器用自己的 `CLAUDE_CONFIG_DIR` 起 claude，但**帳號層級的
# claude.ai 連接器是跟著登入進來的**，不在 `--mcp-config` 裡。實測
# 2026-09-17，在執行器的設定目錄下 `claude mcp list` 列出 Claude Docs、
# Microsoft 365、Adobe、Hugging Face、Postman、Google Calendar、Gmail、
# Canva、Notion、Cloudflare、Atlassian Rovo、Google Drive 共 12 個。
# 一筆 run 只該碰 chatroom（加設定檔明列的例外），其他都是多出來的攻擊面。
#
# 查證（code.claude.com/docs，2026-09-17）：
#
# - `--strict-mcp-config`「只用 --mcp-config 的伺服器」**擋不到連接器**。
#   docs/en/mcp：連接器是 Claude Code 自己去 claude.ai 抓的，不經
#   `--mcp-config`，所以這面旗子對它們沒有作用。
# - `disableClaudeAiConnectors: true`（docs/en/mcp#disable-claude-ai-connectors，
#   等價環境變數 `ENABLE_CLAUDEAI_MCP_SERVERS=false`）是全有全無——會連
#   設定檔想留的 Atlassian 一起關掉，所以這裡不用它。
# - **`deniedMcpServers` 才是真正有效的那一條**（docs/en/managed-mcp
#   #policy-based-control-with-allowlists-and-denylists）：「Denylists merge
#   from every scope regardless.」——不限管理者設定，`--settings` 這個 scope
#   也吃。條目是 `{"serverUrl": ...}`（可帶 `*`）或 `{"serverName": ...}`
#   （deny 清單的 serverName 接受任意字串，連接器的顯示名就是
#   「claude.ai Gmail」這種）。被擋的伺服器**根本不會載入**，不只是工具被藏。
#   實測 2026-09-17：在 `--settings` 放 Gmail 的 serverUrl 與 Canva 的
#   serverName，同一個設定目錄下 `claude mcp list` 那兩行就消失了。
#   文件也提醒 serverName 會隨改名失效，所以有 URL 時優先用 serverUrl。
# - 工具層的 deny 是第二道：`--disallowedTools` 與 settings 的
#   `permissions.deny` 共用同一套規則語法（docs/en/permissions）。
#   `mcp__<server>` 與 `mcp__<server>__*` 都匹配該伺服器的全部工具；deny
#   規則的 tool-name 位置吃 glob（`mcp__*` ＝所有 MCP 工具），被 bare-name
#   或 glob deny 命中的工具會**從 context 移除**。注意 allow 規則的 server
#   段不能有 glob，所以不能靠 `mcp__claude_ai_*` 之類反向放行。
# - 連接器的工具名是 `mcp__claude_ai_<server>__<tool>`
#   （docs/en/permissions），server 段就是顯示名把非 [A-Za-z0-9_] 換成 `_`。
#
# 這份是**保底名單**；啟動自檢會跑一次 `claude mcp list` 把實際看到的合併
# 進來（見 loop.selfcheck），所以之後新長出來的連接器也會被擋。
KNOWN_CLAUDE_AI_SERVERS: tuple[tuple[str, str], ...] = (
    ("claude.ai Adobe for creativity", "https://adobe-creativity.adobe.io/mcp"),
    ("claude.ai Atlassian Rovo", "https://mcp.atlassian.com/v1/mcp"),
    ("claude.ai Canva", "https://mcp.canva.com/mcp"),
    ("claude.ai Claude Docs", "https://api.anthropic.com/v1/pages/mcp"),
    ("claude.ai Cloudflare Developer Platform",
     "https://bindings.mcp.cloudflare.com/mcp"),
    ("claude.ai Gmail", "https://gmailmcp.googleapis.com/mcp/v1"),
    ("claude.ai Google Calendar", "https://calendarmcp.googleapis.com/mcp/v1"),
    ("claude.ai Google Drive", "https://drivemcp.googleapis.com/mcp/v1"),
    ("claude.ai Hugging Face", "https://huggingface.co/mcp"),
    ("claude.ai Microsoft 365", "https://microsoft365.mcp.claude.com/mcp"),
    ("claude.ai Notion", "https://mcp.notion.com/mcp"),
    ("claude.ai Postman", "https://mcp.postman.com/minimal"),
)

# 自檢在執行器設定目錄下跑 `claude mcp list` 的上限。連不上的連接器一個要
# 等 30 秒健康檢查，12 個排下來可能很久；逾時只當「這次沒探到」，不算失敗
MCP_LIST_TIMEOUT_SECONDS = 90

# `claude mcp list` 的一行：`<name>: <url or command> - <狀態>`
_MCP_LIST_RE = re.compile(r"^(?P<name>\S.*?): (?P<target>\S+) - ")
_NON_TOOL_CHAR_RE = re.compile(r"[^A-Za-z0-9_]")
# 自檢探到的連接器（顯示名 → URL）。保底名單之外多出來的那些
_discovered_servers: dict[str, str] = {}


def server_slug(name: str) -> str:
    """伺服器顯示名 → 工具名裡的 server 段。

    `claude.ai Gmail` → `claude_ai_Gmail`，工具是
    `mcp__claude_ai_Gmail__send_message`。
    """
    return _NON_TOOL_CHAR_RE.sub("_", name)


def parse_mcp_list(text: str) -> list[tuple[str, str]]:
    """從 `claude mcp list` 的輸出撈出 claude.ai 連接器的（顯示名, URL）。

    只認 `claude.ai ` 開頭的行——本機 stdio 伺服器不是這裡要擋的東西。
    三種狀態行（✔ 已連線 / ! 需要認證 / ✘ 連不上）都要認得：連不上的那行
    後面還跟著一句帶引號的錯誤訊息，不能讓它把名字吃掉。
    """
    found: list[tuple[str, str]] = []
    for line in text.splitlines():
        m = _MCP_LIST_RE.match(line.strip())
        if not m:
            continue
        name = m.group("name")
        if not name.startswith("claude.ai "):
            continue
        target = m.group("target")
        found.append((name, target if target.startswith("http") else ""))
    return found


def remember_claude_ai_servers(servers: list[tuple[str, str]]) -> None:
    """把自檢探到的連接器併進封鎖名單（保底名單之外的新面孔也會被擋）。"""
    for name, url in servers:
        if name:
            _discovered_servers[name] = url


def known_claude_ai_servers() -> list[tuple[str, str]]:
    """保底名單 ＋ 自檢探到的。依顯示名排序，參數順序才穩定、好比對。"""
    merged = {name: url for name, url in KNOWN_CLAUDE_AI_SERVERS}
    for name, url in _discovered_servers.items():
        if url or name not in merged:
            merged[name] = url
    return sorted(merged.items())


def allowed_server_slugs(allowed: list[str] | None,
                         extra_tools: list[str] | None = None) -> set[str]:
    """這筆 run 允許哪些 MCP 伺服器（用工具名裡的 server 段表示）。

    `extra_allowed_tools` 裡的 `mcp__<server>__*` 也算數——不然設定檔放行了
    Atlassian 的工具，這裡又把整台伺服器擋掉，只會湊出一個死局。
    """
    slugs = {server_slug(x) for x in (allowed or []) if x}
    for tool in extra_tools or []:
        if not tool.startswith("mcp__"):
            continue
        rest = tool[len("mcp__"):]
        slugs.add(rest.split("__", 1)[0])
    return {s for s in slugs if s}


def blocked_claude_ai_servers(
        allowed: list[str] | None,
        extra_tools: list[str] | None = None) -> list[tuple[str, str]]:
    """要擋掉的連接器。**預設拒絕**：不在允許清單裡的一律進 deny。"""
    ok = allowed_server_slugs(allowed, extra_tools)
    return [(name, url) for name, url in known_claude_ai_servers()
            if server_slug(name) not in ok]


def disallowed_tools(allowed: list[str] | None,
                     extra_tools: list[str] | None = None) -> list[str]:
    """`--disallowedTools` 與 `permissions.deny` 共用的那份清單。"""
    return [f"mcp__{server_slug(name)}__*"
            for name, _ in blocked_claude_ai_servers(allowed, extra_tools)]


def denied_mcp_servers(allowed: list[str] | None,
                       extra_tools: list[str] | None = None) -> list[dict]:
    """settings 的 `deniedMcpServers`：讓伺服器連載入都不載入。

    有 URL 就用 `serverUrl`（文件說 serverName 會隨連接器改名失效）。
    """
    entries: list[dict] = []
    for name, url in blocked_claude_ai_servers(allowed, extra_tools):
        entries.append({"serverUrl": url} if url else {"serverName": name})
    return entries

_SHA_RE = re.compile(r"\b[0-9a-f]{7,40}\b")
_REPO_HINT_RE = re.compile(r"^\s*repo\s*[:：]\s*(\S+)\s*$",
                           re.IGNORECASE | re.MULTILINE)


class RunSetupError(Exception):
    """還沒起進程就知道做不了。直接 failed，不要浪費一個 claude session。"""


@dataclass
class RunOutcome:
    status: str
    reason: str = ""
    result: str = ""
    usage: dict = field(default_factory=dict)
    claude_session_id: str = ""
    # 這一輪要不要順手把整台執行器標成 limited（weekly limit 用）
    runner_limit_reason: str = ""


class RepoLocks:
    """每個 repo 一把鎖（§5.5）。跨 repo 的票序列做，第一階段不開 worktree。"""

    def __init__(self) -> None:
        self._locks: dict[str, asyncio.Lock] = {}

    def get(self, key: str) -> asyncio.Lock:
        lock = self._locks.get(key)
        if lock is None:
            lock = asyncio.Lock()
            self._locks[key] = lock
        return lock

    def is_held(self, key: str) -> bool:
        lock = self._locks.get(key)
        return bool(lock and lock.locked())


def resolve_repo(run: dict, project: ProjectConfig) -> RepoConfig:
    """這筆 run 在哪個 repo 做。**規則寫死在這裡，brief 只能「指名」不能「指路」。**

    1. ``push``：``ref`` 就是 repo key（§5.6 的形狀是固定的）。
    2. brief 裡有一行 ``repo: <name>``：用那個（必須在專案的 repos 裡）。
    3. 專案只有一個 repo，或設了 ``default_repo``：用它。
    4. 以上都不成立 ⇒ 失敗。**不猜**：猜錯的代價是在錯的工作樹上 commit。
    """
    repos = project.repos
    if run.get("kind") == "push":
        name = (run.get("ref") or "").strip()
        repo = repos.get(name)
        if repo is None:
            raise RunSetupError(
                f"push 的目標 repo「{name}」不在專案 {project.key} 的允許清單裡。")
        return repo
    hint = _REPO_HINT_RE.search(run.get("brief") or "")
    if hint:
        name = hint.group(1)
        repo = repos.get(name)
        if repo is None:
            raise RunSetupError(
                f"簡述指名的 repo「{name}」不在專案 {project.key} 的允許清單裡"
                f"（可用：{'、'.join(repos)}）。")
        return repo
    if project.default_repo:
        return repos[project.default_repo]
    raise RunSetupError(
        f"專案 {project.key} 有多個 repo（{'、'.join(repos)}）且沒有設"
        " default_repo，而簡述裡也沒有 `repo: <名稱>` 這一行——"
        "執行器不會替你猜要動哪一個工作樹。")


def short_id(run_id: str) -> str:
    return (run_id or "")[:8] or "run"


def kill_tree(pid: int) -> None:
    """殺子進程**連同它的子孫**。

    claude 會自己起 MCP server 等子進程；只殺父的話，那些子進程會留著，
    而下一輪看到的是一個「已經結束」的 run 與一堆還連著 Hub 的殭屍。
    """
    if os.name == "nt":
        try:
            subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"],
                           capture_output=True, timeout=20, check=False,
                           **no_window_kwargs())
            return
        except (OSError, subprocess.SubprocessError):  # pragma: no cover
            pass
    try:  # pragma: no cover - 非 Windows 路徑
        os.kill(pid, 9)
    except OSError:
        pass


class RunExecutor:
    """跑一筆 run。一個 executor 實例對應一筆單。"""

    def __init__(self, cfg: RunnerConfig, hub, usage_store=None,
                 locks: RepoLocks | None = None,
                 sleep: Callable[[float], Awaitable[None]] | None = None,
                 on_runner_limited: Callable[[str], None] | None = None,
                 prompt_dir: Path | None = None,
                 monotonic: Callable[[], float] | None = None) -> None:
        self.cfg = cfg
        self.hub = hub
        self.usage_store = usage_store
        self.locks = locks or RepoLocks()
        self.sleep = sleep or asyncio.sleep
        self.on_runner_limited = on_runner_limited
        self.prompt_dir = prompt_dir
        self.monotonic = monotonic or time.monotonic
        self.context_peak = 0
        self.turns = 0
        # 停滯判斷用：最後一次收到 stream 事件的單調時刻。主迴圈每個心跳讀它
        self.last_event_at = self.monotonic()
        self.events_seen = 0
        # pump 掛掉的原因（有值代表這一輪的 stream 沒讀完）
        self.pump_error = ""
        # 現在活著的 claude 子進程。收尾路徑要靠它殺乾淨
        self.live_proc = None

    def mark_activity(self) -> None:
        """記一次「這個 run 還活著」。stream 有事件、或退避睡完要續跑時呼叫。"""
        self.last_event_at = self.monotonic()
        self.events_seen += 1

    # ---------- 對外 ----------

    async def execute(self, run: dict,
                      cancel: asyncio.Event | None = None) -> RunOutcome:
        """執行一筆 run。**任何例外都在這裡收尾。**

        🚨 2026-09-17 事故：`_pump` 丟出的 `ValueError` 把執行任務整個帶走，
        子進程沒被殺、Hub 上那筆 run 停在 running，人類按取消也沒人處理。
        所以這一層是安全網——殺進程樹、回報一個有理由的 failed，然後才讓
        錯誤往上走給 log。少了它，一個未預期的例外＝一筆永遠不會收場的 run。
        """
        cancel = cancel or asyncio.Event()
        run_id = run["id"]
        try:
            return await self._execute(run, cancel)
        except asyncio.CancelledError:
            self.kill_live_proc()
            await self._report(run_id, RunOutcome(
                "cancelled", reason="cancel_requested",
                result="執行任務被取消，子進程已終止。"))
            raise
        except Exception as exc:
            self.kill_live_proc()
            log.error("run %s 的執行以未預期的例外收場", run_id, exc_info=exc)
            outcome = RunOutcome(
                "failed", reason=f"runner_error: {exc.__class__.__name__}",
                result=f"執行器在跑這筆 run 時丟出未預期的例外："
                       f"{exc.__class__.__name__}: {exc}\n"
                       "子進程（若還在）已被終止。詳細堆疊在執行器的 log。")
            await self._report(run_id, outcome)
            return outcome

    def kill_live_proc(self) -> None:
        """把還活著的 claude 子進程樹殺掉。收尾路徑用，重複呼叫無害。"""
        proc = self.live_proc
        if proc is None or proc.returncode is not None:
            return
        log.warning("收尾：終止仍在跑的 claude 進程（pid %s）", proc.pid)
        kill_tree(proc.pid)

    async def _execute(self, run: dict,
                       cancel: asyncio.Event) -> RunOutcome:
        run_id = run["id"]
        try:
            project = self.cfg.project(run["project"])
            repo = resolve_repo(run, project)
        except Exception as exc:
            outcome = RunOutcome("failed", reason="setup_error",
                                 result=str(exc))
            await self._report(run_id, outcome)
            return outcome

        if run["kind"] == "push":
            async with self.locks.get(f"{project.key}/{repo.name}"):
                outcome = await self._push(run, repo)
            await self._report(run_id, outcome)
            return outcome

        if run["kind"] in WRITE_KINDS:
            async with self.locks.get(f"{project.key}/{repo.name}"):
                return await self._claude_run(run, project, repo, cancel)
        return await self._claude_run(run, project, repo, cancel)

    # ---------- push（不經模型，§5.6）----------

    async def _push(self, run: dict, repo) -> RunOutcome:
        brief = run.get("brief") or ""
        branch = self._push_branch(brief) or await gitops.current_branch(
            repo.path)
        if not repo.allows_push(branch):
            return RunOutcome(
                "failed", reason="push_branch_not_allowed",
                result=f"分支「{branch}」不在 {repo.name} 的可推清單"
                       f"（{'、'.join(repo.push_branches) or '空'}）裡，沒有推送。")
        # 🚨 先 fetch 再算未推送：不 fetch 的話比對的是上次 fetch 時的遠端
        # 位置，而那份清單同時是「按鈕的人看到什麼」的依據。fetch 失敗＝不知
        # 道遠端現在長什麼樣子，這時推上去是盲推
        fetched = await gitops.git(repo.path, *self._push_credential_args(),
                                   "fetch", "origin", branch)
        if not fetched.ok:
            return RunOutcome(
                "failed", reason="push_fetch_failed",
                result=f"git fetch origin {branch} 失敗，沒有推送："
                       f"{fetched.err or fetched.out}\n"
                       "抓不到遠端就無法確認待推的是不是儀表板上那幾顆。")
        expected = {s for s in _SHA_RE.findall(brief.lower())
                    if s != branch.lower()}
        if not expected:
            return RunOutcome(
                "failed", reason="push_sha_list_missing",
                result="這筆 push 沒有帶要推的 commit 清單。儀表板上按推送時會"
                       "把 sha 一起送來；沒有清單就無法確認要推的是不是你看到的"
                       "那幾顆，所以不推。")
        actual = [c.sha for c in await gitops.unpushed(repo.path, branch)]
        if not self._sha_sets_match(expected, actual):
            return RunOutcome(
                "failed", reason="push_sha_mismatch",
                result=(f"待推的 commit 與派工當下看到的不一致，沒有推送。\n"
                        f"現在是 {len(actual)} 顆：{', '.join(a[:8] for a in actual) or '（無）'}\n"
                        f"派工時是 {len(expected)} 顆："
                        f"{', '.join(sorted(s[:8] for s in expected))}\n"
                        "請重新整理儀表板再按一次。"))
        res = await gitops.git(repo.path, *self._push_credential_args(),
                               "push", "origin", branch)
        if not res.ok:
            return RunOutcome("failed", reason="push_failed",
                              result=f"git push 失敗：{res.err or res.out}")
        return RunOutcome(
            "done", reason="pushed",
            result=f"已推送 {repo.name} 的 {branch}（{len(actual)} 顆 commit）。")

    @staticmethod
    def _push_credential_args() -> list[str]:
        """push run 是唯一帶推送憑證的路徑（艾斯維爾裁決 09/16）。

        一般 run 的子進程環境把 ``credential.helper`` 清單清空，所以它對私有
        遠端拿不到憑證；這裡**明確**把執行器自己的 helper 加回來。不改 remote
        URL、不存任何 token——URL 裡帶 token 會留在 `git remote -v` 與 reflog
        上，而那是誰都讀得到的地方。
        """
        return ["-c", f"credential.helper={PUSH_CREDENTIAL_HELPER}"]

    @staticmethod
    def _push_branch(brief: str) -> str:
        for raw in (brief or "").splitlines():
            line = raw.strip()
            if not line:
                continue
            if line.lower().startswith("branch:"):
                return line.split(":", 1)[1].strip()
            if not _SHA_RE.fullmatch(line.lower()) and " " not in line:
                return line
        return ""

    @staticmethod
    def _sha_sets_match(expected: set[str], actual: list[str]) -> bool:
        """sha 可能是短的。比對用前綴，但**兩邊的顆數必須一樣**。

        只比「每個期待的都找得到」的話，多出來的那幾顆會被一起推上去，
        而按鈕的人以為自己推的是畫面上那幾顆。
        """
        if len(expected) != len(actual):
            return False
        lowered = [a.lower() for a in actual]
        for want in expected:
            if not any(a.startswith(want) for a in lowered):
                return False
        return True

    # ---------- claude run ----------

    async def _claude_run(self, run: dict, project: ProjectConfig, repo,
                          cancel: asyncio.Event) -> RunOutcome:
        run_id = run["id"]
        run_dir = self.cfg.runs_dir / run_id
        run_dir.mkdir(parents=True, exist_ok=True)
        branch = await gitops.current_branch(repo.path)
        if not repo.allows(branch):
            outcome = RunOutcome(
                "failed", reason="branch_not_allowed",
                result=f"{repo.name} 目前在分支「{branch}」，不在允許清單"
                       f"（{'、'.join(repo.allowed_branches)}）裡。"
                       "執行器不會替你切分支——那是人類的決定。")
            await self._report(run_id, outcome)
            return outcome

        before = await gitops.snapshot(repo.path)
        fields = {
            "run_id": run_id, "room_id": run.get("room_id", ""),
            "kind": run["kind"], "project": project.key,
            "ref": run.get("ref", ""), "repo": repo.name,
            "cwd": str(repo.path), "branch": branch,
            "allowed_branches": "、".join(repo.allowed_branches),
        }
        prompt = prompts.build(run["kind"], fields, run.get("brief", ""),
                               self.prompt_dir)
        contract = prompts.build_contract(fields, self.prompt_dir)
        self._write_run_files(run_dir, run, repo)
        env = self._child_env(run, run_dir)

        await self._report(run_id, RunOutcome("running", reason="spawn"))

        resume: str = ""
        backoffs = list(self.cfg.backoff_minutes)
        attempt = 0
        outcome = RunOutcome("failed", reason="never_ran")
        while True:
            # 每一輪（含退避後的 --resume）重新起算：剛起的進程還沒吐東西，
            # 不該立刻被上一輪的沉默判成停滯
            self.mark_activity()
            watcher = StreamWatcher(
                project.context_soft_limit_tokens,
                on_soft_limit=lambda n, d=run_dir: self._raise_handoff(d, n),
                rate_limit_threshold=self.cfg.rate_limit_retry_threshold,
                monotonic=self.monotonic,
                on_event=self.mark_activity)
            argv = self._argv(prompt, contract, project, run_dir,
                              resume, run["kind"])
            code, stop_reason = await self._spawn(argv, repo.path, env,
                                                  watcher, run_dir,
                                                  project.wall_clock_seconds,
                                                  cancel)
            state = watcher.state
            self.context_peak = max(self.context_peak,
                                    state.peak_context_tokens)
            self.turns = state.num_turns
            self._record_usage(run_id, state)
            outcome = self._classify(state, code, stop_reason, run_dir,
                                     watcher.rate_limited)
            outcome.result = self._compose_result(state, run_dir, before,
                                                  await gitops.snapshot(
                                                      repo.path))
            if outcome.reason != "rate_limit" or not backoffs:
                break
            wait_minutes = backoffs.pop(0)
            attempt += 1
            await self._report(run_id, RunOutcome(
                "limited", reason=f"rate_limit_backoff_{wait_minutes}m",
                result=f"撞到額度上限，{wait_minutes} 分鐘後用 --resume 續跑"
                       f"（第 {attempt} 次退避）。",
                claude_session_id=state.session_id))
            await self.sleep(wait_minutes * 60)
            if cancel.is_set():
                outcome = RunOutcome("cancelled", reason="cancel_requested",
                                     result="退避等待期間收到取消。")
                break
            resume = state.session_id
            await self._report(run_id, RunOutcome(
                "running", reason="resume_after_backoff",
                claude_session_id=state.session_id))

        if outcome.reason == "rate_limit":
            # 退避用完了還是撞牆：交給人類，不要無限續下去
            outcome = RunOutcome(
                "failed", reason="rate_limit_exhausted",
                result=outcome.result, usage=outcome.usage,
                claude_session_id=outcome.claude_session_id)
        await self._report(run_id, outcome)
        if outcome.runner_limit_reason and self.on_runner_limited:
            self.on_runner_limited(outcome.runner_limit_reason)
        return outcome

    # ---------- 子進程 ----------

    def _argv(self, prompt: str, contract: str, project: ProjectConfig,
              run_dir: Path, resume: str, kind: str = "") -> list[str]:
        tools = allowed_tools(kind, self.cfg.extra_allowed_tools)
        denied = disallowed_tools(self.cfg.allowed_mcp_servers,
                                  self.cfg.extra_allowed_tools)
        argv = list(self.cfg.claude_bin) + [
            "-p", prompt,
            # stream-json **必須配 --verbose**，否則 CLI 直接 exit 1
            "--output-format", "stream-json", "--verbose",
            "--permission-mode", "auto",
            # 見 BASE_ALLOWED_TOOLS：`auto` 不會自動放行 MCP 工具
            "--allowedTools", ",".join(tools),
            "--model", project.model,
            "--max-turns", str(project.max_turns),
            "--max-budget-usd", str(project.max_budget_usd),
            "--mcp-config", str(run_dir / "mcp.json"),
            "--settings", str(run_dir / "settings.json"),
            "--append-system-prompt", contract,
        ]
        if denied:
            # 第二道：把連接器的工具從 context 移除。第一道是 settings 的
            # `deniedMcpServers`（伺服器根本不載入），見 KNOWN_CLAUDE_AI_SERVERS
            argv += ["--disallowedTools", ",".join(denied)]
        if resume:
            argv += ["--resume", resume]
        return argv

    def _child_env(self, run: dict, run_dir: Path) -> dict[str, str]:
        env = dict(os.environ)
        env.update({
            # 獨立設定目錄：不加就會載入使用者全域的 hooks（persona 注入等）
            "CLAUDE_CONFIG_DIR": str(self.cfg.claude_config_dir),
            "CHATROOM_URL": self.cfg.hub_url,
            "CHATROOM_TOKEN": self.cfg.agent_token,
            "CHATROOM_SESSION_KEY": f"claude-run-{run['id']}",
            "CHATROOM_DEFAULT_NAME":
                f"{self.cfg.label}-{short_id(run['id'])}",
            "CHATROOM_RUNNER_RUN_DIR": str(run_dir),
            "CHATROOM_DOWNLOAD_DIR": str(run_dir / DOWNLOADS_DIR_NAME),
        })
        env.update(self._git_credential_isolation(env))
        return env

    @staticmethod
    def _git_credential_isolation(env: dict[str, str]) -> dict[str, str]:
        """把推送憑證擋在 run 進程外（艾斯維爾裁決 09/16）。

        ``GIT_CONFIG_*`` 是**這個進程**的覆寫，本機 git 設定一個字都沒動：
        helper 清單被清空，run 裡的 push／fetch 對私有遠端拿不到憑證就失敗。
        再關掉終端提示與 askpass，否則它會停在一個沒有人能回答的問句上。

        ⚠️ 已經有別的 ``GIT_CONFIG_COUNT`` 用途時**接在後面**，不是覆蓋：
        直接寫 1 會把前面那幾條設定連號一起吃掉。
        """
        try:
            count = int(env.get("GIT_CONFIG_COUNT", "") or 0)
        except ValueError:
            count = 0
        count = max(count, 0)
        return {
            f"GIT_CONFIG_KEY_{count}": "credential.helper",
            f"GIT_CONFIG_VALUE_{count}": "",
            "GIT_CONFIG_COUNT": str(count + 1),
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_ASKPASS": str(ASKPASS_SCRIPT),
            "SSH_ASKPASS": str(ASKPASS_SCRIPT),
        }

    async def _spawn(self, argv: list[str], cwd: Path, env: dict,
                     watcher: StreamWatcher, run_dir: Path,
                     wall_clock: float,
                     cancel: asyncio.Event) -> tuple[int, str]:
        """起進程並逐行吃 stream。回 ``(exit_code, 停止原因)``。"""
        proc = await asyncio.create_subprocess_exec(
            *argv, cwd=str(cwd), env=env,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            limit=STREAM_LINE_LIMIT, **no_window_kwargs())
        self.live_proc = proc
        pump = asyncio.create_task(self._pump(proc, watcher, run_dir))
        waiter = asyncio.create_task(proc.wait())
        canceller = asyncio.create_task(cancel.wait())
        stop = "exited"
        try:
            done, _ = await asyncio.wait(
                {waiter, canceller},
                timeout=wall_clock if wall_clock > 0 else None,
                return_when=asyncio.FIRST_COMPLETED)
            if waiter not in done:
                stop = "cancelled" if canceller in done else "wall_clock"
                kill_tree(proc.pid)
                try:
                    await asyncio.wait_for(waiter, timeout=30)
                except asyncio.TimeoutError:  # pragma: no cover
                    proc.kill()
                    await waiter
        finally:
            canceller.cancel()
            try:
                await asyncio.wait_for(pump, timeout=30)
            except (asyncio.TimeoutError, asyncio.CancelledError):
                # pragma: no cover - 讀不完就算了，狀態已經夠判斷
                pump.cancel()
            self.live_proc = None
        return proc.returncode or 0, stop

    async def _pump(self, proc, watcher: StreamWatcher, run_dir: Path) -> None:
        """stdout 逐行進 watcher，同時原樣落檔（事後要有得看）。

        🚨 **這裡的例外一律吞掉並記錄**（2026-09-17 事故）：pump 是一個獨立的
        task，它丟出去的例外會把 `_spawn` 的 `wait_for` 一起帶走，整個執行任務
        死在半路——子進程還活著、Hub 上那筆 run 停在 running，而沒有任何人會去
        收它。讀不完的 stream 只代表「後面的事件看不到」，那比停屍好處理。
        """
        path = run_dir / "stream.jsonl"
        try:
            with path.open("a", encoding="utf-8") as fh:
                while True:
                    raw = await proc.stdout.readline()
                    if not raw:
                        break
                    line = raw.decode("utf-8", "replace")
                    fh.write(line if line.endswith("\n") else line + "\n")
                    fh.flush()
                    watcher.feed_line(line)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            self.pump_error = f"{exc.__class__.__name__}: {exc}"
            log.error("stream 讀取中斷（%s）；後續事件不會被看到",
                      self.pump_error, exc_info=exc)

    def _raise_handoff(self, run_dir: Path, tokens: int) -> None:
        """立旗標。下一次工具呼叫會被 `PreToolUse` 擋下並要求交接（§5.4）。"""
        (run_dir / "handoff.flag").write_text(
            json.dumps({"context_tokens": tokens}, ensure_ascii=False),
            encoding="utf-8")

    # ---------- 判定與回報 ----------

    def _classify(self, state, code: int, stop_reason: str, run_dir: Path,
                  rate_limited: bool) -> RunOutcome:
        sid = state.session_id
        usage = dict(state.usage or {})
        usage.update({"total_cost_usd": state.total_cost_usd,
                      "num_turns": state.num_turns,
                      "context_peak_tokens": state.peak_context_tokens})
        if stop_reason == "cancelled":
            return RunOutcome("cancelled", reason="cancel_requested",
                              usage=usage, claude_session_id=sid)
        if stop_reason == "wall_clock":
            return RunOutcome("failed", reason="wall_clock", usage=usage,
                              claude_session_id=sid)
        if state.weekly_limit:
            return RunOutcome("limited", reason="weekly_limit", usage=usage,
                              claude_session_id=sid,
                              runner_limit_reason="weekly_limit")
        failed = code != 0 or state.is_error or not state.saw_result
        if failed and (rate_limited
                       or state.subtype == "error_during_execution"
                       and state.rate_limit_retries > 0):
            return RunOutcome("limited", reason="rate_limit", usage=usage,
                              claude_session_id=sid)
        if (run_dir / "handoff.flag").exists():
            return RunOutcome("handoff", reason="context_soft_limit",
                              usage=usage, claude_session_id=sid)
        if state.subtype == "error_max_turns":
            return RunOutcome("failed", reason="max_turns", usage=usage,
                              claude_session_id=sid)
        if state.subtype == "error_max_budget_usd":
            return RunOutcome("failed", reason="max_budget_usd", usage=usage,
                              claude_session_id=sid)
        if failed:
            # 🚨 exit code 與 is_error 是主判準，subtype 只是補充：實測未登入時
            # subtype 仍是 success，只看它會把一個什麼都沒做的 run 標成完成
            reason = (state.subtype if state.subtype.startswith("error")
                      else f"exit_{code}")
            return RunOutcome("failed", reason=reason, usage=usage,
                              claude_session_id=sid)
        return RunOutcome("done", reason=state.subtype or "success",
                          usage=usage, claude_session_id=sid)

    def _compose_result(self, state, run_dir: Path,
                        before: gitops.RepoSnapshot,
                        after: gitops.RepoSnapshot) -> str:
        diff = gitops.diff_snapshots(before, after)
        lines = [state.result_text.strip()] if state.result_text.strip() else []
        lines.append("")
        lines.append("— 執行器附註 —")
        lines.append(f"turns：{state.num_turns}；成本："
                     f"${state.total_cost_usd:.4f}；context 峰值："
                     f"{state.peak_context_tokens} tokens")
        lines.append(f"HEAD：{(diff['head_before'] or '?')[:8]} → "
                     f"{(diff['head_after'] or '?')[:8]}"
                     f"{'（有新 commit）' if diff['head_changed'] else ''}")
        if diff["branch_changed"]:
            lines.append(f"⚠️ 分支變了：{diff['branch_before']} → "
                         f"{diff['branch_after']}")
        if diff["new_dirty"]:
            lines.append("未 commit 的變更（執行器不會自動處理）："
                         + "、".join(diff["new_dirty"][:20]))
        if (run_dir / "compacted").exists():
            lines.append("⚠️ 這一輪被自動壓縮過，摘要裡對前段的敘述是二手的。")
        tool_log = run_dir / "tool.log"
        if tool_log.exists():
            n = sum(1 for _ in tool_log.open(encoding="utf-8"))
            lines.append(f"工具呼叫 {n} 次（完整紀錄：{tool_log}）")
        return "\n".join(lines).strip()[:8000]

    def _record_usage(self, run_id: str, state) -> None:
        if self.usage_store is None:
            return
        self.usage_store.record(run_id, state.total_tokens(),
                                state.total_cost_usd)

    async def _report(self, run_id: str, outcome: RunOutcome) -> bool:
        """回報狀態。**送不出去就落地**（審查 09/16）。

        🚨 一次 HubError 就放棄的話，那筆 run 的結果只存在於一個即將結束的
        process 的記憶體裡：房裡永遠停在 running，而本機一行紀錄都沒有。
        重試三次（退避 2／5 秒），還是不行就寫進 run 目錄，由下一次 heartbeat
        重送。
        """
        last: Exception | None = None
        for attempt in range(1, REPORT_ATTEMPTS + 1):
            try:
                await self.hub.report(
                    run_id, outcome.status, result=outcome.result,
                    reason=outcome.reason,
                    claude_session_id=outcome.claude_session_id,
                    usage=outcome.usage or None)
                return True
            except HubError as exc:
                last = exc
                log.warning("run %s 回報 %s 失敗（第 %d 次）：%s", run_id,
                            outcome.status, attempt, exc)
                if attempt < REPORT_ATTEMPTS:
                    await self.sleep(REPORT_BACKOFF_SECONDS[attempt - 1])
        self._land_report(run_id, outcome, last)
        return False

    def _land_report(self, run_id: str, outcome: RunOutcome,
                     error: Exception | None) -> None:
        run_dir = self.cfg.runs_dir / run_id
        payload = {"run_id": run_id, "status": outcome.status,
                   "reason": outcome.reason, "result": outcome.result,
                   "claude_session_id": outcome.claude_session_id,
                   "usage": outcome.usage or None,
                   "error": str(error) if error else ""}
        try:
            run_dir.mkdir(parents=True, exist_ok=True)
            (run_dir / REPORT_FAILED_NAME).write_text(
                json.dumps(payload, ensure_ascii=False, indent=2),
                encoding="utf-8")
        except OSError as exc:  # pragma: no cover - 連本機都寫不了就只剩 log
            log.error("run %s 的回報連落地都失敗：%s", run_id, exc)
            return
        log.error("run %s 的 %s 回報送不出去，已落地到 %s，等下一次 heartbeat "
                  "重送", run_id, outcome.status, run_dir / REPORT_FAILED_NAME)

    # ---------- run 目錄 ----------

    def _write_run_files(self, run_dir: Path, run: dict, repo) -> None:
        python = sys.executable
        hook = str(HOOKS_DIR / "pretooluse.py")
        precompact = str(HOOKS_DIR / "precompact.py")
        denied_servers = denied_mcp_servers(self.cfg.allowed_mcp_servers,
                                            self.cfg.extra_allowed_tools)
        denied_tools = disallowed_tools(self.cfg.allowed_mcp_servers,
                                        self.cfg.extra_allowed_tools)
        settings = {
            # 跟著登入進來的 claude.ai 連接器：預設拒絕。
            # `deniedMcpServers` 讓它們連載入都不載入，`permissions.deny`
            # 是萬一伺服器仍然到齊時的第二道。見 KNOWN_CLAUDE_AI_SERVERS
            "deniedMcpServers": denied_servers,
            "permissions": {"deny": denied_tools},
            "hooks": {
                "PreToolUse": [{
                    # ⚠️ 一定要含 PowerShell：Windows 上模型預設選它，
                    # 只擋 Bash 的話 `echo hi` 直接跑過去
                    "matcher": TOOL_MATCHER,
                    "hooks": [{"type": "command",
                               "command": f'"{python}" "{hook}"'}],
                }],
                "PreCompact": [{
                    "matcher": "",
                    "hooks": [{"type": "command",
                               "command": f'"{python}" "{precompact}"'}],
                }],
            }
        }
        (run_dir / "settings.json").write_text(
            json.dumps(settings, ensure_ascii=False, indent=2),
            encoding="utf-8")

        bridge = self.cfg.bridge_path or (
            Path(__file__).resolve().parents[2] / "bridge")
        mcp = {"mcpServers": {"chatroom": {
            "command": python,
            "args": ["-m", "chatroom_mcp"],
            # 🚨 模組搜尋路徑走 env.PYTHONPATH，**不要靠 `cwd` 欄位**
            #（實測不生效，會 No module named chatroom_mcp）
            "env": {
                "PYTHONPATH": str(bridge),
                "CHATROOM_URL": self.cfg.hub_url,
                "CHATROOM_TOKEN": self.cfg.agent_token,
                "CHATROOM_SESSION_KEY": f"claude-run-{run['id']}",
                "CHATROOM_DEFAULT_NAME":
                    f"{self.cfg.label}-{short_id(run['id'])}",
                # 附件落在 run 目錄底下，不是 cwd。bridge 預設會寫
                # `./.chatroom/downloads/`，那個「.」是被派工的 repo
                "CHATROOM_DOWNLOAD_DIR": str(run_dir / DOWNLOADS_DIR_NAME),
                # 不帶這個 bridge 會落回 other，成員列顯示 OTHER
                "CHATROOM_AGENT_KIND": AGENT_KIND,
            },
        }}}
        (run_dir / "mcp.json").write_text(
            json.dumps(mcp, ensure_ascii=False, indent=2), encoding="utf-8")

        # 下載目錄先建起來：guard 的放行是比對路徑，但 bridge 要寫得進去
        downloads = run_dir / DOWNLOADS_DIR_NAME
        downloads.mkdir(parents=True, exist_ok=True)

        ctx = GuardContext(
            cwd=repo.path,
            allowed_branches=list(repo.allowed_branches),
            allowed_domains=list(self.cfg.allowed_domains),
            protected_paths=[self.cfg.state_dir, self.cfg.claude_config_dir,
                             HOOKS_DIR.parent],
            # run 目錄整個在 state_dir 底下，本來會被「執行器自己的目錄」擋掉。
            # 附件是 agent 自己要來的，讀得到才有意義——只鑿這一個洞
            downloads_dir=downloads,
        )
        (run_dir / "guard.json").write_text(
            json.dumps(ctx.to_dict(), ensure_ascii=False, indent=2),
            encoding="utf-8")
