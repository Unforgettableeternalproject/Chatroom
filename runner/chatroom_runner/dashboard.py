"""儀表板狀態（REMOTE-OPS-PLAN §4.4）。

Hub **原樣存、不解讀**，App 才是讀的人。所以形狀的權威在這裡——加一格只要改
這個檔與 App，不必動 Hub。

最重要的一格是「尚未推送的 commit」：本機沒有人類，push 是房內人類從儀表板
按的（§5.6），那份 sha 清單同時是 push run 的比對基準。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from . import gitops
from .config import RunnerConfig, branch_allowed


@dataclass
class RunView:
    """面板上一筆進行中的 run。``context_tokens`` 是**估算**（§10）。"""

    run_id: str
    kind: str = ""
    ref: str = ""
    project: str = ""
    repo: str = ""
    started_at: str = ""
    turns: int = 0
    context_tokens: int = 0
    # 多久沒吐出任何 stream 事件（秒）。0 ＝ 沒有停滯。**只是標記**：
    # run 沒有被殺，牆鐘上限照舊。面板上看得到才有人會去問它在做什麼
    stalled_seconds: int = 0

    def to_dict(self) -> dict:
        return {"run_id": self.run_id, "kind": self.kind, "ref": self.ref,
                "project": self.project, "repo": self.repo,
                "started_at": self.started_at, "turns": self.turns,
                "context_tokens": self.context_tokens,
                "stalled_seconds": self.stalled_seconds}


@dataclass
class RunnerRuntime:
    """執行器自己的狀態，heartbeat 時一起送。"""

    version: str = ""
    started_at: str = ""
    last_restart_reason: str = ""
    selfcheck: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {"version": self.version, "started_at": self.started_at,
                "last_restart_reason": self.last_restart_reason,
                "selfcheck_problems": list(self.selfcheck)}


async def repo_view(path: Path, push_branches: list[str],
                    stable_branch: str = "") -> dict:
    """一個 repo 的現況。git 壞掉時把錯誤**放進欄位**而不是丟例外——
    儀表板少一格與「這台機器上的 repo 讀不到了」不是同一件事。"""
    branch = await gitops.current_branch(path)
    if not branch:
        # 讀不到分支時形狀也要**完整**：少一格的話，App 那邊「沒設穩定分支」
        # 與「這個 repo 讀不到」會長成同一個樣子
        return {"path": str(path), "branch": "", "error": "無法讀取分支",
                "dirty": False, "unpushed_count": 0, "unpushed": [],
                "pushable": False, "fetch_stale": True,
                "stable_branch": stable_branch,
                "stable_branch_exists": False}
    # 🚨 先 fetch 再算未推送：不 fetch 的話 `origin/<b>..<b>` 用的是上次
    # fetch 時的遠端位置，面板上那份清單與 push run 的比對基準會一起過期。
    # fetch 失敗**只標記不擋**——連不上遠端與「這台機器讀不到 repo」不是同
    # 一件事，後者才該讓整格變成 error
    fetched = await gitops.git(path, "fetch", "origin", branch)
    commits = await gitops.unpushed(path, branch)
    dirty = await gitops.status_porcelain(path)
    # 上板的目標分支在不在。本機或 origin 有一邊就算——本機還沒有那條分支
    # 是正常的（上板時會從 `origin/<b>` 建），「兩邊都沒有」才是不能上板
    stable_exists = bool(stable_branch) and (
        await gitops.resolve_branch(path, stable_branch)).exists
    return {
        "path": str(path),
        "branch": branch,
        "fetch_stale": not fetched.ok,
        "dirty": bool(dirty),
        "dirty_count": len(dirty),
        "unpushed_count": len(commits),
        "unpushed": [c.to_dict() for c in commits],
        # 面板上的「推送」鈕要不要亮：分支不在可推清單裡就不該亮
        "pushable": branch_allowed(branch, push_branches),
        # 上板（release）用：空字串＝這個 repo 不參與上板
        "stable_branch": stable_branch,
        "stable_branch_exists": stable_exists,
    }


async def build(cfg: RunnerConfig, usage_window: dict, status: str,
                limited_until: str | None, limit_reason: str,
                runs: list[RunView], queued_count: int,
                runtime: RunnerRuntime) -> dict:
    # 面板欄位名 `repos` 不動：那是送給 Hub／App 的既有形狀。
    # 內容是每個工作區底下的每個專案（git repo）
    repos: dict[str, dict] = {}
    for workspace in cfg.workspaces.values():
        for name, project in workspace.projects.items():
            repos[f"{workspace.key}/{name}"] = await repo_view(
                project.path, project.push_branches, project.stable_branch)
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "repos": repos,
        # 工作區層級的設定（目前只有上板）。**`repos` 的形狀不動**：那是
        # 既有的契約，多一格工作區設定掛在這裡，Hub 照樣原樣存
        "workspaces": {ws.key: {"release": ws.release.to_dict()}
                       for ws in cfg.workspaces.values()},
        "usage": usage_window,
        "limits": {"status": status, "limited_until": limited_until,
                   "limit_reason": limit_reason},
        "runs": {"running": [r.to_dict() for r in runs],
                 "queued_count": queued_count,
                 "max_parallel": cfg.max_parallel},
        "runner": runtime.to_dict(),
    }
