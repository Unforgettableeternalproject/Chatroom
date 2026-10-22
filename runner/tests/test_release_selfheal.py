"""上板的自癒（無人值守時自己收斂並推上 origin）。

用真的 git（暫存的 bare origin 加一份 clone）與假 claude（`fake_claude.py` 的
`conflict_*` 情境）。每條測試盯著一個會安靜出錯的地方：還原有沒有真的把 HEAD
退回去、agent 交出的東西有沒有被機械驗證擋下、備份 ref 有沒有留下、自主動作
有沒有寫進結果。
"""

from __future__ import annotations

import asyncio
import dataclasses
import subprocess
import time
import uuid

import pytest

from chatroom_runner import gitops

from ._fixtures import git
from .test_release import (_RecordingHub, _break_gpg, _push_failed_once,
                           _ssh_key, executor, entry, make_config, make_repo,
                           make_run)


@pytest.fixture(autouse=True)
def _fake_claude_success(monkeypatch):
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "success")


def _scenario(monkeypatch, name: str) -> None:
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", name)


def _origin_commit(tmp_path, bare, branch: str, filename: str, text: str,
                   message: str) -> str:
    """從另一份 clone 往 origin 的 ``branch`` 推一顆 commit（模擬別人推進）。"""
    clone = tmp_path / f"other-{uuid.uuid4().hex[:8]}"
    git(tmp_path, "clone", "-q", str(bare), str(clone))
    git(clone, "checkout", branch)
    (clone / filename).write_text(text, encoding="utf-8")
    git(clone, "add", filename)
    git(clone, "commit", "-m", message)
    git(clone, "push", "origin", branch)
    return git(clone, "rev-parse", "HEAD")


def _commit_on(repo, branch: str, filename: str, text: str, message: str,
               *, back_to: str = "develop") -> None:
    git(repo, "checkout", branch)
    (repo / filename).write_text(text, encoding="utf-8")
    git(repo, "add", filename)
    git(repo, "commit", "-m", message)
    git(repo, "checkout", back_to)


def _merging(repo) -> bool:
    out = subprocess.run(["git", "rev-parse", "-q", "--verify", "MERGE_HEAD"],
                         cwd=str(repo), capture_output=True, text=True)
    return out.returncode == 0


def _assert_clean_and_home(repo, branch: str = "develop") -> None:
    assert not _merging(repo), "離開時還留著 MERGE_HEAD"
    assert git(repo, "status", "--porcelain") == ""
    assert git(repo, "rev-parse", "--abbrev-ref", "HEAD") == branch


def _stable_conflict(repo, bare) -> str:
    """穩定分支也改了 feature.txt 並推上去：來源分支合進來必衝突。回合併前的 main。"""
    _commit_on(repo, "main", "feature.txt", "穩定分支這邊\n", "穩定分支也改了同一個檔")
    git(repo, "push", "origin", "main")
    return git(repo, "rev-parse", "main")


def _backups(repo, branch: str = "main") -> list[str]:
    return git(repo, "for-each-ref", f"refs/runner-backup/{branch}/",
               "--format=%(objectname)").split()


# ── 1. 本機穩定分支與 origin 分岔 ───────────────────────────────

async def test_stable_diverged_redundant_merge_is_rebuilt_from_origin(
        tmp_path):
    """JSAI-Web 的實例：本機殘留一顆 merge commit（內容全在來源分支裡），
    origin 之後又前進了。⇒ 備份、重建自 origin、再併來源、推送。"""
    repo, bare = make_repo(tmp_path, "JSAI-Web")
    git(repo, "checkout", "main")
    git(repo, "merge", "--no-ff", "develop", "-m", "殘留的 merge")
    leftover = git(repo, "rev-parse", "main")
    git(repo, "checkout", "develop")
    _origin_commit(tmp_path, bare, "main", "other.txt", "其他\n",
                   "origin 上別人的變更")
    cfg = make_config(tmp_path, {"JSAI-Web": repo})

    outcome = await executor(cfg, _RecordingHub()).execute(
        make_run([entry()]))

    assert (outcome.status, outcome.reason) == ("done", "released"), \
        outcome.result
    assert "release_pull_failed" not in outcome.result
    assert "本機穩定分支重建自 origin，捨棄本機 2 顆 commit（內容皆已在 develop）" in outcome.result
    assert _backups(repo) == [leftover], "備份 ref 要指向重建前的本機 HEAD"
    assert "refs/runner-backup/main/" in outcome.result
    subjects = git(bare, "log", "main", "--format=%s")
    assert "origin 上別人的變更" in subjects and "功能一" in subjects
    assert git(bare, "rev-parse", "main") == git(repo, "rev-parse", "main")
    _assert_clean_and_home(repo)


def _diverged_with_unique_content(tmp_path):
    """本機 main 有一顆來源分支沒有的 commit（改 README），origin 也改了
    README：兩邊分岔、內容衝突。回 (repo, bare, 本機 main, origin 舊 main)。"""
    repo, bare = make_repo(tmp_path, "JSAI-Web")
    _commit_on(repo, "main", "README.md", "本機改的\n", "本機獨有的那顆")
    local = git(repo, "rev-parse", "main")
    origin_old = _origin_commit(tmp_path, bare, "main", "README.md",
                                "遠端改的\n", "遠端改的那顆")
    return repo, bare, local, origin_old


async def test_stable_diverged_unique_content_agent_fails_restores(
        tmp_path, monkeypatch):
    """本機獨有的內容不在來源分支 ⇒ 交給 agent；agent 失敗 ⇒ 還原本機、
    失敗收場，detail 列出是哪一顆，備份 ref 仍在，origin 一顆都沒動。"""
    _scenario(monkeypatch, "max_turns")
    repo, bare, local, origin_old = _diverged_with_unique_content(tmp_path)
    cfg = make_config(tmp_path, {"JSAI-Web": repo})

    outcome = await executor(cfg, _RecordingHub()).execute(
        make_run([entry()]))

    assert (outcome.status, outcome.reason) == ("failed", "release_partial")
    assert "release_stable_reconcile_failed" in outcome.result
    assert "本機獨有的那顆" in outcome.result
    assert "README.md" in outcome.result
    assert git(repo, "rev-parse", "main") == local, "本機要還原到原樣"
    assert git(bare, "rev-parse", "main") == origin_old
    assert _backups(repo) == [local]
    _assert_clean_and_home(repo)


async def test_stable_diverged_unique_content_agent_merges_on_origin_base(
        tmp_path, monkeypatch):
    """agent 解掉衝突 ⇒ 以 origin 為基礎併本機（第一個 parent 是 origin），
    接著照常上板、推送，結果寫明 agent 與衝突檔案。"""
    _scenario(monkeypatch, "conflict_resolve")
    repo, bare, local, origin_old = _diverged_with_unique_content(tmp_path)
    cfg = make_config(tmp_path, {"JSAI-Web": repo})

    outcome = await executor(cfg, _RecordingHub()).execute(
        make_run([entry()]))

    assert (outcome.status, outcome.reason) == ("done", "released"), \
        outcome.result
    assert "agent 解衝突" in outcome.result and "README.md" in outcome.result
    # main 是上板的 merge；它的第一個 parent 是 agent 解的那顆，其 parent
    # 依序是 origin 舊的 main 與本機舊的 main
    assert git(repo, "rev-parse", "main^1^1") == origin_old
    assert git(repo, "rev-parse", "main^1^2") == local
    assert git(bare, "rev-parse", "main") == git(repo, "rev-parse", "main")
    assert _backups(repo) == [local]
    _assert_clean_and_home(repo)


async def test_resume_head_leftover_is_pushed_without_backup(tmp_path):
    """本機只領先、HEAD == resume_head：照舊補推，不重建、不留備份 ref。"""
    repo, bare, cfg, first = await _push_failed_once(tmp_path)
    resume = first.git["repos"][0]["head_after"]
    (bare / "hooks" / "pre-receive").unlink()

    second = await executor(cfg, _RecordingHub()).execute(
        make_run([{**entry(), "resume_head": resume}], run_id="r-rel-2"))

    assert (second.status, second.reason) == ("done", "released")
    assert _backups(repo) == []
    assert "重建自 origin" not in second.result
    assert git(bare, "rev-parse", "main") == resume


# ── 2. 來源分支本機與 origin 分岔 ───────────────────────────────

def _diverge_source_on_feature_file(tmp_path):
    repo, bare = make_repo(tmp_path, "JSAI-Web")
    _origin_commit(tmp_path, bare, "develop", "feature.txt", "遠端改的\n",
                   "origin 上改 feature")
    _commit_on(repo, "develop", "feature.txt", "本機改的\n", "本機上改 feature")
    return repo, bare


async def test_source_diverged_conflict_is_resolved_by_agent(
        tmp_path, monkeypatch):
    _scenario(monkeypatch, "conflict_resolve")
    repo, bare = _diverge_source_on_feature_file(tmp_path)
    local = git(repo, "rev-parse", "develop")
    remote = git(bare, "rev-parse", "develop")
    cfg = make_config(tmp_path, {"JSAI-Web": repo})

    outcome = await executor(cfg, _RecordingHub()).execute(
        make_run([entry()]))

    assert (outcome.status, outcome.reason) == ("done", "released"), \
        outcome.result
    assert "agent 解衝突" in outcome.result and "feature.txt" in outcome.result
    assert git(repo, "show", "main:feature.txt") == "兩邊都保留"
    assert git(repo, "rev-parse", "develop") == local, "本機來源分支不該動"
    assert git(bare, "rev-parse", "develop") == remote, "來源分支不推送"
    _assert_clean_and_home(repo)


async def test_source_diverged_agent_failure_touches_nothing(
        tmp_path, monkeypatch):
    _scenario(monkeypatch, "max_turns")
    repo, bare = _diverge_source_on_feature_file(tmp_path)
    local = git(repo, "rev-parse", "develop")
    main_before = git(repo, "rev-parse", "main")
    cfg = make_config(tmp_path, {"JSAI-Web": repo})

    outcome = await executor(cfg, _RecordingHub()).execute(
        make_run([entry()]))

    assert (outcome.status, outcome.reason) == ("failed", "release_partial")
    assert "release_source_merge_failed" in outcome.result
    assert git(repo, "rev-parse", "develop") == local
    assert git(repo, "rev-parse", "main") == main_before
    assert git(bare, "rev-parse", "main") == main_before
    _assert_clean_and_home(repo)


# ── 3. source → stable 合併衝突 ────────────────────────────────

@pytest.mark.parametrize("method", ["merge", "squash"])
async def test_merge_conflict_is_resolved_signed_and_pushed(
        tmp_path, monkeypatch, method):
    _scenario(monkeypatch, "conflict_resolve")
    repo, bare = make_repo(tmp_path, "JSAI-Web")
    before = _stable_conflict(repo, bare)
    develop = git(repo, "rev-parse", "develop")
    cfg = make_config(tmp_path, {"JSAI-Web": repo},
                      release={"merge_method": method})

    outcome = await executor(cfg, _RecordingHub()).execute(
        make_run([entry()]))

    assert (outcome.status, outcome.reason) == ("done", "released"), \
        outcome.result
    assert "agent 解衝突" in outcome.result and "feature.txt" in outcome.result
    head = git(repo, "rev-parse", "main")
    assert head[:8] in outcome.result, "commit sha 要寫進結果"
    parents = git(repo, "rev-list", "--parents", "-n", "1", "main").split()[1:]
    assert parents == ([before, develop] if method == "merge" else [before])
    assert git(repo, "show", "main:feature.txt") == "兩邊都保留"
    assert git(bare, "rev-parse", "main") == head
    _assert_clean_and_home(repo)


async def test_agent_commit_is_signed_when_repo_requires_signing(
        tmp_path, monkeypatch):
    _scenario(monkeypatch, "conflict_resolve")
    repo, bare = make_repo(tmp_path, "JSAI-Web")
    before = _stable_conflict(repo, bare)
    _break_gpg(repo)
    cfg = make_config(tmp_path, {"JSAI-Web": repo},
                      agent_signing_key=_ssh_key(tmp_path))

    outcome = await executor(cfg, _RecordingHub()).execute(
        make_run([entry()]))

    assert outcome.status == "done", outcome.result
    assert git(repo, "rev-parse", "main") != before
    assert "BEGIN SSH SIGNATURE" in git(repo, "cat-file", "-p", "main")


async def test_unsigned_agent_commit_is_rejected_and_rolled_back(
        tmp_path, monkeypatch):
    _scenario(monkeypatch, "conflict_unsigned")
    repo, bare = make_repo(tmp_path, "JSAI-Web")
    before = _stable_conflict(repo, bare)
    _break_gpg(repo)
    cfg = make_config(tmp_path, {"JSAI-Web": repo},
                      agent_signing_key=_ssh_key(tmp_path))

    outcome = await executor(cfg, _RecordingHub()).execute(
        make_run([entry()]))

    assert (outcome.status, outcome.reason) == ("failed", "release_partial")
    assert "沒有簽章" in outcome.result
    assert git(repo, "rev-parse", "main") == before
    assert git(bare, "rev-parse", "main") == before
    _assert_clean_and_home(repo)


@pytest.mark.parametrize("scenario,needle", [
    ("conflict_markers", "衝突標記"),
    ("conflict_nocommit", "沒有產生合併 commit"),
    ("success", "沒有產生合併 commit"),
])
@pytest.mark.parametrize("method", ["merge", "squash"])
async def test_bad_agent_result_is_rolled_back_and_fails(
        tmp_path, monkeypatch, scenario, needle, method):
    """agent 留下衝突標記、沒 commit、或什麼都沒做 ⇒ 還原、失敗收場、
    沒有 MERGE_HEAD、已切回原分支、origin 沒動。"""
    _scenario(monkeypatch, scenario)
    repo, bare = make_repo(tmp_path, "JSAI-Web")
    before = _stable_conflict(repo, bare)
    cfg = make_config(tmp_path, {"JSAI-Web": repo},
                      release={"merge_method": method})

    outcome = await executor(cfg, _RecordingHub()).execute(
        make_run([entry()]))

    assert (outcome.status, outcome.reason) == ("failed", "release_partial")
    assert "release_merge_conflict" in outcome.result
    assert needle in outcome.result
    assert "feature.txt" in outcome.result
    assert git(repo, "rev-parse", "main") == before
    assert git(bare, "rev-parse", "main") == before
    _assert_clean_and_home(repo)


async def test_ff_only_never_merges_or_calls_the_agent(tmp_path, monkeypatch):
    _scenario(monkeypatch, "conflict_resolve")
    repo, bare = make_repo(tmp_path, "JSAI-Web")
    before = _stable_conflict(repo, bare)
    cfg = make_config(tmp_path, {"JSAI-Web": repo},
                      release={"merge_method": "ff_only"})

    outcome = await executor(cfg, _RecordingHub()).execute(
        make_run([entry()]))

    assert "release_ff_not_possible" in outcome.result
    assert "解衝突" not in outcome.result
    assert git(repo, "rev-parse", "main") == before
    _assert_clean_and_home(repo)


# ── 4. push 被拒 ───────────────────────────────────────────────

def _race_on_push(monkeypatch, tmp_path, bare, *, times: int):
    """前 ``times`` 次推 main 之前，先讓別人往 origin 塞一顆（非快轉）。"""
    real = gitops.push_ref
    state = {"calls": 0, "raced": 0}

    async def racing(path, ref, extra=None):
        if ref == "main":
            state["calls"] += 1
            if state["raced"] < times:
                state["raced"] += 1
                _origin_commit(tmp_path, bare, "main",
                               f"race{state['raced']}.txt", "搶先\n",
                               f"別人搶先推的 {state['raced']}")
        return await real(path, ref, extra)

    monkeypatch.setattr(gitops, "push_ref", racing)
    return state


async def test_push_rejected_once_fetches_merges_and_retries(
        tmp_path, monkeypatch):
    repo, bare = make_repo(tmp_path, "JSAI-Web")
    state = _race_on_push(monkeypatch, tmp_path, bare, times=1)
    cfg = make_config(tmp_path, {"JSAI-Web": repo})

    outcome = await executor(cfg, _RecordingHub()).execute(
        make_run([entry()]))

    assert (outcome.status, outcome.reason) == ("done", "released"), \
        outcome.result
    assert state["calls"] == 2
    assert "共推送 2 次" in outcome.result
    subjects = git(bare, "log", "main", "--format=%s")
    assert "別人搶先推的 1" in subjects and "功能一" in subjects
    assert git(bare, "rev-parse", "main") == git(repo, "rev-parse", "main")
    _assert_clean_and_home(repo)


async def test_push_keeps_being_rejected_gives_up_after_three(
        tmp_path, monkeypatch):
    repo, bare = make_repo(tmp_path, "JSAI-Web")
    state = _race_on_push(monkeypatch, tmp_path, bare, times=99)
    cfg = make_config(tmp_path, {"JSAI-Web": repo})

    outcome = await executor(cfg, _RecordingHub()).execute(
        make_run([entry()]))

    assert (outcome.status, outcome.reason) == ("failed", "release_partial")
    assert "release_push_failed" in outcome.result
    assert "3 次都被拒" in outcome.result
    assert state["calls"] == 3
    assert "功能一" not in git(bare, "log", "main", "--format=%s")
    # Hub 補推要認的 HEAD：失敗當下本機穩定分支的那一顆
    assert outcome.git["repos"][0]["head_after"] == git(repo, "rev-parse",
                                                        "main")
    _assert_clean_and_home(repo)


async def test_hook_rejection_is_not_retried(tmp_path, monkeypatch):
    """遠端 hook 擋下不是「origin 前進了」，重推只會再被擋。"""
    from .test_release import _reject_hook
    repo, bare = make_repo(tmp_path, "JSAI-Web")
    _reject_hook(bare, "exit 1")
    real = gitops.push_ref
    calls = []

    async def counting(path, ref, extra=None):
        calls.append(ref)
        return await real(path, ref, extra)

    monkeypatch.setattr(gitops, "push_ref", counting)
    cfg = make_config(tmp_path, {"JSAI-Web": repo})

    outcome = await executor(cfg, _RecordingHub()).execute(
        make_run([entry()]))

    assert "release_push_failed" in outcome.result
    assert calls == ["main"]


# ── 5. 還原 bug：commit 已經產生，但 merge 回報失敗／逾時 ──────

@pytest.mark.parametrize("method", ["merge", "squash"])
async def test_failed_or_timed_out_merge_that_already_committed_is_reset(
        tmp_path, monkeypatch, method):
    """簽章逾時被殺時 commit 其實已經產生；`merge --abort` 收不掉它。
    要 `reset --hard` 回合併前的 HEAD（10/15 JSAI-Web 殘留 8ab57a27 的成因）。"""
    repo, bare = make_repo(tmp_path, "JSAI-Web")
    before = git(repo, "rev-parse", "main")
    if method == "merge":
        real = gitops.merge_no_ff

        async def merge_then_timeout(path, ref, message, extra=None):
            await real(path, ref, message, extra)
            return gitops.GitResult(124, "", "git merge 逾時")

        monkeypatch.setattr(gitops, "merge_no_ff", merge_then_timeout)
    else:
        real_commit = gitops.commit

        async def commit_then_timeout(path, message, extra=None):
            await real_commit(path, message, extra)
            return gitops.GitResult(124, "", "git commit 逾時")

        monkeypatch.setattr(gitops, "commit", commit_then_timeout)
    cfg = make_config(tmp_path, {"JSAI-Web": repo},
                      release={"merge_method": method})

    outcome = await executor(cfg, _RecordingHub()).execute(
        make_run([entry()]))

    assert (outcome.status, outcome.reason) == ("failed", "release_partial")
    assert "release_merge_failed" in outcome.result
    assert git(repo, "rev-parse", "main") == before, \
        "commit 已經產生，HEAD 沒有被退回去"
    assert git(bare, "rev-parse", "main") == before
    _assert_clean_and_home(repo)


# ── 7. agent 逾時、被取消 ─────────────────────────────────────

async def test_agent_wall_clock_timeout_restores(tmp_path, monkeypatch):
    _scenario(monkeypatch, "long")
    monkeypatch.setenv("FAKE_CLAUDE_SLEEP", "60")
    repo, bare = make_repo(tmp_path, "JSAI-Web")
    before = _stable_conflict(repo, bare)
    cfg = make_config(tmp_path, {"JSAI-Web": repo})
    cfg.workspaces["ai-website"] = dataclasses.replace(
        cfg.workspaces["ai-website"], wall_clock_seconds=2)

    outcome = await executor(cfg, _RecordingHub()).execute(
        make_run([entry()]))

    assert (outcome.status, outcome.reason) == ("failed", "release_partial")
    assert "wall clock" in outcome.result
    assert git(repo, "rev-parse", "main") == before
    _assert_clean_and_home(repo)


async def test_cancel_while_agent_runs_restores(tmp_path, monkeypatch):
    _scenario(monkeypatch, "long")
    monkeypatch.setenv("FAKE_CLAUDE_SLEEP", "60")
    repo, bare = make_repo(tmp_path, "JSAI-Web")
    before = _stable_conflict(repo, bare)
    cfg = make_config(tmp_path, {"JSAI-Web": repo})
    cancel = asyncio.Event()
    task = asyncio.create_task(executor(cfg, _RecordingHub()).execute(
        make_run([entry()]), cancel))
    stream = cfg.runs_dir / "r-rel" / "stream.jsonl"
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if stream.exists() and stream.stat().st_size > 0:
            break
        await asyncio.sleep(0.1)
    assert _merging(repo), "agent 起來的時候合併應該停在衝突狀態"
    cancel.set()
    outcome = await asyncio.wait_for(task, timeout=60)

    assert (outcome.status, outcome.reason) == ("failed", "release_partial")
    assert "收到取消" in outcome.result
    assert git(repo, "rev-parse", "main") == before
    _assert_clean_and_home(repo)


async def test_untracked_leftover_from_agent_is_cleaned_on_restore(
        tmp_path, monkeypatch):
    """agent 留下未追蹤的 .orig ⇒ 還原要成功、工作樹乾淨（不然下一次上板
    會撞 release_dirty）；被忽略的檔案不動。"""
    _scenario(monkeypatch, "conflict_orig")
    repo, bare = make_repo(tmp_path, "JSAI-Web")
    before = _stable_conflict(repo, bare)
    cfg = make_config(tmp_path, {"JSAI-Web": repo})

    outcome = await executor(cfg, _RecordingHub()).execute(
        make_run([entry()]))

    assert (outcome.status, outcome.reason) == ("failed", "release_partial")
    assert "還原失敗" not in outcome.result
    assert not (repo / "agent-scratch.orig.txt").exists()
    assert git(repo, "rev-parse", "main") == before
    _assert_clean_and_home(repo)
