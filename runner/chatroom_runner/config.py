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
import os
from dataclasses import dataclass, field
from pathlib import Path

# 預設值集中在這裡，改一個地方就好
DEFAULT_MAX_PARALLEL = 3
DEFAULT_MODEL = "claude-opus-5"
DEFAULT_MAX_TURNS = 120
DEFAULT_MAX_BUDGET_USD = 5.0
DEFAULT_WALL_CLOCK_SECONDS = 5400
DEFAULT_CONTEXT_SOFT_LIMIT_RATIO = 0.7
DEFAULT_CONTEXT_WINDOW_TOKENS = 200_000
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
class RepoConfig:
    """一個 git 工作樹。``path`` 由設定決定，brief 說了不算（§5.2）。"""

    name: str
    path: Path
    allowed_branches: list[str] = field(default_factory=list)
    push_branches: list[str] = field(default_factory=list)

    def allows(self, branch: str) -> bool:
        return branch_allowed(branch, self.allowed_branches)

    def allows_push(self, branch: str) -> bool:
        return branch_allowed(branch, self.push_branches)


@dataclass(frozen=True)
class ProjectConfig:
    """一個允許的專案（Hub 的 ``project`` key）。"""

    key: str
    repos: dict[str, RepoConfig] = field(default_factory=dict)
    model: str = DEFAULT_MODEL
    max_turns: int = DEFAULT_MAX_TURNS
    max_budget_usd: float = DEFAULT_MAX_BUDGET_USD
    wall_clock_seconds: int = DEFAULT_WALL_CLOCK_SECONDS
    context_soft_limit_ratio: float = DEFAULT_CONTEXT_SOFT_LIMIT_RATIO
    context_window_tokens: int = DEFAULT_CONTEXT_WINDOW_TOKENS
    # 沒指名 repo 時用哪一個（見 `run.resolve_repo` 的規則）
    default_repo: str = ""
    # 起 claude 時要 `--add-dir` 進來的目錄。Claude Code 的 skill 發現只往上
    # 找到 git root，而專案的 skill 常常放在 repo 的**上一層**（cwd 是子
    # repo 時根本掃不到）；`--add-dir` 進來的目錄其 `.claude/skills/` 會載入
    skill_dirs: list[Path] = field(default_factory=list)
    # kind → 這種派工**必須遵守**的 skill 名清單。名字會進 `--allowedTools`
    # 的 `Skill(<name>)`，也會寫進契約要求 run 一開始就啟動它
    skills: dict[str, list[str]] = field(default_factory=dict)
    # guard 額外放行寫入的目錄（skill 要求的產出落在 repo 外時用）。
    # **只放行位置，敏感檔名的檢查照走**
    extra_write_dirs: list[Path] = field(default_factory=list)

    def skills_for(self, kind: str) -> list[str]:
        return list(self.skills.get(kind, []))

    @property
    def context_soft_limit_tokens(self) -> int:
        return int(self.context_window_tokens * self.context_soft_limit_ratio)


@dataclass(frozen=True)
class RunnerConfig:
    hub_url: str
    agent_token: str
    host: str
    label: str
    projects: dict[str, ProjectConfig]
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

    def project(self, key: str) -> ProjectConfig:
        proj = self.projects.get(key)
        if proj is None:
            raise ConfigError(
                f"專案「{key}」不在允許清單裡，這筆派工不會執行。")
        return proj


def _repo_from(name: str, raw: dict) -> RepoConfig:
    path = raw.get("path")
    if not path:
        raise ConfigError(f"repo「{name}」沒有 path")
    return RepoConfig(
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


def _skills_from(key: str, raw: dict, skill_dirs: list[Path]
                 ) -> dict[str, list[str]]:
    """``skills`` 的解析與驗證。

    ⚠️ 缺檔就是**設定錯誤**，不是啟動時的一句 warning：契約會叫 run 去跑一個
    不存在的 skill，而 headless 那邊不會有人發現它其實沒載到。
    """
    skills_raw = raw.get("skills") or {}
    if not isinstance(skills_raw, dict):
        raise ConfigError(f"專案「{key}」的 skills 要是 kind → 清單的物件")
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
                    f"專案「{key}」的 {kind} 指定 skill「{name}」，"
                    f"但在 {where} 底下都找不到 "
                    f".claude/skills/{name}/SKILL.md")
        if kind_skills:
            skills[str(kind)] = kind_skills
    return skills


def _project_from(key: str, raw: dict) -> ProjectConfig:
    repos_raw = raw.get("repos") or {}
    if not repos_raw:
        raise ConfigError(f"專案「{key}」沒有任何 repo")
    repos = {n: _repo_from(n, r) for n, r in repos_raw.items()}
    default_repo = raw.get("default_repo") or (
        next(iter(repos)) if len(repos) == 1 else "")
    if default_repo and default_repo not in repos:
        raise ConfigError(
            f"專案「{key}」的 default_repo「{default_repo}」不在 repos 裡")
    skill_dirs = [Path(str(p)) for p in raw.get("skill_dirs", [])]
    return ProjectConfig(
        key=key,
        repos=repos,
        model=raw.get("model") or DEFAULT_MODEL,
        max_turns=int(raw.get("max_turns", DEFAULT_MAX_TURNS)),
        max_budget_usd=float(raw.get("max_budget_usd",
                                     DEFAULT_MAX_BUDGET_USD)),
        wall_clock_seconds=int(raw.get("wall_clock_seconds",
                                       DEFAULT_WALL_CLOCK_SECONDS)),
        context_soft_limit_ratio=float(
            raw.get("context_soft_limit_ratio",
                    DEFAULT_CONTEXT_SOFT_LIMIT_RATIO)),
        context_window_tokens=int(raw.get("context_window_tokens",
                                          DEFAULT_CONTEXT_WINDOW_TOKENS)),
        default_repo=default_repo,
        skill_dirs=skill_dirs,
        skills=_skills_from(key, raw, skill_dirs),
        extra_write_dirs=[Path(str(p))
                          for p in raw.get("extra_write_dirs", [])],
    )


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
    projects_raw = raw.get("projects") or {}
    if not projects_raw:
        raise ConfigError("設定檔沒有 projects——空的允許清單領不到任何單。")
    projects = {k: _project_from(k, v) for k, v in projects_raw.items()}

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
        projects=projects,
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
        bridge_path=Path(raw["bridge_path"]) if raw.get("bridge_path")
        else None,
        require_gpg=bool(raw.get("require_gpg", True)),
        gpg_bin=str(raw.get("gpg_bin") or ""),
        version=raw.get("version") or "0.1.0",
    )
