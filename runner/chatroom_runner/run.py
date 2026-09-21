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
import contextlib
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
# 🚨 命名對照（跨界）：這個檔案裡的 `project` 一律是 **Hub 的 project key**
# ＝本機的**工作區**（`WorkspaceConfig`），`repo` 是工作區底下的一個 git
# **專案**（`ProjectConfig`）。Hub／DB／bridge 的欄位名沒有跟著換
from .config import (SOFT_STOP_FLAG_NAME, SOFT_STOP_TIMEOUT_FLAG_NAME,
                     ProjectConfig, RunnerConfig, WorkspaceConfig)
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
# run 物件的 `single_writer`：房間要不要守「同一個 repo 同時只有一個寫入型
# run」。**缺鍵一律當 True**（現行行為）——這個欄位由 Hub 從房間帶出來，
# 舊的 Hub 與舊的 run 都不會有它，預設放寬等於默默取消一條安全規則
SINGLE_WRITER_KEY = "single_writer"
# 關掉時給人看的那一句。log 與第一次 running 回報的附註共用同一份文字，
# 面板上看到的與 log 裡寫的才是同一件事
PARALLEL_WRITE_NOTE = "房間已關閉單一寫入者限制，與其他 run 並行。"


def single_writer(run: dict) -> bool:
    """這筆 run 要不要守 repo 的單一寫入者鎖。缺鍵 ＝ 要（現行行為）。"""
    return run.get(SINGLE_WRITER_KEY, True) is not False
# 🚨 進房是 run 的**前置條件**（艾斯維爾裁決 09/19）。實測 run 401a66ab：
# `system/init` 的 mcp_servers 裡 chatroom 是 `pending`（bridge 起得比 Claude
# Code 的 MCP 連線逾時慢），整份 stream 零筆 chatroom 工具呼叫——agent 自己
# 判斷「稍後重試」，然後改走別的工具盲做一整輪：沒有 join、沒讀卡、收尾也沒
# 寫卡。連不上就沒有素材可做，所以直接殺掉重起，重試耗盡就報 failed
REQUIRED_MCP_SERVER = "chatroom"
MCP_UNAVAILABLE_REASON = "chatroom_mcp_unavailable"
# 重試前探一次 bridge 能不能 import（啟動競速的第一個嫌疑是它起不來）
BRIDGE_PROBE_TIMEOUT_SECONDS = 60

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


def allowed_tools(kind: str, extra: list[str] | None = None,
                  skills: list[str] | None = None) -> list[str]:
    """這筆 run 要預先授權哪些工具。順序穩定，方便測試與 log 比對。

    ``skills`` 是這一輪要授權的 skill 名：工作區的 `primary_skill`（不分
    kind）加上這種 kind 必須遵守的那些（見 `WorkspaceConfig.all_skills_for`）。
    headless 下 skill 一樣要預授權（`Skill(<name>)`），不然模型一叫它就停在
    一個沒有人能按的權限提示。
    """
    tools = list(BASE_ALLOWED_TOOLS)
    if kind in WRITE_KINDS:
        tools += list(WRITE_ALLOWED_TOOLS)
    for name in skills or []:
        entry = f"Skill({name})"
        if name and entry not in tools:
            tools.append(entry)
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
#
# 🔴 **不只連接器**：自檢探到的**本機 stdio 伺服器**（執行器設定目錄的
# `.claude.json` 裡註冊的那些）也一起收進來。沒有 `--strict-mcp-config`，
# 那些伺服器照樣會載入；只擋連接器的話，「允許清單」對它們等於沒有規則，
# 而畫面上勾了什麼都不會改變 run 看得到的工具。chatroom 本來就在允許
# 清單裡（`DEFAULT_ALLOWED_MCP_SERVERS`），所以它不會被自己擋掉。
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

# `claude mcp list` 的一行：`<name>: <url or command> - <狀態>`。
# 🔴 target 不能用 `\S+`：本機 stdio 伺服器的那一段是**帶參數的命令**
#（`C:/python.exe -m chatroom_mcp`），`\S+` 只吃到執行檔就對不上後面的
# ` - `，整行會被當成沒有伺服器而靜默跳過。改成非貪婪吃到狀態符號為止
_MCP_LIST_RE = re.compile(r"^(?P<name>\S.*?): (?P<target>.+?) - [✔!✘]")
_NON_TOOL_CHAR_RE = re.compile(r"[^A-Za-z0-9_]")
# 自檢探到的 MCP 伺服器（顯示名 → URL；本機 stdio 伺服器的 URL 是空字串）。
# 保底名單之外多出來的那些
_discovered_servers: dict[str, str] = {}


def server_slug(name: str) -> str:
    """伺服器顯示名 → 工具名裡的 server 段。

    `claude.ai Gmail` → `claude_ai_Gmail`，工具是
    `mcp__claude_ai_Gmail__send_message`。
    """
    return _NON_TOOL_CHAR_RE.sub("_", name)


def parse_mcp_list(text: str) -> list[tuple[str, str]]:
    """從 `claude mcp list` 的輸出撈出每一台 MCP 伺服器的（顯示名, URL）。

    claude.ai 連接器與本機 stdio 伺服器**都要撈**：允許清單是預設拒絕，
    沒被撈到的伺服器就沒有規則管得到它。stdio 那種沒有 URL，回空字串
    （deny 時改用 `serverName`）。
    三種狀態行（✔ 已連線 / ! 需要認證 / ✘ 連不上）都要認得：連不上的那行
    後面還跟著一句帶引號的錯誤訊息，不能讓它把名字吃掉。
    """
    found: list[tuple[str, str]] = []
    for line in text.splitlines():
        m = _MCP_LIST_RE.match(line.strip())
        if not m:
            continue
        name = m.group("name")
        target = m.group("target")
        found.append((name, target if target.startswith("http") else ""))
    return found


def remember_mcp_servers(servers: list[tuple[str, str]]) -> None:
    """把自檢探到的伺服器併進名單（保底名單之外的新面孔也會被擋）。"""
    for name, url in servers:
        if name:
            _discovered_servers[name] = url


def known_mcp_servers() -> list[tuple[str, str]]:
    """保底名單 ＋ 自檢探到的 ＋ 全域 `.claude.json` 的。依顯示名排序，
    參數順序才穩定、好比對。

    全域那些也要收進來：允許清單是預設拒絕，名單裡沒有的伺服器就沒有規則
    管得到它。它們沒有 URL，deny 時用 `serverName`。
    """
    merged = {name: url for name, url in KNOWN_CLAUDE_AI_SERVERS}
    for name in global_mcp_servers():
        merged.setdefault(name, "")
    for name, url in _discovered_servers.items():
        if url or name not in merged:
            merged[name] = url
    return sorted(merged.items())


# 🔴 使用者全域 `~/.claude.json` 的 `mcpServers`（fff、mempal、open-notebook
# 這種自訂的本機 stdio 伺服器）。執行器用自己的 `CLAUDE_CONFIG_DIR` 起
# claude，所以那個設定目錄下的 `claude mcp list` **問不到它們**——只有
# 人類自己的設定檔裡有定義。允許清單勾了這種伺服器時，光放行沒有用，
# 要把定義**原樣複製**進 run 的 mcp.json，claude 才載得到。
_GLOBAL_CONFIG_NAME = ".claude.json"
# 允許清單點名、卻哪裡都找不到定義的名字。同一個進程只念一次
_warned_unknown_allowed: set[str] = set()


def global_config_path() -> Path:
    """使用者全域 `.claude.json` 的位置。

    `CLAUDE_CONFIG_DIR` 有設而且那裡真的有檔案就用它（人類把設定搬走的
    情況），否則回 `~/.claude.json`（Windows 是 `%USERPROFILE%`）。
    """
    env = (os.environ.get("CLAUDE_CONFIG_DIR") or "").strip()
    if env:
        candidate = Path(env).expanduser() / _GLOBAL_CONFIG_NAME
        if candidate.is_file():
            return candidate
    return Path.home() / _GLOBAL_CONFIG_NAME


def global_mcp_servers() -> dict[str, dict]:
    """全域設定檔裡的 `mcpServers`（顯示名 → 原樣定義）。

    檔案不在、讀不動或壞掉都只記 warning 回空字典——這不該擋住一筆 run。
    定義裡的 `env` 原樣帶，不做任何展開（那是人類自己寫的值）。
    """
    path = global_config_path()
    try:
        raw = json.loads(path.read_text("utf-8"))
    except FileNotFoundError:
        log.warning("全域 %s 不存在，允許清單裡的自訂 MCP 伺服器帶不進 run",
                    path)
        return {}
    except (OSError, ValueError) as exc:
        log.warning("全域 %s 讀不了或格式壞掉（%s），這次略過", path, exc)
        return {}
    servers = raw.get("mcpServers")
    if not isinstance(servers, dict):
        return {}
    return {str(name): dict(spec) for name, spec in servers.items()
            if isinstance(spec, dict)}


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


def blocked_mcp_servers(
        allowed: list[str] | None,
        extra_tools: list[str] | None = None) -> list[tuple[str, str]]:
    """要擋掉的伺服器。**預設拒絕**：不在允許清單裡的一律進 deny。"""
    ok = allowed_server_slugs(allowed, extra_tools)
    return [(name, url) for name, url in known_mcp_servers()
            if server_slug(name) not in ok]


def disallowed_tools(allowed: list[str] | None,
                     extra_tools: list[str] | None = None) -> list[str]:
    """`--disallowedTools` 與 `permissions.deny` 共用的那份清單。"""
    return [f"mcp__{server_slug(name)}__*"
            for name, _ in blocked_mcp_servers(allowed, extra_tools)]


def global_mcp_definitions(
        allowed: list[str] | None,
        reserved: tuple[str, ...] = ()) -> dict[str, dict]:
    """允許清單點名、而且全域設定檔裡真的有定義的那幾台（原樣的定義）。

    `reserved` 的名字（chatroom）永遠是執行器自己那一份，不從全域取。
    允許清單裡有、全域沒有、`claude mcp list` 也沒看過的名字，記一次
    warning——那多半是打錯字或伺服器已經被移掉了。
    """
    servers = global_mcp_servers()
    picked: dict[str, dict] = {}
    for name in allowed or []:
        if not name or name in reserved:
            continue
        spec = servers.get(name)
        if spec is not None:
            picked[name] = spec
    seen = {name for name, _ in known_mcp_servers()} | set(reserved)
    unknown = [name for name in (allowed or [])
               if name and name not in seen
               and name not in _warned_unknown_allowed]
    if unknown:
        _warned_unknown_allowed.update(unknown)
        log.warning("允許清單點名的 MCP 伺服器找不到定義：%s"
                    "（全域 %s 與執行器設定目錄都沒有）",
                    "、".join(unknown), global_config_path())
    return picked


def denied_mcp_servers(allowed: list[str] | None,
                       extra_tools: list[str] | None = None) -> list[dict]:
    """settings 的 `deniedMcpServers`：讓伺服器連載入都不載入。

    有 URL 就用 `serverUrl`（文件說 serverName 會隨連接器改名失效）。
    """
    entries: list[dict] = []
    for name, url in blocked_mcp_servers(allowed, extra_tools):
        entries.append({"serverUrl": url} if url else {"serverName": name})
    return entries

_SHA_RE = re.compile(r"\b[0-9a-f]{7,40}\b")
_REPO_HINT_RE = re.compile(r"^\s*repo\s*[:：]\s*(\S+)\s*$",
                           re.IGNORECASE | re.MULTILINE)


class RunSetupError(Exception):
    """還沒起進程就知道做不了。直接 failed，不要浪費一個 claude session。"""


class _SyncBlocked(Exception):
    """工作樹沒辦法更新到最新，這一輪不該起跑。訊息直接當 run 的 result。"""


@dataclass
class RunOutcome:
    status: str
    reason: str = ""
    result: str = ""
    usage: dict = field(default_factory=dict)
    claude_session_id: str = ""
    # 這一輪要不要順手把整台執行器標成 limited（weekly limit 用）
    runner_limit_reason: str = ""


class RepoLockTimeout(Exception):
    """等 repo 鎖等到牆鐘上限（除錯報告 09/21）。帶著卡住的 key 與持有者短碼。"""

    def __init__(self, keys: list[str], holders: dict[str, str]) -> None:
        self.keys = keys
        self.holders = holders
        super().__init__(f"等 repo 鎖逾時：{keys}")


class RepoLocks:
    """每個 repo 一把鎖（§5.5）。跨 repo 的票序列做，第一階段不開 worktree。"""

    def __init__(self) -> None:
        self._locks: dict[str, asyncio.Lock] = {}
        # key → 目前握著它的 run 短碼。**只給人看**（等待通知用），
        # 不參與鎖本身的邏輯——鎖的正確性完全靠 asyncio.Lock
        self._holders: dict[str, str] = {}

    @contextlib.asynccontextmanager
    async def hold(self, keys: list[str], *, run_id: str = "",
                   timeout: float | None = None,
                   on_wait: Callable[[list[str], dict[str, str]],
                                     Awaitable[None]] | None = None):
        """一次握住多把鎖（寫入型 run 會動專案底下每一個 repo）。

        🚨 **取得順序在這裡重排成 key 的字典序**，不照傳進來的順序：呼叫端給
        的是 `project_repos()` 的順序（主 repo 在前），而同一個專案的兩筆 run
        主 repo 不同時那個順序就不一樣——A 拿到 web 等 api、B 拿到 api 等 web
        就是一個死鎖，而它在面板上與「兩筆都在跑」長得一模一樣。
        釋放走 `AsyncExitStack`，順序與取得相反。

        🚨 **卡在鎖上要讓外面看得到**（除錯報告 09/21：`a70bcd9a` 領到單後
        一路等到這裡，Hub 上停在 claimed、沒有回報、沒有 run 目錄、log 一
        個字都沒有，跟「執行器掛了」長得一模一樣）。任何一把鎖已經被佔用時
        先呼叫一次 ``on_wait``（帶著被卡住的 key 與持有者短碼），呼叫端拿
        這個機會回報一次 running 並留一行 log。``timeout`` 給每一把鎖的
        `acquire()` 設上限；逾時就整段放棄，丟 `RepoLockTimeout` 讓呼叫端
        收成 failed——不然一筆卡住的 run 會把併發位置吃到天荒地老，而且
        看起來跟「它在正常等待」一模一樣。
        """
        seen = sorted(set(keys))
        held_keys = [k for k in seen if self.is_held(k)]
        if held_keys and on_wait is not None:
            holders = {k: self._holders.get(k, "") for k in held_keys}
            await on_wait(held_keys, holders)
        async with contextlib.AsyncExitStack() as stack:
            for key in seen:
                lock = self.get(key)
                if timeout is None:
                    await lock.acquire()
                else:
                    try:
                        await asyncio.wait_for(lock.acquire(), timeout=timeout)
                    except asyncio.TimeoutError:
                        holders = {k: self._holders.get(k, "")
                                   for k in seen if self.is_held(k)}
                        raise RepoLockTimeout(seen, holders) from None
                stack.callback(self._release, key, lock)
                if run_id:
                    self._holders[key] = run_id
            yield

    def _release(self, key: str, lock: asyncio.Lock) -> None:
        self._holders.pop(key, None)
        lock.release()

    def get(self, key: str) -> asyncio.Lock:
        lock = self._locks.get(key)
        if lock is None:
            lock = asyncio.Lock()
            self._locks[key] = lock
        return lock

    def is_held(self, key: str) -> bool:
        lock = self._locks.get(key)
        return bool(lock and lock.locked())


def project_repos(project: WorkspaceConfig,
                  primary: ProjectConfig) -> list[ProjectConfig]:
    """這次派工可以動的 repo，**主工作目錄排第一**。

    順序是固定的：附註、prompt 與快照三處都照這個順序列，主 repo 換位置的話
    同一份報告在兩輪之間會長得不一樣。
    """
    ordered = [primary]
    for name in sorted(project.projects):
        item = project.projects[name]
        if item.name != primary.name:
            ordered.append(item)
    return ordered


def _repo_touched(diff: dict) -> bool:
    """這個 repo 這一輪有沒有被動過（新 commit、未提交變更或換分支）。"""
    return bool(diff["head_changed"] or diff["new_dirty"]
                or diff["branch_changed"])


def _repo_diff_lines(diff: dict, prefix: str) -> list[str]:
    """一個 repo 的 HEAD／分支／未 commit 變更條列。

    ``prefix`` 決定縮排：單 repo 是頂層的 ``"- "``，多 repo 時掛在 repo 那一
    節底下（``"    - "``）。
    """
    indent = " " * (len(prefix) - 2)
    lines = [f"{prefix}HEAD：{(diff['head_before'] or '?')[:8]} → "
             f"{(diff['head_after'] or '?')[:8]}"
             f"{'，有新 commit' if diff['head_changed'] else ''}"]
    if diff["branch_changed"]:
        lines.append(f"{prefix}分支已變更：{diff['branch_before']} → "
                     f"{diff['branch_after']}")
    if diff["new_dirty"]:
        dirty = diff["new_dirty"][:20]
        if len(dirty) == 1:
            lines.append(f"{prefix}未 commit 的變更：{dirty[0]}")
        else:
            lines.append(f"{prefix}未 commit 的變更（{len(dirty)} 個檔案）：")
            lines.extend(f"{indent}    - {name}" for name in dirty)
    return lines


def resolve_repo(run: dict, project: WorkspaceConfig) -> ProjectConfig:
    """這筆 run 在哪個 repo 做。**規則寫死在這裡，brief 只能「指名」不能「指路」。**

    1. ``push``：``ref`` 就是 repo key（§5.6 的形狀是固定的）。
    2. brief 裡有一行 ``repo: <name>``：用那個（必須在專案的 repos 裡）。
    3. 工作區只有一個專案，或設了 ``default_project``：用它。
    4. 以上都不成立 ⇒ 失敗。**不猜**：猜錯的代價是在錯的工作樹上 commit。
    """
    repos = project.projects
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
                f"簡述指名的 repo「{name}」不在專案 {project.key} 的允許清單裡。"
                f"可用：{'、'.join(repos)}。")
        return repo
    if project.default_project:
        return repos[project.default_project]
    raise RunSetupError(
        f"工作區 {project.key} 有多個專案且沒有設 default_project，"
        "請在簡述裡加一行 `repo: <名稱>`。"
        f"可用：{'、'.join(repos)}。")


def short_id(run_id: str) -> str:
    """run id 的短碼。目前只給人看（日誌、訊息），**不再拿來當房內名字**。"""
    return (run_id or "")[:8] or "run"


def kill_tree(pid: int) -> None:
    """殺子進程**連同它的子孫**。

    claude 會自己起 MCP server 等子進程；只殺父的話，那些子進程會留著，
    而下一輪看到的是一個「已經結束」的 run 與一堆還連著 Hub 的殭屍。
    """
    if os.name == "nt":
        try:
            res = subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"],
                                 capture_output=True, timeout=20, check=False,
                                 **no_window_kwargs())
            # 🚨 失敗不能悄悄吞掉：呼叫端只等到 `proc.wait()`（只追蹤最上層
            # 那一個 PID），taskkill 沒殺乾淨子孫的話不會有任何例外，
            # 下一輪重試會在還有殘留進程的狀況下起跑而沒有人知道
            if res.returncode != 0:
                log.warning("taskkill /PID %s /T /F 沒有乾淨結束"
                           "（returncode=%s）：%s", pid, res.returncode,
                           (res.stderr or res.stdout or b"")
                           .decode("utf-8", "replace").strip())
            return
        except (OSError, subprocess.SubprocessError) as exc:
            log.warning("taskkill /PID %s 起不來：%s", pid, exc)
            return
    try:  # pragma: no cover - 非 Windows 路徑
        os.kill(pid, 9)
    except OSError as exc:
        log.warning("os.kill(%s, 9) 失敗：%s", pid, exc)


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
        # 等 repo 鎖時已經回報過一次 running（除錯報告 09/21）。
        # `_claude_run` 起跑前不用再報一次「running/spawn」——那會撞上
        # Hub 的 running→running 白名單，變成一句無害但誤導人的 409 警告
        self._pre_reported_running = False

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
                result=f"執行器發生未預期的例外："
                       f"{exc.__class__.__name__}: {exc}\n"
                       "子進程已終止，詳細堆疊在執行器的 log。")
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
            # run["project"] 是 Hub 的 project key ＝ 本機工作區 key
            project = self.cfg.workspace(run["project"])
            repo = resolve_repo(run, project)
        except Exception as exc:
            outcome = RunOutcome("failed", reason="setup_error",
                                 result=str(exc))
            await self._report(run_id, outcome)
            return outcome

        if run["kind"] == "push":
            # 🚨 先回報 running 再推：Hub 的狀態機只讓 done 從 running 來，
            # 直接從 claimed 報 done 會吃 409，而 409 在客戶端是「當成已套用」
            # 的——推成功了，面板上卻還停在 claimed
            await self._report(run_id, RunOutcome("running",
                                                  reason="push_start"))
            async with self.locks.get(f"{project.key}/{repo.name}"):
                outcome = await self._push(run, repo)
            await self._report(run_id, outcome)
            return outcome

        if run["kind"] in WRITE_KINDS:
            # 寫入型 run 可以動專案底下**每一個** repo，所以鎖也要拿全部：
            # 只鎖主 repo 的話，兩筆主 repo 不同的 run 會同時寫同一個副 repo，
            # 而那是「同一個 repo 只允許一個寫入者」本來就要擋掉的事
            keys = [f"{project.key}/{item.name}"
                    for item in project_repos(project, repo)]

            if not single_writer(run):
                # 房間自己關掉了單一寫入者限制（Hub 從房間帶出這個欄位）：
                # claude 進程並行跑，不排隊。守衛（PreToolUse 的 git 與寫入
                # 範圍）一點都沒有變鬆，鬆掉的只有排隊這條規則。
                # 🚨 **派工前的同步仍然要序列化**（敏卡裁決 09/21）：兩筆同時
                # 在同一份工作樹上 `git pull --ff-only` 會對撞（實測
                # `fatal: Cannot fast-forward to multiple branches.`），輸的
                # 那筆以 sync_not_fast_forward 收場——那是並行的副作用，不是
                # 它自己的問題。同步完就放鎖，之後兩筆並行
                log.warning("run %s：%s", run_id, PARALLEL_WRITE_NOTE)
                try:
                    return await self._claude_run(run, project, repo, cancel,
                                                  sync_keys=keys)
                except RepoLockTimeout as exc:
                    return await self._report_lock_timeout(run_id, project,
                                                           exc)

            async def _on_wait(held_keys: list[str],
                               holders: dict[str, str]) -> None:
                blockers = "、".join(
                    holders.get(k) or k for k in held_keys)
                log.warning("run %s 等待 repo 鎖，卡在：%s", run_id, blockers)
                await self._report(run_id, RunOutcome(
                    "running", reason="repo_lock_wait",
                    result=f"等待同一 repo 的 run {blockers} 完成。"))
                self._pre_reported_running = True

            try:
                async with self.locks.hold(
                        keys, run_id=short_id(run_id),
                        timeout=project.wall_clock_seconds,
                        on_wait=_on_wait):
                    return await self._claude_run(run, project, repo, cancel)
            except RepoLockTimeout as exc:
                return await self._report_lock_timeout(run_id, project, exc)
        return await self._claude_run(run, project, repo, cancel)

    async def _report_lock_timeout(self, run_id: str,
                                   project: WorkspaceConfig,
                                   exc: RepoLockTimeout) -> RunOutcome:
        """等 repo 鎖逾時的收場。整筆鎖與並行分支的同步鎖共用同一份訊息。"""
        blockers = "、".join(
            exc.holders.get(k) or k for k in exc.keys) or "未知"
        log.error("run %s 等 repo 鎖逾時（%s 秒），卡在：%s",
                  run_id, int(project.wall_clock_seconds), blockers)
        outcome = RunOutcome(
            "failed", reason="repo_lock_timeout",
            result=f"等待同一 repo 的 run {blockers} 完成，"
                   f"超過 {int(project.wall_clock_seconds)} 秒仍未"
                   "取得鎖，已收場。")
        await self._report(run_id, outcome)
        return outcome

    # ---------- push（不經模型，§5.6）----------

    async def _push(self, run: dict, repo) -> RunOutcome:
        brief = run.get("brief") or ""
        branch = self._push_branch(brief) or await gitops.current_branch(
            repo.path)
        if not repo.allows_push(branch):
            return RunOutcome(
                "failed", reason="push_branch_not_allowed",
                result=f"分支「{branch}」不在 {repo.name} 的可推清單裡，"
                       "沒有推送。可推："
                       f"{'、'.join(repo.push_branches) or '無'}。")
        # 🚨 先 fetch 再算未推送：不 fetch 的話比對的是上次 fetch 時的遠端
        # 位置，而那份清單同時是「按鈕的人看到什麼」的依據。fetch 失敗＝不知
        # 道遠端現在長什麼樣子，這時推上去是盲推
        fetched = await gitops.git(repo.path, *self._push_credential_args(),
                                   "fetch", "origin", branch)
        if not fetched.ok:
            return RunOutcome(
                "failed", reason="push_fetch_failed",
                result=f"git fetch origin {branch} 失敗，沒有推送："
                       f"{fetched.err or fetched.out}")
        expected = {s for s in _SHA_RE.findall(brief.lower())
                    if s != branch.lower()}
        if not expected:
            return RunOutcome(
                "failed", reason="push_sha_list_missing",
                result="這筆 push 沒有帶要推的 commit 清單，沒有推送。"
                       "請從儀表板重新按一次推送。")
        actual = [c.sha for c in await gitops.unpushed(repo.path, branch)]
        if not self._sha_sets_match(expected, actual):
            return RunOutcome(
                "failed", reason="push_sha_mismatch",
                result=(f"待推的 commit 與派工當下看到的不一致，沒有推送。\n"
                        f"現在是 {len(actual)} 顆："
                        f"{', '.join(a[:8] for a in actual) or '無'}\n"
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
            result=f"已推送 {repo.name} 的 {branch}，"
                   f"共 {len(actual)} 顆 commit。")

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

    async def _sync_worktree(self, repo) -> str:
        """派工前把常駐工作樹更新到最新，回一句要寫進收工摘要的 note。

        run 之間共用同一份工作樹，不先同步的話 agent 會在上一輪留下的舊基礎
        上動工。三種情況各自有代價，所以分開處理：

        - 工作樹髒：**不 pull**。別人（或上一輪）未提交的東西比「最新」重要，
          照常執行，只在摘要裡講清楚這一輪沒同步。
        - fetch 失敗：多半是網路，不值得擋掉整筆 run。
        - 不能快轉：分支已經分岔，往下跑等於在錯的基礎上做事，直接失敗。
        """
        dirty = await gitops.status_porcelain(repo.path)
        if dirty:
            return "工作樹有未提交變更，未同步遠端。"
        if not await gitops.has_upstream(repo.path):
            return "目前分支沒有 upstream，未同步遠端。"
        fetched = await gitops.fetch(repo.path)
        if not fetched.ok:
            log.warning("同步 %s 時 fetch 失敗：%s", repo.name,
                        fetched.err or fetched.out)
            return "fetch 失敗，於本機現況執行。"
        pulled = await gitops.pull_ff(repo.path)
        if not pulled.ok:
            raise _SyncBlocked(
                "分支落後遠端且無法快轉，請先手動處理。\n"
                f"git pull --ff-only：{pulled.summary}")
        return pulled.summary

    async def _claude_run(self, run: dict, project: WorkspaceConfig, repo,
                          cancel: asyncio.Event,
                          sync_keys: list[str] | None = None) -> RunOutcome:
        run_id = run["id"]
        run_dir = self.cfg.runs_dir / run_id
        run_dir.mkdir(parents=True, exist_ok=True)
        # 一次派工可以動專案底下**每一個** repo（主工作目錄仍是被選中的那個），
        # 所以分支檢查、同步與快照都要對全部做：只顧主 repo 的話，另一個 repo
        # 會在沒有檢查、沒有同步、也沒有人記得它動過什麼的狀態下被改
        repos = project_repos(project, repo)
        branches: dict[str, str] = {}
        for item in repos:
            branch = await gitops.current_branch(item.path)
            branches[item.name] = branch
            if not item.allows(branch):
                outcome = RunOutcome(
                    "failed", reason="branch_not_allowed",
                    result=f"{item.name} 目前在分支「{branch}」，不在允許清單裡。"
                           f"允許的分支：{'、'.join(item.allowed_branches)}。")
                await self._report(run_id, outcome)
                return outcome
        branch = branches[repo.name]

        # 🚨 同步要在快照**之前**：pull 帶進來的變更不是 agent 改的，
        # 先拍快照的話那些檔案會被算進「這一輪動了什麼」
        sync_notes: dict[str, str] = {}

        async def _sync_all() -> str:
            """全部 repo 同步一輪。回傳空字串或要收場的失敗說明。"""
            for item in repos:
                try:
                    sync_notes[item.name] = await self._sync_worktree(item)
                except _SyncBlocked as exc:
                    return (f"{item.name}：{exc}" if len(repos) > 1
                            else str(exc))
            return ""

        # `sync_keys` 有值 ＝ 這筆 run 不排整筆的 repo 鎖（房間關掉了單一寫入
        # 者限制），但**同步這一段仍然要獨佔**：兩筆同時 `git pull --ff-only`
        # 會對撞。拿完就放，claude 進程照樣並行。等這一段不回報 running
        # （通常只有幾秒，報了反而多一筆雜訊），但 log 要留得到
        if sync_keys:
            if any(self.locks.is_held(k) for k in set(sync_keys)):
                log.info("run %s 等 repo 鎖以完成派工前同步（並行模式）", run_id)
            async with self.locks.hold(sync_keys, run_id=short_id(run_id),
                                       timeout=project.wall_clock_seconds):
                detail = await _sync_all()
        else:
            detail = await _sync_all()
        if detail:
            outcome = RunOutcome("failed", reason="sync_not_fast_forward",
                                 result=detail)
            await self._report(run_id, outcome)
            return outcome

        before = {item.name: await gitops.snapshot(item.path)
                  for item in repos}
        fields = {
            "run_id": run_id, "room_id": run.get("room_id", ""),
            "kind": run["kind"], "project": project.key,
            "ref": run.get("ref", ""), "repo": repo.name,
            "cwd": str(repo.path), "branch": branch,
            "allowed_branches": "、".join(repo.allowed_branches),
            "repos_block": prompts.repos_block([
                {"name": item.name, "path": str(item.path),
                 "branch": branches[item.name],
                 "allowed_branches": list(item.allowed_branches),
                 "primary": item.name == repo.name}
                for item in repos]),
            "repo_names": "、".join(item.name for item in repos),
            "skills_block": prompts.skills_block(
                project.skills_for(run["kind"])),
            "primary_skill_block": prompts.primary_skill_block(
                project.primary_skill),
            "livetest_block": prompts.livetest_block(
                project.allow_browser_livetest),
        }
        prompt = prompts.build(run["kind"], fields, run.get("brief", ""),
                               self.prompt_dir)
        contract = prompts.build_contract(fields, self.prompt_dir)
        self._write_run_files(run_dir, run, repo, project)
        env = self._child_env(run, run_dir)

        # 等 repo 鎖時已經報過一次 running（`_on_wait`）：這裡再報 spawn
        # 會是 running→running 且 reason 不在 Hub 的同狀態白名單裡，
        # 送出去只換一句無害但誤導人的 409 警告
        if not self._pre_reported_running:
            # 並行寫入時附註要帶一句：面板上只看得到回報，看不到執行器的 log，
            # 而「這筆 run 沒有獨佔工作樹」是看結果的人需要知道的前提
            note = ("" if single_writer(run) or run["kind"] not in WRITE_KINDS
                    else PARALLEL_WRITE_NOTE)
            await self._report(run_id, RunOutcome("running", reason="spawn",
                                                  result=note))

        resume: str = ""
        backoffs = list(self.cfg.backoff_minutes)
        attempt = 0
        mcp_attempt = 0
        # 最後一次 bridge 探測的附註。重試耗盡時的收工附註要帶這句，不然只
        # 看得到「pending」，看不到「為什麼」（探測到的 import 錯誤、連線
        # 被拒等）——見 09/21 run 57c3ae48 的除錯
        last_mcp_probe = ""
        outcome = RunOutcome("failed", reason="never_ran")
        while True:
            # 每一輪（含退避後的 --resume）重新起算：剛起的進程還沒吐東西，
            # 不該立刻被上一輪的沉默判成停滯
            self.mark_activity()
            # chatroom 開場沒連上時由這個事件把子進程叫停。每一輪一個新的：
            # 上一輪立過的旗子不能讓這一輪一起跑就被判死
            mcp_not_ready = asyncio.Event()
            watcher = StreamWatcher(
                project.context_soft_limit_tokens,
                on_soft_limit=lambda n, d=run_dir: self._raise_handoff(d, n),
                rate_limit_threshold=self.cfg.rate_limit_retry_threshold,
                monotonic=self.monotonic,
                on_event=self.mark_activity,
                on_init_mcp=lambda servers, ev=mcp_not_ready, rid=run_id:
                    self._check_init_mcp(servers, ev, rid))
            argv = self._argv(prompt, contract, project, run_dir,
                              resume, run["kind"])
            code, stop_reason = await self._spawn(argv, repo.path, env,
                                                  watcher, run_dir,
                                                  project.wall_clock_seconds,
                                                  cancel, mcp_not_ready)
            state = watcher.state
            self.context_peak = max(self.context_peak,
                                    state.peak_context_tokens)
            self.turns = state.num_turns
            self._record_usage(run_id, state)
            if (stop_reason == "mcp_not_ready"
                    and mcp_attempt < self.cfg.mcp_retries
                    and not cancel.is_set()):
                mcp_attempt += 1
                wait_seconds = self._mcp_backoff(mcp_attempt)
                probe = await self._probe_bridge(env)
                last_mcp_probe = probe
                # 🚨 reason 一定要落在 Hub 的同狀態白名單（`stalled`／
                # `resumed`）：這裡是 running→running 的同狀態回報，帶別的
                # reason（曾經是 `mcp_retry_N`）一律撞 409 run_bad_transition
                # （實測 09/20 run 5ba6caa5、09/21 run 57c3ae48）。回報本身
                # 無害（`hub.report` 早就把這種 409 當成已套用），但每次重試
                # 都在 log 裡留一則看起來像失敗的警告，混淆了真正的根因
                # ——重試細節照樣寫在 result 裡，房裡看得到
                await self._report(run_id, RunOutcome(
                    "running", reason="resumed",
                    result=f"chatroom MCP 開場未連上"
                           f"（{self._mcp_status_text(state)}），"
                           f"{wait_seconds:g} 秒後重起，"
                           f"第 {mcp_attempt} 次重試。{probe}"))
                await self.sleep(wait_seconds)
                if cancel.is_set():
                    outcome = RunOutcome("cancelled",
                                         reason="cancel_requested",
                                         result="等待 chatroom MCP 期間收到取消。")
                    break
                # 重起是**全新的一輪**：上一輪連房都沒進，沒有值得續的 session
                resume = ""
                continue
            outcome = self._classify(state, code, stop_reason, run_dir,
                                     watcher.rate_limited)
            after = {item.name: await gitops.snapshot(item.path)
                     for item in repos}
            outcome.result = self._compose_result(state, run_dir, before,
                                                  after, sync_notes)
            if outcome.reason == MCP_UNAVAILABLE_REASON:
                outcome.result = (
                    f"chatroom MCP 在 {mcp_attempt + 1} 次嘗試內都沒有連上"
                    f"（{self._mcp_status_text(state)}）。"
                    "進房是這筆 run 的前置條件——沒有進房就讀不到卡與階段素材，"
                    "整輪只會是盲做，因此已中止，沒有執行任何工作。"
                    # pending 多半是 bridge 冷啟動比 MCP 逾時慢，跟「進房被拒」
                    # 是兩回事：join 403 發生在 agent 自己呼叫 chatroom_join
                    # 的那一步，早於這裡看到的 init 快照，這裡探不到那句話。
                    # 能帶出來的只有 bridge 起得來起不來——一樣要講，不然只
                    # 看得到 pending，看不到「為什麼」
                    + (f"（{last_mcp_probe}）" if last_mcp_probe else "")
                    + "\n\n" + outcome.result)
            if outcome.reason != "rate_limit" or not backoffs:
                break
            wait_minutes = backoffs.pop(0)
            attempt += 1
            await self._report(run_id, RunOutcome(
                "limited", reason=f"rate_limit_backoff_{wait_minutes}m",
                result=f"已達額度上限，{wait_minutes} 分鐘後續跑，"
                       f"第 {attempt} 次退避。",
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

    def _argv(self, prompt: str, contract: str, project: WorkspaceConfig,
              run_dir: Path, resume: str, kind: str = "") -> list[str]:
        # 優先載入的 skill 不分 kind 都要授權，否則契約叫它就卡權限提示
        tools = allowed_tools(kind, self.cfg.extra_allowed_tools,
                              project.all_skills_for(kind))
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
            "--max-budget-usd", str(project.max_budget_usd),
            "--mcp-config", str(run_dir / "mcp.json"),
            "--settings", str(run_dir / "settings.json"),
            "--append-system-prompt", contract,
        ]
        for extra_dir in project.skill_dirs:
            # 專案的 skill 常常放在 cwd 的上一層（cwd 自己是子 repo，skill
            # 發現只往上找到 git root 就停）。`--add-dir` 進來的目錄其
            # `.claude/skills/` 會載入——沒有這一行，契約叫的 skill 根本不存在
            argv += ["--add-dir", str(extra_dir)]
        if denied:
            # 第二道：把連接器的工具從 context 移除。第一道是 settings 的
            # `deniedMcpServers`（伺服器根本不載入），見 KNOWN_CLAUDE_AI_SERVERS
            argv += ["--disallowedTools", ",".join(denied)]
        if project.max_turns > 0:
            # 預設不設：輪數不是硬限制，context 才是（config.DEFAULT_MAX_TURNS）
            argv += ["--max-turns", str(project.max_turns)]
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
            # 名字留空＝讓 Hub 從名字池發一個名號。塞 `<label>-<run 短碼>`
            # 的話，房間成員列上顯示的就是一串 id；run 的識別本來就在
            # `participant.run_id`，不必靠名字帶。
            # **空字串是必要的**：不寫這一鍵會沿用執行器自己的
            # CHATROOM_DEFAULT_NAME（`env = dict(os.environ)`），run 會頂著
            # 執行器的代稱進房。bridge 的 .env 載入也只補「不在 env 裡」的鍵。
            "CHATROOM_DEFAULT_NAME": "",
            "CHATROOM_RUNNER_RUN_DIR": str(run_dir),
            "CHATROOM_DOWNLOAD_DIR": str(run_dir / DOWNLOADS_DIR_NAME),
        })
        if self.cfg.mcp_startup_timeout_ms > 0:
            # MCP 伺服器的啟動／連線逾時（docs/en/mcp「Timeouts &
            # Performance」，單位毫秒，stdio 也適用）。第一道防線：bridge
            # 冷啟動比預設的等待久時，拉長等待比事後重起便宜
            env["MCP_TIMEOUT"] = str(self.cfg.mcp_startup_timeout_ms)
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

    def _bridge_dir(self) -> Path:
        """bridge（`chatroom_mcp`）的模組路徑。run 的 mcp.json 也用同一份。"""
        return self.cfg.bridge_path or (
            Path(__file__).resolve().parents[2] / "bridge")

    def _mcp_backoff(self, attempt: int) -> float:
        """第 ``attempt`` 次重試前等幾秒。用完最後一段就一直沿用它。"""
        waits = [float(x) for x in self.cfg.mcp_retry_backoff_seconds]
        if not waits:
            return 0.0
        return waits[min(attempt, len(waits)) - 1]

    @staticmethod
    def _mcp_status_text(state) -> str:
        servers = state.mcp_servers or {}
        status = servers.get(REQUIRED_MCP_SERVER)
        if status is None:
            return f"init 事件裡沒有 {REQUIRED_MCP_SERVER}"
        return f"{REQUIRED_MCP_SERVER}：{status}"

    def _check_init_mcp(self, servers: dict[str, str],
                        event: asyncio.Event, run_id: str) -> None:
        """init 的 MCP 快照 ⇒ 這一輪還能不能跑。

        ``connected`` 以外的任何狀態（``pending``／``failed``／根本沒列出來）
        都當作不能跑：**開場沒連上就不會有第二個事件來更正**，而 agent 看到
        工具不在時會自己找路走，那條路上沒有卡、沒有房、也沒有人在看。
        """
        status = servers.get(REQUIRED_MCP_SERVER)
        if status == "connected":
            return
        log.warning("run %s：chatroom MCP 開場狀態為 %s，中止這一輪",
                    run_id, status or "（未列出）")
        event.set()

    async def _probe_bridge(self, env: dict) -> str:
        """重試前探一次 bridge 能不能 import。回一句要寫進回報的附註。

        探得過不代表下一輪一定連得上（那是啟動時序），但探不過就**確定**連不
        上——那時重試多少次都一樣，把原因寫出來比再等 30 秒有用。
        順帶把 bytecode 快取熱起來，下一次 import 會快一點。
        """
        probe_env = dict(env)
        probe_env["PYTHONPATH"] = str(self._bridge_dir())
        try:
            proc = await asyncio.create_subprocess_exec(
                sys.executable, "-c", "import chatroom_mcp",
                env=probe_env,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE, **no_window_kwargs())
        except OSError as exc:
            return f"（bridge 探測起不來：{exc}）"
        try:
            _, err = await asyncio.wait_for(
                proc.communicate(), timeout=BRIDGE_PROBE_TIMEOUT_SECONDS)
        except asyncio.TimeoutError:
            kill_tree(proc.pid)
            return "（bridge 探測逾時）"
        if proc.returncode == 0:
            return ""
        detail = err.decode("utf-8", "replace").strip().splitlines()
        return f"（bridge 探測失敗：{detail[-1] if detail else proc.returncode}）"

    async def _spawn(self, argv: list[str], cwd: Path, env: dict,
                     watcher: StreamWatcher, run_dir: Path,
                     wall_clock: float,
                     cancel: asyncio.Event,
                     mcp_not_ready: asyncio.Event | None = None
                     ) -> tuple[int, str]:
        """起進程並逐行吃 stream。回 ``(exit_code, 停止原因)``。"""
        proc = await asyncio.create_subprocess_exec(
            *argv, cwd=str(cwd), env=env,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            limit=STREAM_LINE_LIMIT, **no_window_kwargs())
        self.live_proc = proc
        pump = asyncio.create_task(self._pump(proc, watcher, run_dir))
        waiter = asyncio.create_task(proc.wait())
        canceller = asyncio.create_task(cancel.wait())
        # chatroom 開場沒連上時由這一條把進程叫停（見 REQUIRED_MCP_SERVER）
        mcp_waiter = (asyncio.create_task(mcp_not_ready.wait())
                      if mcp_not_ready is not None else None)
        stop = "exited"
        try:
            waits = {waiter, canceller}
            if mcp_waiter is not None:
                waits.add(mcp_waiter)
            done, _ = await asyncio.wait(
                waits,
                timeout=wall_clock if wall_clock > 0 else None,
                return_when=asyncio.FIRST_COMPLETED)
            if waiter not in done:
                if canceller in done:
                    # 取消優先：人按了取消就是取消，即使 MCP 也沒連上
                    stop = "cancelled"
                elif mcp_waiter is not None and mcp_waiter in done:
                    stop = "mcp_not_ready"
                else:
                    stop = "wall_clock"
                kill_tree(proc.pid)
                try:
                    await asyncio.wait_for(waiter, timeout=30)
                except asyncio.TimeoutError:  # pragma: no cover
                    proc.kill()
                    await waiter
        finally:
            canceller.cancel()
            if mcp_waiter is not None:
                mcp_waiter.cancel()
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
            # 收尾請求逾時被硬殺的，理由要說得出是**哪一件事**把它殺掉的：
            # 都報 `cancel_requested` 的話，事後看到的是一筆「有人按了取消」，
            # 而實際上沒有人按過
            reason = ("soft_stop_timeout"
                      if (run_dir / SOFT_STOP_TIMEOUT_FLAG_NAME).exists()
                      else "cancel_requested")
            return RunOutcome("cancelled", reason=reason,
                              usage=usage, claude_session_id=sid)
        if stop_reason == "wall_clock":
            return RunOutcome("failed", reason="wall_clock", usage=usage,
                              claude_session_id=sid)
        if stop_reason == "mcp_not_ready":
            # 重試已經在 `_claude_run` 用完了；走到這裡就是前置條件不成立
            return RunOutcome("failed", reason=MCP_UNAVAILABLE_REASON,
                              usage=usage, claude_session_id=sid)
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
                        before: dict[str, gitops.RepoSnapshot],
                        after: dict[str, gitops.RepoSnapshot],
                        sync_notes: dict[str, str] | None = None) -> str:
        """收工附註。``before``／``after`` 以 repo 名為 key，**主 repo 排第一**。

        單 repo 專案維持原本的平鋪格式；多 repo 時每個 repo 一節，只列有變動
        或有新 commit 的——全都沒動就只列主 repo，讓讀的人知道那一節不是漏掉。
        """
        sync_notes = dict(sync_notes or {})
        names = list(before)
        primary = names[0] if names else ""
        diffs = {name: gitops.diff_snapshots(before[name], after[name])
                 for name in names}
        lines = [state.result_text.strip()] if state.result_text.strip() else []
        if (run_dir / SOFT_STOP_FLAG_NAME).exists():
            # 擺在最前面：看報告的人要先知道這一份**不是做完才停的**，
            # 後面那些「沒做的事」才讀得出是被請下來的，不是漏掉的
            lines.insert(0, "（依收尾請求提前結束）")
        # 🚨 附註走 **markdown 條列**，不是逐行純文字：App 端用 GFM 算繪，
        # 單一個換行會被吃掉，整段附註在手機上黏成一條讀不出欄位的長句
        lines.append("")
        lines.append("— 執行器附註 —")
        lines.append("")
        lines.append(f"- turns：{state.num_turns}")
        lines.append(f"- 成本：${state.total_cost_usd:.4f}")
        lines.append(f"- context 峰值：{state.peak_context_tokens} tokens")
        if len(names) <= 1:
            lines.extend(_repo_diff_lines(diffs[primary], "- ") if primary
                         else [])
        else:
            shown = [name for name in names if _repo_touched(diffs[name])]
            if not shown:
                shown = [primary]
            for name in shown:
                lines.append(f"- {name}")
                lines.extend(_repo_diff_lines(diffs[name], "    - "))
        if state.pending_mcp_servers:
            lines.append("- 開場時未就緒的 MCP："
                         + "、".join(state.pending_mcp_servers))
        for name in names:
            note = sync_notes.get(name, "")
            if not note:
                continue
            # 同步的結果不跟著「有沒有變動」走：fetch 失敗或工作樹本來就髒的
            # repo 照樣要說出來，那正是「這一輪不是在最新的基礎上做的」
            label = "工作樹同步" if len(names) <= 1 else f"工作樹同步（{name}）"
            lines.append(f"- {label}：{note}")
        if (run_dir / "compacted").exists():
            lines.append("- 這一輪被自動壓縮過，摘要中前段的敘述是二手的。")
        tool_log = run_dir / "tool.log"
        if tool_log.exists():
            n = sum(1 for _ in tool_log.open(encoding="utf-8"))
            lines.append(f"- 工具呼叫 {n} 次，完整紀錄：`{tool_log}`")
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

    def _write_run_files(self, run_dir: Path, run: dict, repo,
                         project: WorkspaceConfig | None = None) -> None:
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

        bridge = self._bridge_dir()
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
                # 同 `_child_env`：留空讓 Hub 的名字池取名，不要把 run id
                # 當名字。這一鍵不能省——省掉會沿用外層的代稱
                "CHATROOM_DEFAULT_NAME": "",
                # 附件落在 run 目錄底下，不是 cwd。bridge 預設會寫
                # `./.chatroom/downloads/`，那個「.」是被派工的 repo
                "CHATROOM_DOWNLOAD_DIR": str(run_dir / DOWNLOADS_DIR_NAME),
                # 不帶這個 bridge 會落回 other，成員列顯示 OTHER
                "CHATROOM_AGENT_KIND": AGENT_KIND,
            },
        }}}
        # 允許清單勾到的全域伺服器（fff、mempal 這種）：定義原樣複製進來，
        # 不然 run 用的是執行器的設定目錄，那裡根本沒有它們。chatroom 永遠
        # 是上面那一份，不被全域同名的蓋掉
        for name, spec in global_mcp_definitions(
                self.cfg.allowed_mcp_servers, reserved=("chatroom",)).items():
            mcp["mcpServers"].setdefault(name, spec)
        (run_dir / "mcp.json").write_text(
            json.dumps(mcp, ensure_ascii=False, indent=2), encoding="utf-8")

        # 下載目錄先建起來：guard 的放行是比對路徑，但 bridge 要寫得進去
        downloads = run_dir / DOWNLOADS_DIR_NAME
        downloads.mkdir(parents=True, exist_ok=True)

        ctx = GuardContext(
            cwd=repo.path,
            # 專案底下所有 repo 都可以動，主工作目錄只是其中一個
            repo_roots=([r.path for r in project_repos(project, repo)]
                        if project else [repo.path]),
            allowed_branches=list(repo.allowed_branches),
            allowed_domains=list(self.cfg.allowed_domains),
            protected_paths=[self.cfg.state_dir, self.cfg.claude_config_dir,
                             HOOKS_DIR.parent],
            # run 目錄整個在 state_dir 底下，本來會被「執行器自己的目錄」擋掉。
            # 附件是 agent 自己要來的，讀得到才有意義——只鑿這一個洞
            downloads_dir=downloads,
            # 設定檔替這個專案放行的額外寫入目錄（skill 要求的產出落在 repo
            # 外面時）。敏感檔名的檢查照走
            extra_write_dirs=list(project.extra_write_dirs) if project
            else [],
        )
        (run_dir / "guard.json").write_text(
            json.dumps(ctx.to_dict(), ensure_ascii=False, indent=2),
            encoding="utf-8")
