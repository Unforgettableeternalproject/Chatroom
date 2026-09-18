"""git 的薄包裝（儀表板、工作樹守衛、push run 共用）。

只做兩件事：跑 git、把輸出切成結構。**不做判斷**——「這個分支能不能推」是
``config`` 與 ``run`` 的事，混進來的話同一條規則會在三個地方各寫一次
（PM 記憶：一條規則三端實作，有一端不一樣就湊出死局）。
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from pathlib import Path

from .procs import no_window_kwargs

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
