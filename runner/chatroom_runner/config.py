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
# 退避階梯（分鐘）。撞到 rate limit 之後用 `--resume` 續跑，每一階報一次
DEFAULT_BACKOFF_MINUTES = (5, 15, 30, 60)
# stream 裡連續看到幾次 rate_limit 的 api_retry 就把執行器標 limited
DEFAULT_RATE_LIMIT_RETRY_THRESHOLD = 3


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
    allowed_domains: list[str] = field(default_factory=list)
    backoff_minutes: list[int] = field(
        default_factory=lambda: list(DEFAULT_BACKOFF_MINUTES))
    rate_limit_retry_threshold: int = DEFAULT_RATE_LIMIT_RETRY_THRESHOLD
    bridge_path: Path | None = None
    # 啟動自檢要不要驗 GPG。**預設驗**——簽章不可用時 commit 會停在 pinentry，
    # 而遠端沒有人能按那個視窗。只有明知這台機器不簽章時才關掉
    require_gpg: bool = True
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
        allowed_domains=list(raw.get("allowed_domains", [])),
        backoff_minutes=[int(x) for x in raw.get(
            "backoff_minutes", DEFAULT_BACKOFF_MINUTES)],
        rate_limit_retry_threshold=int(
            raw.get("rate_limit_retry_threshold",
                    DEFAULT_RATE_LIMIT_RETRY_THRESHOLD)),
        bridge_path=Path(raw["bridge_path"]) if raw.get("bridge_path")
        else None,
        require_gpg=bool(raw.get("require_gpg", True)),
        version=raw.get("version") or "0.1.0",
    )
