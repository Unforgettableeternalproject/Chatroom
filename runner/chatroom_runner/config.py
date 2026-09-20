"""執行器設定（REMOTE-OPS-PLAN §5.2／§6.4）。

設定**全部來自 JSON 檔**，不寫在程式碼裡：repo 路徑、允許分支、模型、上限都是
這台機器的事，硬編碼進來的話換一台機器就要改程式，而「改程式」在遠端無人看著
時是最貴的一種變更。

檔案位置依序：

1. 環境變數 ``CHATROOM_RUNNER_CONFIG``
2. ``%LOCALAPPDATA%/UEP/Chatroom/runner/config.json``（Windows）
3. ``~/.local/share/uep/chatroom/runner/config.json``（其他平台）

Hub 憑證（``agent_token``）可以三種來源，由近到遠：設定檔 ``agent_token``、
環境變數 ``CHATROOM_TOKEN``、``token_env_file`` 指到的 ``.env``（沿用 bridge
讀 ``server/.env`` 的做法）。**不要把 token 印進 log**。
"""

from __future__ import annotations

import fnmatch
import json
import logging
import os
from dataclasses import dataclass, field
from pathlib import Path

log = logging.getLogger("chatroom_runner.config")

# 預設值集中在這裡，改一個地方就好
DEFAULT_MAX_PARALLEL = 3
DEFAULT_MODEL = "claude-opus-5"
# 0 ＝ 不設輪數上限。真正的硬限制是 context（見 context_soft_limit_ratio
# 的交接機制），輪數只是人為的天花板：複雜票本來就要跑很多輪，撞到它
# 是把做到一半的變更砍在收尾前（2026-09-20 JSAI-2383 實測，121 輪）
DEFAULT_MAX_TURNS = 0
DEFAULT_MAX_BUDGET_USD = 5.0
DEFAULT_WALL_CLOCK_SECONDS = 5400
DEFAULT_CONTEXT_SOFT_LIMIT_RATIO = 0.7
# 模型的 context 視窗（tokens）。⚠️ 這是**單一 run 的上下文容量**，跟額度
# 限制（rate limit／weekly limit）是兩套獨立機制：視窗滿了會交接，額度用完
# 會把執行器標成 limited，兩者誰也不影響誰。填小了的症狀是每一輪都在半路
# 交接，而沒有任何地方會說「其實還有空間」。
# 可由環境變數 ``CHATROOM_RUNNER_CONTEXT_WINDOW_TOKENS`` 覆寫（優先於設定檔）
DEFAULT_CONTEXT_WINDOW_TOKENS = 1_000_000
DEFAULT_USAGE_WINDOW_HOURS = 5.0
DEFAULT_MAINTENANCE_HOUR = 4
DEFAULT_HEARTBEAT_SECONDS = 30
# 進行中的 run 多久沒吐出任何 stream 事件就標成停滯。**只標記、不殺進程**
#（牆鐘上限照舊管終止）——遠端看不到 shell，一個安靜的 run 與一個掛住的 run
# 在面板上長得一模一樣
DEFAULT_STALL_WARN_SECONDS = 600
# 退避階梯（分鐘）。撞到 rate limit 之後用 `--resume` 續跑，每一階報一次
DEFAULT_BACKOFF_MINUTES = (5, 15, 30, 60)
# stream 裡連續看到幾次 rate_limit 的 api_retry 就把執行器標 limited
DEFAULT_RATE_LIMIT_RETRY_THRESHOLD = 3
# chatroom MCP 開場沒連上時重起 claude 的次數與間隔（秒）。
# 進房是 run 的前置條件（艾斯維爾裁決 09/19）：連不上就沒有卡、沒有
# 階段素材，那一輪只會盲做。間隔遞增是給 bridge 起來的時間——實測的
# 形狀是啟動競速，不是 bridge 壞掉
DEFAULT_MCP_RETRIES = 3
DEFAULT_MCP_RETRY_BACKOFF_SECONDS = (5, 15, 30)
# 傳給 claude 的 `MCP_TIMEOUT`（毫秒）＝ MCP 伺服器啟動／連線逾時。
# 依 docs/en/mcp「Timeouts & Performance」：單位毫秒，HTTP／SSE／
# WebSocket 與 **stdio** 都適用（chatroom 走 stdio）。cli-reference 說
# `--mcp-config` 預設等約 30 秒——bridge 冷啟動輸給它就是這次的事故，
# 所以拉到 60 秒當第一道防線；擋不住的才走重試
DEFAULT_MCP_STARTUP_TIMEOUT_MS = 60_000
# run 預設只准用 chatroom。其他要開的在設定檔的 `allowed_mcp_servers` 明列
DEFAULT_ALLOWED_MCP_SERVERS = ("chatroom",)
# 收尾請求（軟停止）立旗標之後，等進程自己結束的上限。逾時就走既有的
# `request_cancel` 硬殺——沒有上限的話，一個已經不再呼叫工具的 run（旗標
# 永遠沒有機會被讀到）會把那個位置佔到牆鐘上限為止
DEFAULT_SOFT_STOP_TIMEOUT_SECONDS = 300

# run 目錄裡的三個檔名。**執行器與 PreToolUse hook 共用**：寫成兩份字面值
# 的話，改了一邊的症狀是旗標立了而 hook 永遠看不到，而沒有地方會報錯
SOFT_STOP_FLAG_NAME = "soft_stop.flag"
SOFT_STOP_TIMEOUT_FLAG_NAME = "soft_stop_timeout.flag"
INJECT_FILE_NAME = "inject.jsonl"
# 已經送進模型的行數。**不刪 `inject.jsonl`**：那份紀錄是事後唯一說得出
# 「房裡跟它講過什麼」的東西
INJECT_CURSOR_NAME = "inject.cursor"


class ConfigError(Exception):
    """設定檔缺漏或形狀不對。啟動時就該炸，不要帶著半套設定去領單。"""


def default_state_dir() -> Path:
    """執行器的本機狀態根目錄（設定、狀態檔、log、暫存 run 目錄）。"""
    local = os.environ.get("LOCALAPPDATA")
    if local:
        return Path(local) / "UEP" / "Chatroom" / "runner"
    return Path.home() / ".local" / "share" / "uep" / "chatroom" / "runner"


def default_config_path() -> Path:
    env = os.environ.get("CHATROOM_RUNNER_CONFIG")
    if env:
        return Path(env)
    return default_state_dir() / "config.json"


def read_env_file(path: str | os.PathLike[str], key: str) -> str:
    """從 ``.env`` 風格的檔案讀一個 key。讀不到回空字串。

    刻意不做變數展開、不 source：這個檔案裡還有別的密鑰，執行器只要一個值。
    """
    p = Path(path)
    if not p.is_file():
        return ""
    for raw in p.read_text(encoding="utf-8-sig").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        if k.strip() == key:
            return v.strip().strip('"').strip("'")
    return ""


def branch_allowed(branch: str, patterns: list[str]) -> bool:
    """分支是否落在允許清單。清單支援 ``feature/*`` 這種 glob。

    ⚠️ 空清單是**不允許任何分支**，不是「不限制」——白名單留白的那一刻就
    該什麼都領不到，而不是什麼都放行（沿用 Hub 對 ``projects`` 的做法）。
    """
    if not branch:
        return False
    return any(fnmatch.fnmatch(branch, p) for p in patterns)


@dataclass(frozen=True)
class ProjectConfig:
    """一個**專案**＝一個 git 工作樹（舊名 ``RepoConfig``）。

    ``path`` 由設定決定，brief 說了不算（§5.2）；而且**必須是 git repo**，
    載入時就驗（見 ``is_git_project``）——不是 git 的目錄在這裡沒有分支、
    沒有快照，整套守衛與收尾附註都建立在「它是 repo」這個前提上。
    """

    name: str
    path: Path
    allowed_branches: list[str] = field(default_factory=list)
    push_branches: list[str] = field(default_factory=list)

    def allows(self, branch: str) -> bool:
        return branch_allowed(branch, self.allowed_branches)

    def allows_push(self, branch: str) -> bool:
        return branch_allowed(branch, self.push_branches)


@dataclass(frozen=True)
class WorkspaceConfig:
    """一個**工作區**＝底下擺著數個專案的外層資料夾（舊名 ``ProjectConfig``）。

    🚨 跨界對照：這裡的 ``key`` 就是 **Hub 對外的 ``project`` key**（派工
    body 的 ``project``、register 的 ``projects`` 清單）。Hub 不知道工作區
    底下有幾個專案——那是這台機器本機的事。
    """

    key: str
    # 工作區底下的專案（名稱 → 一個 git repo）
    projects: dict[str, ProjectConfig] = field(default_factory=dict)
    # 工作區的外層資料夾（絕對路徑，選填）。**執行器的邏輯不依賴它**：只給
    # App 顯示，以及當 skill_dirs／專案路徑的預設起點。不存在只警告不排除
    # ——路徑打錯不該讓一個本來跑得動的工作區停擺
    folder: str = ""
    model: str = DEFAULT_MODEL
    # 0 ＝ 不傳 --max-turns
    max_turns: int = DEFAULT_MAX_TURNS
    max_budget_usd: float = DEFAULT_MAX_BUDGET_USD
    wall_clock_seconds: int = DEFAULT_WALL_CLOCK_SECONDS
    context_soft_limit_ratio: float = DEFAULT_CONTEXT_SOFT_LIMIT_RATIO
    context_window_tokens: int = DEFAULT_CONTEXT_WINDOW_TOKENS
    # 沒指名專案時用哪一個（見 `run.resolve_repo` 的規則）
    default_project: str = ""
    # 起 claude 時要 `--add-dir` 進來的目錄。Claude Code 的 skill 發現只往上
    # 找到 git root，而專案的 skill 常常放在 repo 的**上一層**（cwd 是子
    # repo 時根本掃不到）；`--add-dir` 進來的目錄其 `.claude/skills/` 會載入
    skill_dirs: list[Path] = field(default_factory=list)
    # kind → 這種派工**必須遵守**的 skill 名清單。名字會進 `--allowedTools`
    # 的 `Skill(<name>)`，也會寫進契約要求 run 一開始就啟動它
    skills: dict[str, list[str]] = field(default_factory=dict)
    # 這個工作區**不分 kind**都要一開始就載入的 skill（至多一個）。
    # 與 `skills`（kind → 必守清單）是兩套語意：那個看派工類型，這個是
    # 「在這個工作區工作就要先載它」
    primary_skill: str = ""
    # guard 額外放行寫入的目錄（skill 要求的產出落在 repo 外時用）。
    # **只放行位置，敏感檔名的檢查照走**
    extra_write_dirs: list[Path] = field(default_factory=list)
    # 要不要讓**別人**在派工對話框看到這個工作區。只影響執行器往 Hub 報的
    # `projects` 清單，不影響本機白名單語意：非公開的工作區照樣能被直接
    # 指名派工，只是不會出現在別人的選單裡
    public: bool = True
    # 這個工作區的 run 可不可以開瀏覽器做實機測試。True 時 ticket 模板會多
    # 一句「能做就做」；False 時整句不出現（模板預設的「不是交付門檻」照舊）
    allow_browser_livetest: bool = False
    # 被排除的專案（名稱 → 原因）。**不讓整台執行器起不來**，但要留著讓
    # 自檢與 log 講得出「少了哪一個、為什麼」——靜默少一個專案的症狀是
    # 派工落在剩下那個上面，而沒有地方說另一個被跳過了
    invalid_projects: dict[str, str] = field(default_factory=dict)

    def skills_for(self, kind: str) -> list[str]:
        return list(self.skills.get(kind, []))

    def all_skills_for(self, kind: str) -> list[str]:
        """這一輪要預先授權／寫進契約的 skill：優先載入的那個 + kind 的必守。

        `primary_skill` 不分 kind 都要在，否則 run 一叫它就卡在權限提示。
        """
        names: list[str] = []
        if self.primary_skill:
            names.append(self.primary_skill)
        for name in self.skills_for(kind):
            if name not in names:
                names.append(name)
        return names

    @property
    def context_soft_limit_tokens(self) -> int:
        return int(self.context_window_tokens * self.context_soft_limit_ratio)


@dataclass(frozen=True)
class RunnerConfig:
    hub_url: str
    agent_token: str
    host: str
    label: str
    # 本機工作區（key ＝ Hub 對外的 `project` key）
    workspaces: dict[str, WorkspaceConfig]
    claude_bin: list[str]
    claude_config_dir: Path
    state_dir: Path
    max_parallel: int = DEFAULT_MAX_PARALLEL
    usage_window_hours: float = DEFAULT_USAGE_WINDOW_HOURS
    usage_soft_cap_tokens: int = 0
    usage_soft_cap_usd: float = 0.0
    maintenance_hour: int = DEFAULT_MAINTENANCE_HOUR
    heartbeat_seconds: float = DEFAULT_HEARTBEAT_SECONDS
    stall_warn_seconds: float = DEFAULT_STALL_WARN_SECONDS
    # 收尾請求後等進程自己結束的上限（秒）
    soft_stop_timeout: float = DEFAULT_SOFT_STOP_TIMEOUT_SECONDS
    allowed_domains: list[str] = field(default_factory=list)
    # 額外要預先授權給子 agent 的工具名（`--allowedTools`），例如
    # "mcp__claude_ai_Atlassian_Rovo__*"。硬限制仍由 PreToolUse hook 守
    extra_allowed_tools: list[str] = field(default_factory=list)
    # run 允許用哪些 MCP 伺服器。**預設拒絕**：不在這裡、也沒被
    # `extra_allowed_tools` 的 `mcp__<server>__*` 點名的 claude.ai 連接器，
    # 一律進 run 專用 settings 的 `deniedMcpServers` 與 `--disallowedTools`
    #（見 run.KNOWN_CLAUDE_AI_SERVERS）
    allowed_mcp_servers: list[str] = field(
        default_factory=lambda: list(DEFAULT_ALLOWED_MCP_SERVERS))
    backoff_minutes: list[int] = field(
        default_factory=lambda: list(DEFAULT_BACKOFF_MINUTES))
    rate_limit_retry_threshold: int = DEFAULT_RATE_LIMIT_RETRY_THRESHOLD
    # chatroom MCP 開場不是 `connected` 時，最多重起 claude 幾次。
    # 0 ＝不重試，第一次就判 `chatroom_mcp_unavailable`
    mcp_retries: int = DEFAULT_MCP_RETRIES
    # 每一次重試前等幾秒。用完最後一個就一直沿用它
    mcp_retry_backoff_seconds: list[float] = field(
        default_factory=lambda: list(DEFAULT_MCP_RETRY_BACKOFF_SECONDS))
    # 傳給 claude 子進程的 `MCP_TIMEOUT`（毫秒，MCP 伺服器啟動逾時）。
    # 0 ＝不設，沿用 CLI 預設
    mcp_startup_timeout_ms: int = DEFAULT_MCP_STARTUP_TIMEOUT_MS
    bridge_path: Path | None = None
    # 啟動自檢要不要驗 GPG。**預設驗**——簽章不可用時 commit 會停在 pinentry，
    # 而遠端沒有人能按那個視窗。只有明知這台機器不簽章時才關掉
    require_gpg: bool = True
    # 自檢要用哪一支 gpg。留空＝跟 git 同源（`git config --get gpg.program`），
    # 再退回 PATH 上的 `gpg`。排程工作的 PATH 跟互動 shell 不一樣，
    # 「commit 簽得起來」與「自檢叫得到 gpg」必須指同一支才有意義
    gpg_bin: str = ""
    version: str = "0.1.0"

    @property
    def log_dir(self) -> Path:
        return self.state_dir / "logs"

    @property
    def runs_dir(self) -> Path:
        return self.state_dir / "runs"

    @property
    def state_file(self) -> Path:
        """本機狀態檔：runner_id 與 `runner_token`（Hub 只在建立那次回）。"""
        return self.state_dir / "state.json"

    @property
    def usage_db(self) -> Path:
        return self.state_dir / "usage.db"

    def workspace(self, key: str) -> WorkspaceConfig:
        """依 key 取工作區。``key`` 就是 Hub 派工 body 裡的 ``project``。"""
        ws = self.workspaces.get(key)
        if ws is None:
            raise ConfigError(
                f"工作區「{key}」不在允許清單裡，這筆派工不會執行。")
        return ws


def is_git_project(path: str | os.PathLike[str]) -> bool:
    """``<path>/.git`` 在不在。

    目錄＝一般 clone，**檔案**＝worktree／submodule 的指標檔（``gitdir: ...``），
    兩種都算。不跑 `git rev-parse`：自檢那一關本來就會對每個專案跑 git，
    載入時多起一個子進程只會讓啟動變慢。
    """
    p = Path(path) / ".git"
    return p.is_dir() or p.is_file()


def _project_from(name: str, raw: dict) -> ProjectConfig:
    path = raw.get("path")
    if not path:
        raise ConfigError(f"專案「{name}」沒有 path")
    return ProjectConfig(
        name=name,
        path=Path(path),
        allowed_branches=list(raw.get("allowed_branches", [])),
        push_branches=list(raw.get("push_branches", [])),
    )


def skill_manifest(name: str, skill_dirs: list[Path]) -> Path | None:
    """找 skill 的 ``SKILL.md``。找不到回 ``None``。

    位置就是 Claude Code 的規則：``<dir>/.claude/skills/<name>/SKILL.md``。
    """
    for d in skill_dirs:
        manifest = Path(d) / ".claude" / "skills" / name / "SKILL.md"
        if manifest.is_file():
            return manifest
    return None


def _alias_get(raw: dict, new_key: str, old_key: str, where: str):
    """新鍵優先、舊鍵相容。兩個都寫了就用新的，並留一句警告。

    舊設定檔（``projects``／``repos``／``default_repo``）照樣讀得進來；靜默
    只吃一邊的話，改了舊鍵的人會看到設定「沒有生效」而沒有任何地方說原因。
    """
    if new_key in raw and old_key in raw:
        log.warning("%s 同時有「%s」與舊鍵「%s」，以「%s」為準",
                    where, new_key, old_key, new_key)
        return raw.get(new_key)
    if new_key in raw:
        return raw.get(new_key)
    return raw.get(old_key)


def _skills_from(key: str, raw: dict, skill_dirs: list[Path]
                 ) -> dict[str, list[str]]:
    """``skills`` 的解析與驗證。

    ⚠️ 缺檔就是**設定錯誤**，不是啟動時的一句 warning：契約會叫 run 去跑一個
    不存在的 skill，而 headless 那邊不會有人發現它其實沒載到。
    """
    skills_raw = raw.get("skills") or {}
    if not isinstance(skills_raw, dict):
        raise ConfigError(f"工作區「{key}」的 skills 要是 kind → 清單的物件")
    skills: dict[str, list[str]] = {}
    for kind, names in skills_raw.items():
        if isinstance(names, str):
            names = [names]
        kind_skills = [str(n) for n in names if str(n)]
        for name in kind_skills:
            if skill_manifest(name, skill_dirs) is None:
                where = "、".join(str(d) for d in skill_dirs) or "（沒有設定"\
                    " skill_dirs）"
                raise ConfigError(
                    f"工作區「{key}」的 {kind} 指定 skill「{name}」，"
                    f"但在 {where} 底下都找不到 "
                    f".claude/skills/{name}/SKILL.md")
        if kind_skills:
            skills[str(kind)] = kind_skills
    return skills


def _primary_skill_from(key: str, raw: dict, skill_dirs: list[Path]) -> str:
    """``primary_skill`` 的解析與驗證（沿用 `skills` 那一套）。

    缺 SKILL.md 一樣是**設定錯誤**：契約會叫 run 開工先載它，而載不到的時候
    headless 那邊不會有人發現。
    """
    name = str(raw.get("primary_skill") or "").strip()
    if not name:
        return ""
    if skill_manifest(name, skill_dirs) is None:
        where = "、".join(str(d) for d in skill_dirs) or "（沒有設定 skill_dirs）"
        raise ConfigError(
            f"工作區「{key}」的 primary_skill「{name}」，"
            f"但在 {where} 底下都找不到 .claude/skills/{name}/SKILL.md")
    return name


def _workspace_from(key: str, raw: dict) -> WorkspaceConfig:
    where = f"工作區「{key}」"
    projects_raw = _alias_get(raw, "projects", "repos", where) or {}
    if not projects_raw:
        raise ConfigError(f"{where}沒有任何專案")
    projects: dict[str, ProjectConfig] = {}
    invalid: dict[str, str] = {}
    for name, item in projects_raw.items():
        proj = _project_from(name, item)
        # 專案必須是 git repo。**只排除那一個，不讓整台執行器起不來**：
        # 一個打錯的路徑不該讓其他工作區也領不到單
        if not is_git_project(proj.path):
            reason = f"不是 git 專案（{proj.path} 底下找不到 .git），已排除"
            invalid[name] = reason
            log.error("%s的專案「%s」%s", where, name, reason)
            continue
        projects[name] = proj
    default_project = _alias_get(raw, "default_project", "default_repo",
                                 where) or (
        next(iter(projects)) if len(projects) == 1 else "")
    if default_project and default_project not in projects:
        raise ConfigError(
            f"{where}的 default_project「{default_project}」不在專案清單裡"
            + (f"（被排除的：{'、'.join(invalid)}）" if invalid else ""))
    folder = str(raw.get("folder") or "").strip()
    if folder and not Path(folder).is_dir():
        log.warning("%s的 folder「%s」不存在（只是顯示用，不影響執行）",
                    where, folder)
    skill_dirs = [Path(str(p)) for p in raw.get("skill_dirs", [])]
    return WorkspaceConfig(
        key=key,
        projects=projects,
        folder=folder,
        model=raw.get("model") or DEFAULT_MODEL,
        max_turns=int(raw.get("max_turns", DEFAULT_MAX_TURNS)),
        max_budget_usd=float(raw.get("max_budget_usd",
                                     DEFAULT_MAX_BUDGET_USD)),
        wall_clock_seconds=int(raw.get("wall_clock_seconds",
                                       DEFAULT_WALL_CLOCK_SECONDS)),
        context_soft_limit_ratio=float(
            raw.get("context_soft_limit_ratio",
                    DEFAULT_CONTEXT_SOFT_LIMIT_RATIO)),
        context_window_tokens=int(
            os.environ.get("CHATROOM_RUNNER_CONTEXT_WINDOW_TOKENS")
            or raw.get("context_window_tokens",
                       DEFAULT_CONTEXT_WINDOW_TOKENS)),
        default_project=default_project,
        skill_dirs=skill_dirs,
        skills=_skills_from(key, raw, skill_dirs),
        primary_skill=_primary_skill_from(key, raw, skill_dirs),
        extra_write_dirs=[Path(str(p))
                          for p in raw.get("extra_write_dirs", [])],
        public=bool(raw.get("public", True)),
        allow_browser_livetest=bool(raw.get("allow_browser_livetest", False)),
        invalid_projects=invalid,
    )


def public_project_keys(workspaces: dict[str, WorkspaceConfig]) -> list[str]:
    """要報給 Hub 的 `projects` 清單——**只有標公開的**。

    🚨 跨界：回傳的是 Hub 語意的 `project` key（＝本機工作區 key）。Hub 的
    `projects` 欄位形狀不變（純字串陣列），變的只是內容：沒標公開的工作區
    留在本機白名單裡照常可執行，但不會出現在別人的派工對話框。
    """
    return [k for k, w in workspaces.items() if w.public]


def private_project_keys(workspaces: dict[str, WorkspaceConfig]) -> list[str]:
    """要報給 Hub 的 `private_projects` 清單——**沒標公開的那些**。

    🚨 跨界：形狀與 `public_project_keys` 一樣（純字串陣列，內容是本機工作
    區 key），兩份清單互斥。私人工作區照樣在本機白名單裡可執行，差別只在
    Hub 那端只讓私人房派它的工——那條規則在 Hub，本機不重複判斷。
    """
    return [k for k, w in workspaces.items() if not w.public]


def _as_argv(raw) -> list[str]:
    """``claude_bin`` 可以是字串或陣列。

    字串**不做 shlex 切**：Windows 路徑裡的反斜線會被 shlex 當成跳脫字元吃掉，
    要帶參數的人請直接給陣列。
    """
    if raw is None or raw == "":
        return ["claude"]
    if isinstance(raw, list):
        return [str(x) for x in raw]
    return [str(raw)]


def load_config(path: str | os.PathLike[str] | None = None) -> RunnerConfig:
    """讀設定檔並套用環境變數覆寫。"""
    cfg_path = Path(path) if path else default_config_path()
    if not cfg_path.is_file():
        raise ConfigError(
            f"找不到執行器設定檔：{cfg_path}。"
            "請複製 runner/config.example.json 過去再改，或設定環境變數"
            " CHATROOM_RUNNER_CONFIG 指到別的位置。")
    try:
        raw = json.loads(cfg_path.read_text(encoding="utf-8-sig"))
    except json.JSONDecodeError as exc:
        raise ConfigError(f"設定檔不是合法的 JSON（{cfg_path}）：{exc}") from exc
    return config_from_dict(raw, base_dir=cfg_path.parent)


def config_from_dict(raw: dict, base_dir: Path | None = None) -> RunnerConfig:
    workspaces_raw = _alias_get(raw, "workspaces", "projects", "設定檔") or {}
    if not workspaces_raw:
        raise ConfigError("設定檔沒有 workspaces——空的允許清單領不到任何單。")
    workspaces = {k: _workspace_from(k, v) for k, v in workspaces_raw.items()}

    token = (raw.get("agent_token") or os.environ.get("CHATROOM_TOKEN") or "")
    if not token and raw.get("token_env_file"):
        env_file = Path(raw["token_env_file"])
        if not env_file.is_absolute() and base_dir is not None:
            env_file = base_dir / env_file
        token = read_env_file(env_file, "CHATROOM_TOKEN")

    state_dir = Path(raw["state_dir"]) if raw.get("state_dir") \
        else default_state_dir()
    claude_config_dir = Path(raw["claude_config_dir"]) \
        if raw.get("claude_config_dir") else state_dir / "claude-config"

    return RunnerConfig(
        hub_url=(os.environ.get("CHATROOM_RUNNER_HUB_URL")
                 or raw.get("hub_url") or "http://127.0.0.1:8787"),
        agent_token=token,
        host=raw.get("host") or os.environ.get("COMPUTERNAME") or "localhost",
        label=raw.get("label") or "runner",
        workspaces=workspaces,
        claude_bin=_as_argv(raw.get("claude_bin")),
        claude_config_dir=claude_config_dir,
        state_dir=state_dir,
        max_parallel=int(raw.get("max_parallel", DEFAULT_MAX_PARALLEL)),
        usage_window_hours=float(raw.get("usage_window_hours",
                                         DEFAULT_USAGE_WINDOW_HOURS)),
        usage_soft_cap_tokens=int(raw.get("usage_soft_cap_tokens", 0)),
        usage_soft_cap_usd=float(raw.get("usage_soft_cap_usd", 0.0)),
        maintenance_hour=int(raw.get("maintenance_hour",
                                     DEFAULT_MAINTENANCE_HOUR)),
        heartbeat_seconds=float(raw.get("heartbeat_seconds",
                                        DEFAULT_HEARTBEAT_SECONDS)),
        stall_warn_seconds=float(raw.get("stall_warn_seconds",
                                         DEFAULT_STALL_WARN_SECONDS)),
        soft_stop_timeout=float(raw.get(
            "soft_stop_timeout", DEFAULT_SOFT_STOP_TIMEOUT_SECONDS)),
        allowed_domains=list(raw.get("allowed_domains", [])),
        extra_allowed_tools=[
            str(x) for x in raw.get("extra_allowed_tools", [])],
        allowed_mcp_servers=[
            str(x) for x in raw.get("allowed_mcp_servers",
                                    DEFAULT_ALLOWED_MCP_SERVERS)],
        backoff_minutes=[int(x) for x in raw.get(
            "backoff_minutes", DEFAULT_BACKOFF_MINUTES)],
        rate_limit_retry_threshold=int(
            raw.get("rate_limit_retry_threshold",
                    DEFAULT_RATE_LIMIT_RETRY_THRESHOLD)),
        mcp_retries=int(raw.get("mcp_retries", DEFAULT_MCP_RETRIES)),
        mcp_retry_backoff_seconds=[
            float(x) for x in raw.get("mcp_retry_backoff_seconds",
                                      DEFAULT_MCP_RETRY_BACKOFF_SECONDS)],
        mcp_startup_timeout_ms=int(
            raw.get("mcp_startup_timeout_ms",
                    DEFAULT_MCP_STARTUP_TIMEOUT_MS)),
        bridge_path=Path(raw["bridge_path"]) if raw.get("bridge_path")
        else None,
        require_gpg=bool(raw.get("require_gpg", True)),
        gpg_bin=str(raw.get("gpg_bin") or ""),
        version=raw.get("version") or "0.1.0",
    )
