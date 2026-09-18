"""硬限制的判斷邏輯（REMOTE-OPS-PLAN §6.4）。

這個模組是 ``hooks/pretooluse.py`` 的大腦，拆出來的理由只有一個：**它要能被
測試**。hook 本身是一個讀 stdin、寫 stderr、exit 2 的殼，把規則寫在殼裡等於
那些規則永遠只在真的跑一次 agent 時才被驗到。

三層：**預設拒絕的黑名單 + git 子命令的白名單 + 讀取路徑的敏感清單**。

⚠️ 黑名單只在「模型直接下那條指令」時有效。殼層與直譯器可以把任何一條被擋
的指令再包一層（``cmd /c git push``、``python -c "subprocess.run(...)"``），
所以**包裝本身要擋**——否則第一個 token 不是 `git`，整份規則就形同不存在。
結構性的邊界寫在規劃書 §6.4「結構性限制」。

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
SENSITIVE_NAME_PATTERNS = (".env", ".env*", "*.pem", "*.key", "*.p12",
                           "*.pfx", "id_rsa*", "id_ed25519*", ".claude.json",
                           "credentials*")
SENSITIVE_DIR_NAMES = (".claude", ".gnupg", ".ssh")

# git 的白名單。**沒列出來的一律擋**
GIT_ALLOWED = {
    "status", "diff", "log", "show", "add", "commit", "branch", "checkout",
    "switch", "stash", "fetch", "rev-parse", "ls-files", "remote", "config",
}
# 白名單裡仍要看參數的三個
GIT_BRANCH_DESTRUCTIVE = {"-d", "-D", "--delete", "-m", "-M", "--move",
                          "-f", "--force"}
# `git config` 只開放讀，而且**整條都要是讀**：`--get --global` 會寫到全域
GIT_CONFIG_READ_FLAGS = {"--get", "--get-all", "--get-regexp", "--list", "-l",
                         "--show-origin", "--show-scope", "--null", "-z"}
GIT_REMOTE_READ = {"-v", "--verbose", "show", "get-url"}
# `git -c k=v` 裡不能碰的設定：改了等於把簽章、hooks 或憑證換掉
GIT_CONFIG_DENY_PREFIXES = ("core.hookspath", "gpg.", "commit.gpgsign",
                            "tag.gpgsign", "core.sshcommand", "core.editor",
                            "core.pager", "url.")
GIT_CREDENTIAL_PREFIXES = ("credential.", "http.extraheader")

NETWORK_COMMANDS = {"curl", "wget", "invoke-webrequest", "iwr",
                    "invoke-restmethod", "irm"}

# ── 進程包裝（審查 09/16 Critical）──────────────────────────────
# 殼層：一律擋。它們存在的意義就是「再跑一段命令字串」
SHELL_WRAPPER_HEADS = {"cmd", "wsl", "wslconfig", "powershell", "pwsh",
                       "powershell_ise", "conhost"}
POSIX_SHELL_HEADS = {"bash", "sh", "zsh", "ksh", "dash", "fish", "busybox"}
# 直接把字串當程式碼跑的
INLINE_EXEC_HEADS = {"start-process", "saps", "start", "invoke-expression",
                     "iex", "invoke-command", "icm", "eval", "exec",
                     "source", "xargs", "env"}
PYTHON_HEADS = {"python", "python3", "pythonw", "py"}
NODE_HEADS = {"node", "nodejs", "deno", "bun"}
# 解譯器：旗標就是「下面這段字串是程式碼」
EVAL_FLAGS = {
    "node": {"-e", "--eval", "-p", "--print"},
    "nodejs": {"-e", "--eval", "-p", "--print"},
    "deno": {"eval"},
    "bun": {"-e", "--eval"},
    "perl": {"-e", "-E"},
    "ruby": {"-e"},
    "php": {"-r"},
}
NPM_HEADS = {"npm", "npx", "pnpm", "yarn", "bunx"}
# npm 的逃生門：`npm exec -- bash -c ...` 與直接 npx 一個殼
NPM_DENIED_SUBS = {"exec", "explore"}

_URL_RE = re.compile(r"https?://([^/\s\"'`,;)]+)", re.IGNORECASE)
# `& { ... }`：split_commands 會把 `&` 當分隔符切掉，只能在整串上看
_SCRIPTBLOCK_RE = re.compile(r"&\s*\{")
# 改 git 憑證相關環境變數的各種寫法（艾斯維爾裁決 09/16：推送憑證隔離）
_GIT_ENV_WRITE_RE = re.compile(
    r"(\$env:git_\w*\s*="
    r"|\bset\s+git_\w*\s*="
    r"|\bsetx\s+git_\w*"
    r"|\bexport\s+git_\w*\s*="
    r"|set-item\s+(-path\s+)?env:\\?git_"
    r"|setenvironmentvariable\s*\(\s*[\"']?git_)",
    re.IGNORECASE)


@dataclass
class GuardContext:
    """判斷需要的環境。全部由執行器寫進 run 目錄的 ``guard.json``。"""

    cwd: Path
    # 這個專案底下**所有** repo 的根目錄（主工作目錄 `cwd` 也在裡面）。
    # 一次派工可以動專案的每一個 repo：只放行 `cwd` 的話，跨 repo 的票會在
    # 第二個 repo 的第一次寫入被擋下來，而 agent 只能把那半段寫進卡裡。
    # 留空＝退回只放行 `cwd`（舊設定檔與單 repo 專案的行為不變）
    repo_roots: list[Path] = field(default_factory=list)
    allowed_branches: list[str] = field(default_factory=list)
    allowed_domains: list[str] = field(default_factory=list)
    # 執行器自己的目錄（設定、狀態、hooks）——agent 不准讀寫
    protected_paths: list[Path] = field(default_factory=list)
    # 這一筆 run 的附件落點（`<run_dir>/downloads`）。它在 run 目錄底下，
    # 也就是在 `protected_paths` 裡面，所以要**明列一個例外**：附件是 agent
    # 自己用 `chatroom_get_file` 要來的，讀不到的話那個工具等於沒有
    downloads_dir: Path | None = None
    # 設定檔（`ProjectConfig.extra_write_dirs`）額外放行寫入的目錄，例如
    # skill 要求產出的分析／摘要資料夾落在 repo 外面時。放行的是**位置**，
    # 敏感檔名與敏感目錄的檢查照走
    extra_write_dirs: list[Path] = field(default_factory=list)

    @classmethod
    def from_dict(cls, raw: dict) -> "GuardContext":
        return cls(
            cwd=Path(raw.get("cwd", ".")),
            repo_roots=[Path(p) for p in raw.get("repo_roots", [])],
            allowed_branches=list(raw.get("allowed_branches", [])),
            allowed_domains=list(raw.get("allowed_domains", [])),
            protected_paths=[Path(p) for p in raw.get("protected_paths", [])],
            downloads_dir=(Path(raw["downloads_dir"])
                           if raw.get("downloads_dir") else None),
            extra_write_dirs=[Path(p)
                              for p in raw.get("extra_write_dirs", [])],
        )

    def to_dict(self) -> dict:
        return {"cwd": str(self.cwd),
                "repo_roots": [str(p) for p in self.repo_roots],
                "allowed_branches": list(self.allowed_branches),
                "allowed_domains": list(self.allowed_domains),
                "protected_paths": [str(p) for p in self.protected_paths],
                "downloads_dir": (str(self.downloads_dir)
                                  if self.downloads_dir else ""),
                "extra_write_dirs": [str(p) for p in self.extra_write_dirs]}


@dataclass
class Decision:
    allowed: bool
    rule: str = ""
    reason: str = ""


ALLOW = Decision(True)

WRAPPER_REASON = ("派工流程不允許透過殼層或直譯器再執行一段命令字串，"
                  "請直接呼叫要跑的指令。")
CREDENTIAL_REASON = "派工 run 不得改動 git 憑證設定。"


def _deny(rule: str, reason: str) -> Decision:
    return Decision(False, rule, f"{SYSTEM_LIMIT}：{reason}")


def _deny_wrapper() -> Decision:
    return _deny("process_wrapper", WRAPPER_REASON)


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


def _sensitive_segment(segment: str) -> bool:
    """一段路徑（或一段 glob）碰不碰得到敏感檔。

    glob 要**雙向**比：`**/.env*` 這個 pattern 本身不是一個檔名，拿它當名字比
    比不中，但它撈得到 `.env`。反向比只在這一段真的有萬用字元、而且去掉萬用
    字元還剩東西時才做——否則單獨一個 `*` 會把所有 glob 都擋掉。
    """
    low = segment.lower()
    if _is_sensitive_name(low):
        return True
    if any(ch in low for ch in "*?[") and low.strip("*?[]"):
        for pat in SENSITIVE_NAME_PATTERNS:
            literal = pat.replace("*", "")
            if literal and fnmatch.fnmatch(literal, low):
                return True
    return False


def _path_segments(raw: str) -> list[str]:
    return [s for s in re.split(r"[\\/]+", raw.strip())
            if s not in ("", ".", "..")]


def _domain_allowed(host: str, allowed: list[str]) -> bool:
    host = host.split("@")[-1].split(":")[0].lower()
    for pat in allowed:
        p = pat.lower().lstrip("*.")
        if host == p or host.endswith("." + p):
            return True
    return False


def _resolve(raw: str, ctx: GuardContext) -> Path | None:
    path = Path(_unquote(raw))
    if not path.is_absolute():
        path = ctx.cwd / path
    try:
        return path.resolve()
    except OSError:  # pragma: no cover - 路徑壞掉就當它在外面
        return None


def repo_roots(ctx: GuardContext) -> list[Path]:
    """這次派工可以動的 repo 根目錄（已解析）。

    設定沒給 ``repo_roots`` 時退回只有 ``cwd`` 一個——舊的 run 目錄與單 repo
    專案的行為因此完全不變。
    """
    raw = list(ctx.repo_roots) or [ctx.cwd]
    roots: list[Path] = []
    for root in raw:
        try:
            resolved = Path(root).resolve()
        except OSError:  # pragma: no cover
            continue
        if resolved not in roots:
            roots.append(resolved)
    return roots


def _within_roots(resolved: Path, roots: list[Path]) -> bool:
    return any(resolved == root or root in resolved.parents for root in roots)


def _within_cwd(raw: str, ctx: GuardContext) -> bool:
    """路徑是否落在這次派工的任一個 repo 以內。"""
    resolved = _resolve(raw, ctx)
    if resolved is None:
        return False
    return _within_roots(resolved, repo_roots(ctx))


def _in_downloads(resolved: Path, ctx: GuardContext) -> bool:
    """路徑是否落在這一筆 run 的附件目錄底下（含目錄本身）。"""
    if ctx.downloads_dir is None:
        return False
    try:
        root = ctx.downloads_dir.resolve()
    except OSError:  # pragma: no cover
        return False
    return resolved == root or root in resolved.parents


def _in_extra_write(resolved: Path, ctx: GuardContext) -> bool:
    """路徑是否落在設定放行的額外寫入目錄底下（含目錄本身）。"""
    for extra in ctx.extra_write_dirs:
        try:
            root = Path(extra).resolve()
        except OSError:  # pragma: no cover
            continue
        if resolved == root or root in resolved.parents:
            return True
    return False


def _protected_hit(resolved: Path, ctx: GuardContext) -> bool:
    for prot in ctx.protected_paths:
        try:
            if resolved == prot.resolve() or prot.resolve() in resolved.parents:
                return True
        except OSError:  # pragma: no cover
            continue
    return False


def check_path(raw_path: str, ctx: GuardContext) -> Decision:
    """寫入型工具的路徑守衛：必須在 cwd 內，且不是敏感檔。"""
    if not raw_path:
        return _deny("path_missing",
                     "這次工具呼叫沒有給路徑，執行器無法確認它寫在哪裡。"
                     "請改用明確的相對路徑（相對於工作目錄）。")
    resolved = _resolve(raw_path, ctx)
    if resolved is None:
        return _deny("path_unresolvable", "這個路徑無法解析，拒絕寫入。")
    roots = repo_roots(ctx)
    if not roots:  # pragma: no cover - cwd 解析不出來
        return _deny("path_unresolvable", "這個路徑無法解析，拒絕寫入。")
    # repo 外只有兩個例外：這筆 run 的附件目錄，與設定明列的 `extra_write_dirs`。
    # 敏感檔名的檢查照走——放行的是「位置」，不是「什麼檔都行」
    exempt = _in_downloads(resolved, ctx) or _in_extra_write(resolved, ctx)
    if not exempt and _protected_hit(resolved, ctx):
        return _deny(
            "path_protected",
            "那是執行器自己的目錄（設定與 hooks），任何 run 都不能動。"
            "要調整限制請問人類。")
    if not exempt and not _within_roots(resolved, roots):
        listed = "、".join(str(r) for r in roots)
        return _deny("path_outside_cwd",
                     f"只能寫這個專案的 repo（{listed}）以內的檔案。"
                     "這次的路徑在外面，要動別的專案請開一張新的卡讓人類派工。")
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


def check_read_path(raw_path: str, ctx: GuardContext) -> Decision:
    """讀取型工具（Read／Glob／Grep）的路徑守衛。

    **不限 cwd**：看別的 repo 的程式碼是正常的調查。擋的是敏感檔本身——
    少了這一層，`.env` 與私鑰只要換一個工具就讀得到，而 hook 的 log 上看起來
    與一次普通的 Read 沒有差別。
    """
    raw = _unquote(str(raw_path or "")).strip()
    if not raw:
        return ALLOW
    segments = _path_segments(raw)
    for seg in segments:
        if _sensitive_segment(seg):
            return _deny("read_sensitive",
                         f"「{seg}」屬於設定檔或金鑰（.env、*.pem、*.key、"
                         "id_rsa 這類），不能讀。需要環境變數請寫進卡裡請"
                         "人類設定。")
    dirs = {d.lower() for d in SENSITIVE_DIR_NAMES}
    for seg in segments:
        if seg.lower() in dirs:
            return _deny("read_sensitive_dir",
                         f"{seg} 這類目錄不能讀——那是登入憑證與簽章金鑰的"
                         "位置。")
    if not any(ch in raw for ch in "*?["):
        resolved = _resolve(raw, ctx)
        if (resolved is not None and not _in_downloads(resolved, ctx)
                and _protected_hit(resolved, ctx)):
            return _deny("read_protected",
                         "那是執行器自己的目錄（設定、狀態與 hooks），"
                         "任何 run 都不能讀。要調整限制請問人類。")
    return ALLOW


# ── git ─────────────────────────────────────────────────────────

def _check_git_globals(args: list[str]) -> tuple[Decision | None, str,
                                                 list[str]]:
    """剝掉子命令前的全域選項，順便擋掉會換工作樹／換設定的那幾個。

    🚨 ``-C``、``--git-dir``、``--work-tree`` 會把整條命令搬到別的 repo 去做，
    而 ``-c k=v`` 可以就地關掉簽章、換掉 hooks 或塞進一個憑證 helper。舊版
    直接 ``startswith("-") → continue``，於是 ``git -C log push`` 的子命令被
    當成 ``log``，push 整條放行。
    """
    i = 0
    while i < len(args):
        tok = args[i]
        low = tok.lower()
        base = low.split("=", 1)[0]
        if tok == "-C" or (tok.startswith("-C") and len(tok) > 2) \
                or base in ("--git-dir", "--work-tree"):
            return (_deny("git_global_path",
                          "派工只能在目前的工作樹上操作。-C／--git-dir／"
                          "--work-tree 會把這條命令搬到別的 repo 去做，"
                          "而那個 repo 沒有人在看。要動別的 repo 請開一張"
                          "新的卡。"), "", [])
        if base == "--namespace":
            i += 1 if "=" in tok else 2
            continue
        if low == "-c" or (low.startswith("-c") and "=" in tok):
            kv = tok[2:] if low != "-c" else (args[i + 1] if i + 1 < len(args)
                                              else "")
            decision = _check_git_config_kv(_unquote(kv))
            if decision is not None:
                return (decision, "", [])
            i += 1 if low != "-c" else 2
            continue
        if tok.startswith("-"):
            i += 1
            continue
        return (None, low, args[i + 1:])
    return (None, "", [])


def _check_git_config_kv(kv: str) -> Decision | None:
    key = kv.split("=", 1)[0].strip().lower()
    value = kv.split("=", 1)[1].strip().lower() if "=" in kv else ""
    if any(key.startswith(p) for p in GIT_CREDENTIAL_PREFIXES):
        return _deny("git_credential_env", CREDENTIAL_REASON)
    if key == "commit.gpgsign" or key == "tag.gpgsign":
        if value in ("false", "0", "no", "off", ""):
            return _deny("git_config_override",
                         "不能用 -c 關掉簽章。簽章失敗就把 staged 狀態留著、"
                         "在卡裡寫清楚卡在哪，由人類處理。")
        return None
    if any(key.startswith(p) for p in GIT_CONFIG_DENY_PREFIXES):
        return _deny("git_config_override",
                     f"不能用 -c 覆寫「{key}」：hooks、簽章與遠端改寫這幾項"
                     "決定了這次 commit 到底有沒有經過檢查。需要調整請問人類。")
    return None


def _check_git(tokens: list[str], ctx: GuardContext) -> Decision:
    decision, sub, rest = _check_git_globals([t for t in tokens[1:]])
    if decision is not None:
        return decision
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
    if sub == "config":
        return _check_git_config(rest)
    if sub == "remote":
        return _check_git_remote(rest)
    return ALLOW


def _check_git_config(rest: list[str]) -> Decision:
    """只開放讀，而且**整條 token 都要是讀**。

    舊版只看 ``rest[0]``：``git config --get --global user.email x`` 的第一個
    token 是 ``--get``，於是一條會寫到全域設定的命令整條放行。
    """
    flags = [t.lower() for t in rest if t.startswith("-")]
    keys = [t for t in rest if not t.startswith("-")]
    if any(_unquote(k).lower().startswith("credential.") for k in keys):
        return _deny("git_credential_env", CREDENTIAL_REASON)
    if not flags or any(f not in GIT_CONFIG_READ_FLAGS for f in flags) \
            or len(keys) > 1:
        return _deny("git_config",
                     "只開放讀 git config（--get／--get-all／--list／"
                     "--show-origin 加一個設定名）。改設定會影響簽章、憑證"
                     "與身分，那是人類的事。")
    return ALLOW


def _check_git_remote(rest: list[str]) -> Decision:
    if not rest:
        return ALLOW
    if rest[0].lower() not in GIT_REMOTE_READ:
        return _deny("git_remote",
                     "只開放讀 git remote（-v／show／get-url）。")
    if any(t.startswith("-") and t.lower() not in ("-v", "--verbose")
           for t in rest[1:]):
        return _deny("git_remote",
                     "只開放讀 git remote（-v／show／get-url），"
                     "不接受其他旗標。")
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


# ── 進程包裝 ────────────────────────────────────────────────────

def _script_decision(raw: str, ctx: GuardContext) -> Decision:
    if _within_cwd(raw, ctx):
        return ALLOW
    resolved = _resolve(raw, ctx)
    if resolved is not None and _in_extra_write(resolved, ctx):
        return ALLOW
    return _deny("script_outside_cwd",
                 "直譯器只能跑這個專案的 repo 以內的腳本。這些 repo 以外的"
                 "檔案這邊看不到也管不到，要跑它請在卡裡說明由人類處理。")


def _short_flag_has(tok: str, letter: str) -> bool:
    """單槓短旗標（含 ``-uc`` 這種合併寫法）裡有沒有某個字母。"""
    return (tok.startswith("-") and not tok.startswith("--")
            and letter in tok[1:].lower())


def _check_interpreter(head: str, args: list[str],
                       ctx: GuardContext) -> Decision:
    """直譯器：``-c``／``-e`` 這類旗標＝「下面那串字是程式碼」，一律擋。

    允許的形狀只有兩個：``python -m pytest``（跑測試）與跑一個 cwd 以內的
    腳本檔。
    """
    if head in PYTHON_HEADS:
        for i, tok in enumerate(args):
            low = tok.lower()
            if _short_flag_has(tok, "c"):
                return _deny_wrapper()
            if low == "-m":
                module = (args[i + 1].lower() if i + 1 < len(args) else "")
                if module.split(".")[0] != "pytest":
                    return _deny_wrapper()
                return ALLOW
            if tok.startswith("-"):
                continue
            return _script_decision(tok, ctx)
        return ALLOW
    flags = EVAL_FLAGS.get(head, set())
    for tok in args:
        low = _unquote(tok).lower()
        if low in flags:
            return _deny_wrapper()
        if tok.startswith("-"):
            continue
        return _script_decision(tok, ctx)
    return ALLOW


def _check_wrapper(head: str, tokens: list[str],
                   ctx: GuardContext) -> Decision:
    """殼層／直譯器包裝（審查 09/16 Critical）。

    🚨 ``cmd /c git push`` 的第一個 token 是 ``cmd``：所有「看子命令」的規則
    都攔不到它，而 push 照樣推上去了。包裝本身擋掉，才輪得到底下那層規則。
    """
    raw_first = _unquote(tokens[0])
    args = tokens[1:]
    if raw_first == ".":
        # PowerShell 的 dot-source：跑的是那個檔案裡的所有東西
        for tok in args:
            if not tok.startswith("-"):
                return _script_decision(tok, ctx)
        return ALLOW
    if head in SHELL_WRAPPER_HEADS:
        return _deny_wrapper()
    if head in INLINE_EXEC_HEADS:
        return _deny_wrapper()
    if head in POSIX_SHELL_HEADS:
        for tok in args:
            if _short_flag_has(tok, "c"):
                return _deny_wrapper()
            if tok.startswith("-"):
                continue
            return _script_decision(tok, ctx)
        return ALLOW
    if head in PYTHON_HEADS or head in NODE_HEADS or head in EVAL_FLAGS:
        return _check_interpreter(head, args, ctx)
    if head in NPM_HEADS:
        lows = {_unquote(t).lower() for t in args}
        if lows & NPM_DENIED_SUBS:
            return _deny_wrapper()
        for tok in args:
            name = Path(_unquote(tok)).name.lower()
            name = name[:-4] if name.endswith(".exe") else name
            if name in SHELL_WRAPPER_HEADS or name in POSIX_SHELL_HEADS \
                    or name in INLINE_EXEC_HEADS:
                return _deny_wrapper()
        return ALLOW
    return ALLOW


def check_command(command: str, ctx: GuardContext) -> Decision:
    """Bash / PowerShell 的指令守衛。

    ⚠️ matcher 一定要同時含 ``Bash`` 與 ``PowerShell``：實測 Windows 上模型
    預設選 PowerShell，只擋 Bash 時連 ``echo hi`` 都直接跑過去。
    """
    if _SCRIPTBLOCK_RE.search(command):
        # `& { git push }`：`&` 是 split_commands 的分隔符，切完就看不到了
        return _deny_wrapper()
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
    if _GIT_ENV_WRITE_RE.search(segment):
        # run 進程的憑證是被刻意清掉的；能把它裝回去就等於沒清
        return _deny("git_credential_env", CREDENTIAL_REASON)
    wrapped = _check_wrapper(head, tokens, ctx)
    if not wrapped.allowed:
        return wrapped
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
# 讀取型工具要看的欄位。**不限 cwd，但敏感路徑一樣擋**
READ_TOOLS = {"Read": ("file_path",), "Glob": ("path", "pattern"),
              "Grep": ("path", "glob")}
COMMAND_TOOLS = {"Bash", "PowerShell"}
# hook 的 matcher 字串。**兩端要一致**，寫在這裡讓 settings 產生器直接引用
TOOL_MATCHER = ("Bash|PowerShell|Write|Edit|MultiEdit|NotebookEdit|"
                "Read|Glob|Grep")


def check_tool(tool_name: str, tool_input: dict,
               ctx: GuardContext) -> Decision:
    """一次工具呼叫的總判斷。不認得的工具一律放行（matcher 已經先篩過）。"""
    if tool_name in COMMAND_TOOLS:
        return check_command(str(tool_input.get("command") or ""), ctx)
    field_name = WRITE_TOOLS.get(tool_name)
    if field_name:
        return check_path(str(tool_input.get(field_name) or ""), ctx)
    read_fields = READ_TOOLS.get(tool_name)
    if read_fields:
        for name in read_fields:
            decision = check_read_path(str(tool_input.get(name) or ""), ctx)
            if not decision.allowed:
                return decision
    return ALLOW
