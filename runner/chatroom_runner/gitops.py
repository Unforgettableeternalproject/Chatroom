"""git 的薄包裝（儀表板、工作樹守衛、push run 共用）。

只做兩件事：跑 git、把輸出切成結構。**不做判斷**——「這個分支能不能推」是
``config`` 與 ``run`` 的事，混進來的話同一條規則會在三個地方各寫一次
（PM 記憶：一條規則三端實作，有一端不一樣就湊出死局）。
"""

from __future__ import annotations

import asyncio
import re
from dataclasses import dataclass, field
from pathlib import Path

from .procs import no_window_kwargs

# git ref 名的白名單：不以 `-` 開頭、不含空白與 `..`，只放行 `A-Za-z0-9._/-`。
# 與 Hub 端 `_GIT_REF_PATTERN` 同一條（PM 記憶：一條規則三端實作，有一端不
# 一樣就湊出死局）；這些值會原樣進 git argv，`-` 開頭就是一個 git 參數。
_GIT_REF_PATTERN = re.compile(r"^(?!-)(?!.*\.\.)[A-Za-z0-9._/-]+$")


def valid_ref_name(value: str) -> bool:
    """這個分支名／tag 名能不能安全地放進 git argv。"""
    return bool(_GIT_REF_PATTERN.match(value or ""))


# 未推送清單的格式：sha \x1f 標題 \x1f ISO 時間
_LOG_FORMAT = "%H%x1f%s%x1f%cI"


@dataclass
class GitResult:
    code: int
    out: str
    err: str

    @property
    def ok(self) -> bool:
        return self.code == 0


async def git(repo: Path, *args: str, timeout: float = 60.0) -> GitResult:
    try:
        proc = await asyncio.create_subprocess_exec(
            "git", *args, cwd=str(repo),
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            **no_window_kwargs())
    except OSError as exc:
        # 路徑不存在（被搬走、被刪掉）時**回一筆失敗**，不要往上炸：
        # 儀表板要能顯示「這個 repo 讀不到」，而不是整份心跳生不出來
        return GitResult(127, "", f"起不了 git（{repo}）：{exc}")
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return GitResult(124, "", f"git {' '.join(args)} 逾時")
    return GitResult(proc.returncode or 0,
                     out.decode("utf-8", "replace").strip(),
                     err.decode("utf-8", "replace").strip())


async def current_branch(repo: Path) -> str:
    res = await git(repo, "rev-parse", "--abbrev-ref", "HEAD")
    return res.out if res.ok else ""


async def head_sha(repo: Path) -> str:
    res = await git(repo, "rev-parse", "HEAD")
    return res.out if res.ok else ""


async def status_porcelain(repo: Path) -> list[str]:
    res = await git(repo, "status", "--porcelain")
    return [line for line in res.out.splitlines() if line.strip()]


async def has_upstream(repo: Path) -> bool:
    """目前分支有沒有設 upstream。沒有的話 ``git pull`` 根本無從比起。"""
    res = await git(repo, "rev-parse", "--abbrev-ref", "@{u}")
    return res.ok and bool(res.out)


async def fetch(repo: Path) -> GitResult:
    """把遠端現況抓下來。失敗（多半是網路）由呼叫端決定要不要擋。"""
    return await git(repo, "fetch")


@dataclass
class PullOutcome:
    """``pull --ff-only`` 的結果。

    ``ok`` 為假只有一個意思：**不能快轉**（分支分岔或遠端讀不到），不是
    「沒有更新」——已經是最新時 ``ok`` 仍為真。兩者混在同一個空字串裡的話，
    呼叫端沒辦法分開處理。
    """

    ok: bool
    summary: str


async def pull_ff(repo: Path) -> PullOutcome:
    before = await head_sha(repo)
    res = await git(repo, "pull", "--ff-only")
    if not res.ok:
        return PullOutcome(False, res.err or res.out)
    after = await head_sha(repo)
    if not before or before == after:
        return PullOutcome(True, "已是最新")
    counted = await git(repo, "rev-list", "--count", f"{before}..{after}")
    n = counted.out if counted.ok and counted.out else "?"
    return PullOutcome(True, f"已快轉 {n} 個 commit")


@dataclass
class Commit:
    sha: str
    title: str
    at: str

    def to_dict(self) -> dict:
        return {"sha": self.sha, "title": self.title, "at": self.at}


async def unpushed(repo: Path, branch: str) -> list[Commit]:
    """``origin/<branch>..<branch>`` 的 commit。

    遠端沒有這條分支時 git 會失敗——那時回空清單而不是炸：「還沒推過的新分支」
    與「git 壞了」在儀表板上要分得開，後者由 ``dirty``／錯誤欄位講。
    """
    res = await git(repo, "log", f"origin/{branch}..{branch}",
                    f"--format={_LOG_FORMAT}")
    if not res.ok:
        return []
    commits: list[Commit] = []
    for line in res.out.splitlines():
        parts = line.split("\x1f")
        if len(parts) == 3:
            commits.append(Commit(parts[0], parts[1], parts[2]))
    return commits


@dataclass
class RepoSnapshot:
    """run 開始前後各拍一張，比對出「這一輪動了什麼」（§5.5）。"""

    branch: str = ""
    head: str = ""
    dirty: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {"branch": self.branch, "head": self.head,
                "dirty": list(self.dirty)}


async def snapshot(repo: Path) -> RepoSnapshot:
    return RepoSnapshot(branch=await current_branch(repo),
                        head=await head_sha(repo),
                        dirty=await status_porcelain(repo))


def diff_snapshots(before: RepoSnapshot, after: RepoSnapshot) -> dict:
    """兩張快照的差。**不自動 stash、不自動還原**——未 commit 的東西由 agent
    在收工摘要列出，執行器只負責讓它在紀錄裡講得出來。"""
    before_set = set(before.dirty)
    after_set = set(after.dirty)
    return {
        "branch_changed": before.branch != after.branch,
        "branch_before": before.branch,
        "branch_after": after.branch,
        "head_changed": before.head != after.head,
        "head_before": before.head,
        "head_after": after.head,
        "new_dirty": sorted(after_set - before_set),
        "resolved_dirty": sorted(before_set - after_set),
    }


# ---------- 上板（release）用的薄包裝 ----------
#
# 一樣**不做判斷**：要不要合、合不合得起來由 `run._release` 決定，這裡只負責
# 把指令跑出來、把輸出切成結構。`extra` 是要插在子指令前的 `-c key=value`
# 之類的全域參數（推送憑證走這條，見 `run.RunExecutor._push_credential_args`）。


async def ref_exists(repo: Path, ref: str) -> bool:
    """本機看得到這個 ref 嗎。``origin/<b>`` 也走同一條。"""
    if not ref:
        return False
    res = await git(repo, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}")
    return res.ok and bool(res.out)


async def rev_parse(repo: Path, ref: str) -> str:
    """一個 ref 指到哪一顆。讀不到回空字串。"""
    res = await git(repo, "rev-parse", "--verify", "--quiet",
                    f"{ref}^{{commit}}")
    return res.out if res.ok else ""


async def is_ancestor(repo: Path, ancestor: str, descendant: str) -> bool:
    """``ancestor`` 是不是 ``descendant`` 的祖先（同一顆也算）。

    ``merge-base --is-ancestor`` 用離開碼回答：0 是、1 不是。其他碼（壞掉的
    ref、git 起不來）一律當成「不是」——這裡的呼叫端拿它決定要不要合，答不
    出來時保守處理比猜一個方向安全。
    """
    res = await git(repo, "merge-base", "--is-ancestor", ancestor, descendant)
    return res.code == 0


@dataclass
class BranchRef:
    """``resolve_branch`` 的結果。

    ``ref`` 是**可以直接拿去 merge 的那一條**；兩邊都沒有、或本機與 origin
    已經分岔時它是空字串，那兩種要靠 ``exists``／``diverged`` 分開——「這條
    分支不存在」與「兩邊各走各的」的處置完全不同。
    """

    ref: str = ""
    local_sha: str = ""
    remote_sha: str = ""
    diverged: bool = False

    @property
    def exists(self) -> bool:
        """本機或 origin 至少有一邊看得到這條分支。"""
        return bool(self.ref) or self.diverged


async def resolve_branch(repo: Path, branch: str) -> BranchRef:
    """挑出這條分支**該拿去合的那一顆**（fetch 之後呼叫才有意義）。

    🚨 不能無條件優先本機（審查 09/22）：fetch 回來的 ``origin/<b>`` 比本機
    新時，用本機的 tip 去合會併進一份**舊的**來源，然後回報成功——人類看到
    綠燈，而遠端上的那幾顆根本沒上板。所以兩邊都在時比祖先關係：

    - 本機是 ``origin/<b>`` 的祖先（含相同）→ 用 ``origin/<b>``。
    - ``origin/<b>`` 是本機的祖先 → 用本機（本機領先，多半是剛 commit 完）。
    - 互不是祖先 ⇒ **分岔**：不挑，回 ``diverged``，由呼叫端收成錯誤。
      這裡不做判斷（見模組開頭），但「挑哪一邊」在分岔時沒有安全的答案。
    """
    local_sha = await rev_parse(repo, branch) if branch else ""
    remote = f"origin/{branch}" if branch else ""
    remote_sha = await rev_parse(repo, remote) if branch else ""
    if not local_sha and not remote_sha:
        return BranchRef()
    if not remote_sha:
        return BranchRef(ref=branch, local_sha=local_sha)
    if not local_sha:
        return BranchRef(ref=remote, remote_sha=remote_sha)
    if local_sha == remote_sha:
        return BranchRef(ref=branch, local_sha=local_sha,
                         remote_sha=remote_sha)
    if await is_ancestor(repo, local_sha, remote_sha):
        return BranchRef(ref=remote, local_sha=local_sha,
                         remote_sha=remote_sha)
    if await is_ancestor(repo, remote_sha, local_sha):
        return BranchRef(ref=branch, local_sha=local_sha,
                         remote_sha=remote_sha)
    return BranchRef(local_sha=local_sha, remote_sha=remote_sha,
                     diverged=True)


async def checkout(repo: Path, branch: str) -> GitResult:
    """切到既有的本機分支。"""
    return await git(repo, "checkout", branch)


async def checkout_tracking(repo: Path, branch: str) -> GitResult:
    """本機還沒有這條分支時，從 ``origin/<b>`` 建一條出來並切過去。"""
    return await git(repo, "checkout", "-b", branch, f"origin/{branch}")


async def pull_ff_branch(repo: Path, branch: str,
                         extra: list[str] | None = None) -> GitResult:
    return await git(repo, *(extra or []), "pull", "--ff-only", "origin",
                     branch)


async def merge_no_ff(repo: Path, ref: str, message: str) -> GitResult:
    return await git(repo, "merge", "--no-ff", ref, "-m", message)


async def merge_squash(repo: Path, ref: str) -> GitResult:
    """``merge --squash`` **只把變更放進索引**，commit 要另外下（見 `commit`）。"""
    return await git(repo, "merge", "--squash", ref)


async def merge_ff_only(repo: Path, ref: str) -> GitResult:
    return await git(repo, "merge", "--ff-only", ref)


async def commit(repo: Path, message: str) -> GitResult:
    return await git(repo, "commit", "-m", message)


async def merge_abort(repo: Path) -> GitResult:
    """把合到一半的狀態收掉。沒有在合併中時 git 會失敗，呼叫端不必在意。"""
    return await git(repo, "merge", "--abort")


async def reset_hard(repo: Path, ref: str) -> GitResult:
    """``merge --squash`` 撞衝突時沒有 MERGE_HEAD，``merge --abort`` 收不掉，
    只能硬退回合併前的位置。"""
    return await git(repo, "reset", "--hard", ref)


async def conflicted_files(repo: Path) -> list[str]:
    res = await git(repo, "diff", "--name-only", "--diff-filter=U")
    return [line for line in res.out.splitlines() if line.strip()]


async def count_commits(repo: Path, base: str, head: str) -> int:
    """``base..head`` 有幾顆。算不出來回 ``-1``，與「零顆」分得開。"""
    res = await git(repo, "rev-list", "--count", f"{base}..{head}")
    if not res.ok or not res.out.isdigit():
        return -1
    return int(res.out)


async def log_oneline(repo: Path, base: str, head: str,
                      limit: int = 50) -> list[str]:
    res = await git(repo, "log", f"-{limit}", "--oneline", f"{base}..{head}")
    if not res.ok:
        return []
    return [line for line in res.out.splitlines() if line.strip()]


async def tag_annotated(repo: Path, tag: str, message: str) -> GitResult:
    return await git(repo, "tag", "-a", tag, "-m", message)


async def tag_exists(repo: Path, tag: str) -> bool:
    res = await git(repo, "tag", "--list", tag)
    return res.ok and bool(res.out.strip())


async def push_ref(repo: Path, ref: str,
                   extra: list[str] | None = None) -> GitResult:
    """推一條分支或一個 tag。憑證參數由呼叫端給（push run 那一套）。"""
    return await git(repo, *(extra or []), "push", "origin", ref)


async def fetch_origin(repo: Path, extra: list[str] | None = None
                       ) -> GitResult:
    return await git(repo, *(extra or []), "fetch", "origin")
