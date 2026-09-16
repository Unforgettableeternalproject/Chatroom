"""硬限制的判斷邏輯（REMOTE-OPS-PLAN §6.4）。

這個模組是 ``hooks/pretooluse.py`` 的大腦，拆出來的理由只有一個：**它要能被
測試**。hook 本身是一個讀 stdin、寫 stderr、exit 2 的殼，把規則寫在殼裡等於
那些規則永遠只在真的跑一次 agent 時才被驗到。

兩層：**預設拒絕的黑名單 + git 子命令的白名單**。白名單以外的 git 一律擋。

回給模型的理由**一定要說「這是系統限制」並指出替代路徑**：實測被擋的模型會
換一個工具再試一次然後放棄，講清楚才不會在那裡繞。
"""

from __future__ import annotations

import fnmatch
import re
import shlex
from dataclasses import dataclass, field
from pathlib import Path

from .config import branch_allowed

SYSTEM_LIMIT = "這是系統限制"

# 讀寫都不准碰的東西。`.env` 類與私鑰在任何 repo 裡都一樣敏感
SENSITIVE_NAME_PATTERNS = (".env", ".env.*", "*.pem", "*.key", "id_rsa",
                           "id_ed25519", "*.pfx")
SENSITIVE_DIR_NAMES = (".claude", ".gnupg", ".ssh")

# git 的白名單。**沒列出來的一律擋**
GIT_ALLOWED = {
    "status", "diff", "log", "show", "add", "commit", "branch", "checkout",
    "switch", "stash", "fetch", "rev-parse", "ls-files", "remote", "config",
}
# 白名單裡仍要看參數的三個
GIT_BRANCH_DESTRUCTIVE = {"-d", "-D", "--delete", "-m", "-M", "--move",
                          "-f", "--force"}

NETWORK_COMMANDS = {"curl", "wget", "invoke-webrequest", "iwr",
                    "invoke-restmethod", "irm"}

_URL_RE = re.compile(r"https?://([^/\s\"'`,;)]+)", re.IGNORECASE)


@dataclass
class GuardContext:
    """判斷需要的環境。全部由執行器寫進 run 目錄的 ``guard.json``。"""

    cwd: Path
    allowed_branches: list[str] = field(default_factory=list)
    allowed_domains: list[str] = field(default_factory=list)
    # 執行器自己的目錄（設定、狀態、hooks）——agent 不准讀寫
    protected_paths: list[Path] = field(default_factory=list)

    @classmethod
    def from_dict(cls, raw: dict) -> "GuardContext":
        return cls(
            cwd=Path(raw.get("cwd", ".")),
            allowed_branches=list(raw.get("allowed_branches", [])),
            allowed_domains=list(raw.get("allowed_domains", [])),
            protected_paths=[Path(p) for p in raw.get("protected_paths", [])],
        )

    def to_dict(self) -> dict:
        return {"cwd": str(self.cwd),
                "allowed_branches": list(self.allowed_branches),
                "allowed_domains": list(self.allowed_domains),
                "protected_paths": [str(p) for p in self.protected_paths]}


@dataclass
class Decision:
    allowed: bool
    rule: str = ""
    reason: str = ""


ALLOW = Decision(True)


def _deny(rule: str, reason: str) -> Decision:
    return Decision(False, rule, f"{SYSTEM_LIMIT}：{reason}")


def split_commands(command: str) -> list[str]:
    """把一行指令切成數個子指令。

    ``;`` ``&&`` ``||`` ``|`` 與換行都是分隔符——只看第一個 token 的話，
    ``echo hi && git push`` 會整句放行。引號內的分隔符不切。
    """
    parts: list[str] = []
    buf: list[str] = []
    quote = ""
    i = 0
    while i < len(command):
        ch = command[i]
        if quote:
            buf.append(ch)
            if ch == quote:
                quote = ""
            i += 1
            continue
        if ch in "\"'":
            quote = ch
            buf.append(ch)
            i += 1
            continue
        if ch in ";\n|&`":
            nxt = command[i + 1] if i + 1 < len(command) else ""
            if ch in "|&" and nxt == ch:
                i += 2
            else:
                i += 1
            parts.append("".join(buf))
            buf = []
            continue
        buf.append(ch)
        i += 1
    parts.append("".join(buf))
    return [p.strip() for p in parts if p.strip()]


def tokenize(segment: str) -> list[str]:
    """盡量切成 token。切不動就退回 ``split()``——寧可粗一點也不要整句放行。"""
    try:
        return [t for t in shlex.split(segment, posix=False) if t]
    except ValueError:
        return [t for t in segment.split() if t]


def _unquote(token: str) -> str:
    if len(token) >= 2 and token[0] == token[-1] and token[0] in "\"'":
        return token[1:-1]
    return token


def _is_sensitive_name(name: str) -> bool:
    low = name.lower()
    return any(fnmatch.fnmatch(low, pat) for pat in SENSITIVE_NAME_PATTERNS)


def _domain_allowed(host: str, allowed: list[str]) -> bool:
    host = host.split("@")[-1].split(":")[0].lower()
    for pat in allowed:
        p = pat.lower().lstrip("*.")
        if host == p or host.endswith("." + p):
            return True
    return False


def check_path(raw_path: str, ctx: GuardContext) -> Decision:
    """寫入型工具的路徑守衛：必須在 cwd 內，且不是敏感檔。"""
    if not raw_path:
        return _deny("path_missing",
                     "這次工具呼叫沒有給路徑，執行器無法確認它寫在哪裡。"
                     "請改用明確的相對路徑（相對於工作目錄）。")
    path = Path(_unquote(raw_path))
    if not path.is_absolute():
        path = ctx.cwd / path
    try:
        resolved = path.resolve()
        cwd = ctx.cwd.resolve()
    except OSError:  # pragma: no cover - 路徑壞掉就當它在外面
        return _deny("path_unresolvable", "這個路徑無法解析，拒絕寫入。")
    for prot in ctx.protected_paths:
        try:
            if resolved == prot.resolve() or prot.resolve() in resolved.parents:
                return _deny(
                    "path_protected",
                    "那是執行器自己的目錄（設定與 hooks），任何 run 都不能動。"
                    "要調整限制請問人類。")
        except OSError:  # pragma: no cover
            continue
    if resolved != cwd and cwd not in resolved.parents:
        return _deny("path_outside_cwd",
                     f"只能寫工作目錄（{cwd}）以內的檔案。這次的路徑在外面，"
                     "要動別的 repo 請開一張新的卡讓人類派工。")
    if _is_sensitive_name(resolved.name):
        return _deny("path_sensitive",
                     "設定檔與金鑰（.env、*.pem 這類）不能讀也不能寫。"
                     "需要新的環境變數請寫進卡裡請人類設定。")
    parts = {p.lower() for p in resolved.parts}
    hit = parts & {d.lower() for d in SENSITIVE_DIR_NAMES}
    if hit:
        return _deny("path_sensitive_dir",
                     f"{'、'.join(sorted(hit))} 這類目錄不能動——那是登入憑證與"
                     "簽章金鑰的位置。")
    return ALLOW


def _check_git(tokens: list[str], ctx: GuardContext) -> Decision:
    args = [t for t in tokens[1:]]
    sub = ""
    rest: list[str] = []
    for i, tok in enumerate(args):
        if tok.startswith("-"):
            continue
        sub = tok.lower()
        rest = args[i + 1:]
        break
    if sub == "push":
        return _deny("git_push",
                     "push 不由 agent 做。本機沒有人類看著，推送要房內人類從"
                     "儀表板按「推送」建一筆 push 派工。你把 commit 留在分支上"
                     "就好，並在卡裡寫清楚有幾顆待推。")
    if sub not in GIT_ALLOWED:
        return _deny("git_not_allowed",
                     f"git {sub or '(未知子命令)'} 不在允許清單裡"
                     "（只開放 status/diff/log/show/add/commit/branch 建立/"
                     "checkout 到允許分支/stash list/fetch/rev-parse/ls-files）。"
                     "需要其他 git 操作請寫進卡裡請人類處理。")
    if sub == "branch":
        bad = [t for t in rest if t in GIT_BRANCH_DESTRUCTIVE]
        if bad:
            return _deny("git_branch_destructive",
                         f"git branch {' '.join(bad)} 會刪掉或改掉分支，"
                         "不開放。只允許建立新分支。")
    if sub in ("checkout", "switch"):
        return _check_checkout(sub, rest, ctx)
    if sub == "stash":
        if not rest or rest[0].lower() != "list":
            return _deny("git_stash",
                         "只開放 git stash list。stash 會把別人的工作藏起來，"
                         "而遠端沒有人看得到它被藏到哪裡去了。")
    if sub == "reset":  # pragma: no cover - reset 不在白名單，這裡是保險
        return _deny("git_reset", "git reset 不開放。")
    if sub == "config" and rest and rest[0].lower() not in ("--get", "-l",
                                                            "--list"):
        return _deny("git_config",
                     "只開放讀 git config（--get/--list）。改設定會影響"
                     "簽章與身分，那是人類的事。")
    if sub == "remote" and rest and rest[0].lower() not in ("-v", "show",
                                                            "get-url"):
        return _deny("git_remote",
                     "只開放讀 git remote（-v／show／get-url）。")
    return ALLOW


def _check_checkout(sub: str, rest: list[str], ctx: GuardContext) -> Decision:
    creating = False
    targets: list[str] = []
    for tok in rest:
        low = tok.lower()
        if low in ("-b", "-c", "--create", "-B", "-C"):
            creating = True
            continue
        if tok == "--":
            return _deny(
                "git_checkout_path",
                f"git {sub} -- <路徑> 會把檔案還原成 HEAD 的樣子，"
                "未 commit 的修改會消失。要放棄修改請在卡裡說明，讓人類決定。")
        if tok.startswith("-"):
            continue
        targets.append(_unquote(tok))
    if not targets:
        return ALLOW
    branch = targets[0]
    if not branch_allowed(branch, ctx.allowed_branches):
        verb = "建立" if creating else "切換到"
        return _deny(
            "git_branch_not_allowed",
            f"不能{verb}分支「{branch}」。這台執行器只允許"
            f"{'、'.join(ctx.allowed_branches) or '(未設定)'}；"
            "jsai_prod、main、master 在任何 repo 都不可 checkout 也不可 push。")
    return ALLOW


def _check_network(tokens: list[str], segment: str,
                   ctx: GuardContext) -> Decision:
    hosts = _URL_RE.findall(segment)
    if not hosts:
        return _deny("network_no_url",
                     "執行器看不出這次網路呼叫要去哪個網域，所以不放行。"
                     "請把完整的 https URL 寫在指令裡。")
    for host in hosts:
        if not _domain_allowed(host, ctx.allowed_domains):
            return _deny(
                "network_domain",
                f"「{host}」不在允許網域清單裡"
                f"（{'、'.join(ctx.allowed_domains) or '目前是空的'}）。"
                "需要別的來源請問人類。")
    return ALLOW


def check_command(command: str, ctx: GuardContext) -> Decision:
    """Bash / PowerShell 的指令守衛。

    ⚠️ matcher 一定要同時含 ``Bash`` 與 ``PowerShell``：實測 Windows 上模型
    預設選 PowerShell，只擋 Bash 時連 ``echo hi`` 都直接跑過去。
    """
    for segment in split_commands(command):
        decision = _check_segment(segment, ctx)
        if not decision.allowed:
            return decision
    return ALLOW


def _check_segment(segment: str, ctx: GuardContext) -> Decision:
    low = segment.lower()
    tokens = tokenize(segment)
    if not tokens:
        return ALLOW
    head = Path(_unquote(tokens[0])).name.lower()
    head = head[:-4] if head.endswith(".exe") else head

    if "--no-verify" in low or "--no-gpg-sign" in low or "-n --amend" in low:
        return _deny("bypass_hooks",
                     "不能繞過 hooks 或 GPG 簽章。簽章失敗就把 staged 狀態"
                     "留著、在卡裡寫清楚卡在哪，由人類處理。")
    if head == "rm":
        flags = [t for t in tokens[1:] if t.startswith("-")]
        if any("r" in f.lower() or f.lower() == "--recursive" for f in flags):
            return _deny("rm_recursive",
                         "遞迴刪除不開放。要刪整個目錄請在卡裡列出路徑與理由，"
                         "由人類執行。")
    if head in ("remove-item", "ri", "rd", "rmdir", "del", "erase"):
        if any(t.lower().startswith(("-recurse", "-r", "/s"))
               for t in tokens[1:]):
            return _deny("rm_recursive",
                         "遞迴刪除不開放（Remove-Item -Recurse 也一樣）。"
                         "請在卡裡列出要刪的路徑與理由，由人類執行。")
    if head == "az":
        return _deny("cloud_cli",
                     "雲端 CLI（az）不開放——部署與資源變更不在這個系統的"
                     "範圍內。請把需要的變更寫進卡裡。")
    if head == "wrangler" and "deploy" in low:
        return _deny("cloud_cli",
                     "wrangler deploy 不開放：部署是人類的決定。"
                     "請把要部署的內容寫進卡裡。")
    if head == "npm" and "publish" in low:
        return _deny("npm_publish",
                     "npm publish 不開放。要發版請寫進卡裡由人類決定。")
    if head == "gh" and re.search(r"\bpr\b.*\bmerge\b", low):
        return _deny("gh_pr_merge",
                     "合併 PR 是人類的決定，不由 agent 執行。"
                     "把 PR 連結寫進卡裡即可。")
    if head == "git":
        return _check_git(tokens, ctx)
    if head in NETWORK_COMMANDS:
        return _check_network(tokens, segment, ctx)
    for tok in tokens[1:]:
        name = Path(_unquote(tok)).name
        if _is_sensitive_name(name):
            return _deny("path_sensitive",
                         f"「{name}」屬於設定檔或金鑰，不能讀也不能寫。"
                         "需要環境變數請寫進卡裡請人類設定。")
        parts = {p.lower() for p in Path(_unquote(tok)).parts}
        hit = parts & {d.lower() for d in SENSITIVE_DIR_NAMES}
        if hit:
            return _deny("path_sensitive_dir",
                         f"{'、'.join(sorted(hit))} 這類目錄不能動——"
                         "那是登入憑證與簽章金鑰的位置。")
    return ALLOW


# 寫入型工具的參數名。NotebookEdit 用的是 notebook_path
WRITE_TOOLS = {"Write": "file_path", "Edit": "file_path",
               "MultiEdit": "file_path", "NotebookEdit": "notebook_path"}
COMMAND_TOOLS = {"Bash", "PowerShell"}
# hook 的 matcher 字串。**兩端要一致**，寫在這裡讓 settings 產生器直接引用
TOOL_MATCHER = "Bash|PowerShell|Write|Edit|MultiEdit|NotebookEdit"


def check_tool(tool_name: str, tool_input: dict,
               ctx: GuardContext) -> Decision:
    """一次工具呼叫的總判斷。不認得的工具一律放行（matcher 已經先篩過）。"""
    if tool_name in COMMAND_TOOLS:
        return check_command(str(tool_input.get("command") or ""), ctx)
    field_name = WRITE_TOOLS.get(tool_name)
    if field_name:
        return check_path(str(tool_input.get(field_name) or ""), ctx)
    return ALLOW
