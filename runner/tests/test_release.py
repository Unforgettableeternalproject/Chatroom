"""上板（release）的執行（契約 C1／C2／C3／C5 的執行器半邊）。

git 的部分**不經模型**，所以這裡用的是真的 git：暫存的 bare origin 加一份
clone，每條測試盯著一個會安靜失敗的地方——合併方式沒照設定走、訊息模板渲染
炸掉、衝突沒還原、髒工作樹被硬併、沒東西可併被算成失敗、一個 repo 失敗卻報
成功、終局回報少了 git 欄位。

報告那一支 agent 用假的 claude（`fake_claude.py`），不起真的。
"""

from __future__ import annotations

import asyncio
import subprocess

import pytest

from chatroom_runner import dashboard
from chatroom_runner.config import (DEFAULT_MERGE_METHOD, ReleaseConfig,
                                    config_from_dict, render_template)
from chatroom_runner.run import RunExecutor
from chatroom_runner.usage import UsageStore

from ._fixtures import config_raw, git


@pytest.fixture(autouse=True)
def _fake_claude_success(monkeypatch):
    """報告子進程一律走「正常收工」的假 claude。"""
    monkeypatch.setenv("FAKE_CLAUDE_SCENARIO", "success")


class _RecordingHub:
    """把每一次回報留下來。上板的 Hub 端點是另一半的事，這裡只驗執行器送什麼。"""

    def __init__(self) -> None:
        self.reports: list[tuple[str, dict]] = []

    async def report(self, run_id: str, status: str, **kw):
        self.reports.append((status, kw))
        return None

    def final(self) -> tuple[str, dict]:
        return self.reports[-1]


def make_repo(tmp_path, name: str, *, stable: str = "main",
              source: str = "develop"):
    """一份掛著 bare origin 的 clone：``stable`` 一顆、``source`` 多一顆。

    回傳 ``(repo, bare)``；工作樹停在 ``source`` 上（上板要切走再切回來）。
    """
    bare = tmp_path / f"{name}.git"
    bare.mkdir()
    subprocess.run(["git", "init", "--bare", "-b", stable, str(bare)],
                   capture_output=True, check=True)
    repo = tmp_path / name
    repo.mkdir()
    git(repo, "init", "-b", stable)
    # 被測的 gitops 用的是 repo 自己的設定，不是測試 helper 塞的 -c：CI 的
    # runner 沒有全域身分也沒有簽章金鑰，merge／squash 那顆 commit 會在那裡
    # 炸成「Committer identity unknown」。寫進 repo 本機設定，兩邊同一份
    git(repo, "config", "user.email", "runner@test")
    git(repo, "config", "user.name", "runner")
    git(repo, "config", "commit.gpgsign", "false")
    git(repo, "config", "tag.gpgsign", "false")
    git(repo, "remote", "add", "origin", str(bare))
    (repo / "README.md").write_text("測試用\n", encoding="utf-8")
    git(repo, "add", "README.md")
    git(repo, "commit", "-m", "init")
    git(repo, "push", "-u", "origin", stable)
    git(repo, "checkout", "-b", source)
    (repo / "feature.txt").write_text("功能\n", encoding="utf-8")
    git(repo, "add", "feature.txt")
    git(repo, "commit", "-m", "功能一")
    git(repo, "push", "-u", "origin", source)
    return repo, bare


@pytest.fixture
def release_repo(tmp_path):
    repo, _bare = make_repo(tmp_path, "JSAI-Web")
    return repo


def make_config(tmp_path, repos: dict, *, release: dict | None = None,
                stable: str = "main"):
    """指向這些 repo 的執行器設定。``repos`` 是 名稱 → 路徑。"""
    first = next(iter(repos.values()))
    raw = config_raw(tmp_path, first)
    ws = raw["workspaces"]["ai-website"]
    ws["projects"] = {
        name: {"path": str(path),
               "allowed_branches": ["*"],
               "push_branches": ["*"],
               "stable_branch": stable}
        for name, path in repos.items()}
    ws["default_project"] = next(iter(repos))
    if release is not None:
        ws["release"] = release
    return config_from_dict(raw, base_dir=tmp_path)


def make_run(repos: list[dict], *, tag: str = "", run_id: str = "r-rel"):
    """直接構造一筆含 spec 的 release run（Hub 端點是另一半的事）。"""
    return {"id": run_id, "kind": "release", "project": "ai-website",
            "ref": "obj-1", "brief": "", "room_id": "room-1",
            "spec": {"objective_id": "obj-1", "objective_title": "第一週期",
                     "room_id": "room-1", "repos": repos, "tag": tag}}


def entry(name: str = "JSAI-Web", source: str = "develop",
          stable: str = "main") -> dict:
    return {"name": name, "source_branch": source, "stable_branch": stable}


def executor(cfg, hub):
    return RunExecutor(cfg, hub, usage_store=UsageStore(cfg.usage_db))


# ── 三種合併方式 ────────────────────────────────────────────────

async def test_merge_method_merge_makes_a_merge_commit(tmp_path,
                                                       release_repo):
    """預設 `merge` ＝ `--no-ff`：穩定分支上要留下一顆合併 commit。

    留不留得下來是「這個週期是一次上板」的唯一證據——被快轉掉的話，歷史上
    看不出哪幾顆是同一次上板進來的。
    """
    cfg = make_config(tmp_path, {"JSAI-Web": release_repo},
                      release={"merge_method": "merge",
                               "merge_message": "release: 併入 {source}"})
    hub = _RecordingHub()

    outcome = await executor(cfg, hub).execute(make_run([entry()]))

    assert (outcome.status, outcome.reason) == ("done", "released"), \
        outcome.result
    subject = git(release_repo, "log", "-1", "--format=%s", "main")
    assert subject == "release: 併入 develop"
    parents = git(release_repo, "log", "-1", "--format=%P", "main").split()
    assert len(parents) == 2, "沒有合併 commit 就等於被快轉掉了"
    # 推上去了才算上板
    assert git(release_repo, "rev-parse", "main") == \
        git(release_repo, "rev-parse", "origin/main")
    # 收工要切回原分支，不然下一輪 run 會在穩定分支上開工
    assert git(release_repo, "rev-parse", "--abbrev-ref", "HEAD") == "develop"


async def test_merge_method_squash_lands_one_commit(tmp_path, release_repo):
    cfg = make_config(tmp_path, {"JSAI-Web": release_repo},
                      release={"merge_method": "squash",
                               "merge_message": "release: squash {source}"})
    hub = _RecordingHub()

    outcome = await executor(cfg, hub).execute(make_run([entry()]))

    assert outcome.status == "done", outcome.result
    assert git(release_repo, "log", "-1", "--format=%s",
               "main") == "release: squash develop"
    parents = git(release_repo, "log", "-1", "--format=%P", "main").split()
    assert len(parents) == 1, "squash 不該留下合併 commit"


async def test_merge_method_ff_only_fast_forwards(tmp_path, release_repo):
    cfg = make_config(tmp_path, {"JSAI-Web": release_repo},
                      release={"merge_method": "ff_only"})
    hub = _RecordingHub()

    outcome = await executor(cfg, hub).execute(make_run([entry()]))

    assert outcome.status == "done", outcome.result
    assert git(release_repo, "rev-parse", "main") == \
        git(release_repo, "rev-parse", "develop"), "快轉後兩邊要同一顆"


async def test_ff_only_fails_when_branches_diverged(tmp_path, release_repo):
    """穩定分支自己有新 commit 時 `ff_only` 快轉不了——那要說出來，不是默默合。"""
    git(release_repo, "checkout", "main")
    (release_repo / "hotfix.txt").write_text("急修\n", encoding="utf-8")
    git(release_repo, "add", "hotfix.txt")
    git(release_repo, "commit", "-m", "急修")
    git(release_repo, "push", "origin", "main")
    git(release_repo, "checkout", "develop")
    cfg = make_config(tmp_path, {"JSAI-Web": release_repo},
                      release={"merge_method": "ff_only"})
    hub = _RecordingHub()

    outcome = await executor(cfg, hub).execute(make_run([entry()]))

    assert (outcome.status, outcome.reason) == ("failed", "release_partial")
    assert "release_ff_not_possible" in outcome.result


# ── 訊息模板 ────────────────────────────────────────────────────

async def test_merge_message_renders_placeholders(tmp_path, release_repo):
    """模板的佔位符要渲染，**未知的鍵不能炸**——模板是人在 App 上打的。"""
    cfg = make_config(
        tmp_path, {"JSAI-Web": release_repo},
        release={"merge_method": "merge",
                 "merge_message": "上板 {repo}：{source}→{stable}"
                                  "（{objective}）{未知的鍵}"})
    hub = _RecordingHub()

    outcome = await executor(cfg, hub).execute(make_run([entry()]))

    assert outcome.status == "done", outcome.result
    assert git(release_repo, "log", "-1", "--format=%s", "main") == \
        "上板 JSAI-Web：develop→main（第一週期）"


def test_render_template_handles_unknown_and_broken_templates():
    values = {"source": "develop"}
    assert render_template("併 {source} {nope}", values) == "併 develop "
    # 括號不成對時原樣回傳，不丟例外：這條字串只是 commit 訊息
    assert render_template("併 {source", values) == "併 {source"


# ── tag ─────────────────────────────────────────────────────────

async def test_tag_is_created_and_pushed(tmp_path, release_repo):
    cfg = make_config(tmp_path, {"JSAI-Web": release_repo},
                      release={"merge_method": "merge",
                               "tag_message": "{objective} / {stable}"})
    hub = _RecordingHub()

    outcome = await executor(cfg, hub).execute(
        make_run([entry()], tag="v1.0.0"))

    assert outcome.status == "done", outcome.result
    assert git(release_repo, "tag", "--list", "v1.0.0") == "v1.0.0"
    assert "第一週期 / main" in git(release_repo, "tag", "-n99", "--list",
                                    "v1.0.0")
    assert "refs/tags/v1.0.0" in git(release_repo, "ls-remote", "--tags",
                                     "origin"), "tag 沒推上去等於只有本機看得到"


async def test_existing_tag_fails_but_says_the_merge_landed(tmp_path,
                                                            release_repo):
    """tag 撞名要失敗，但**合併與推送已經完成**這件事要如實寫出來。"""
    # 這台機器的全域設定會把 tag 簽起來，輕量 tag 會要不到訊息；
    # 測試的 repo 是拋棄式的，這裡明確關掉簽章（不影響專案規則）
    git(release_repo, "-c", "tag.gpgSign=false", "tag", "-a", "v1.0.0",
        "-m", "早就存在的 tag")
    cfg = make_config(tmp_path, {"JSAI-Web": release_repo})
    hub = _RecordingHub()

    outcome = await executor(cfg, hub).execute(
        make_run([entry()], tag="v1.0.0"))

    assert (outcome.status, outcome.reason) == ("failed", "release_partial")
    assert "release_tag_exists" in outcome.result
    assert "已併進 main 並推送" in outcome.result
    assert git(release_repo, "rev-parse", "main") == \
        git(release_repo, "rev-parse", "origin/main")


# ── 擋下來的情況 ────────────────────────────────────────────────

async def test_conflict_aborts_and_leaves_stable_untouched(tmp_path,
                                                           release_repo):
    """衝突要 `merge --abort`，穩定分支停在合併前那一顆。

    沒還原的話，工作樹會留在一個合到一半的狀態，而下一筆 run 會在那上面動工。
    """
    git(release_repo, "checkout", "main")
    (release_repo / "feature.txt").write_text("穩定分支這邊\n",
                                              encoding="utf-8")
    git(release_repo, "add", "feature.txt")
    git(release_repo, "commit", "-m", "穩定分支也改了同一個檔")
    git(release_repo, "push", "origin", "main")
    before = git(release_repo, "rev-parse", "main")
    git(release_repo, "checkout", "develop")
    cfg = make_config(tmp_path, {"JSAI-Web": release_repo})
    hub = _RecordingHub()

    outcome = await executor(cfg, hub).execute(make_run([entry()]))

    assert (outcome.status, outcome.reason) == ("failed", "release_partial")
    assert "release_merge_conflict" in outcome.result
    assert "feature.txt" in outcome.result, "衝突檔案清單要寫進結果"
    assert git(release_repo, "rev-parse", "main") == before
    assert git(release_repo, "status", "--porcelain") == "", \
        "合到一半的狀態沒收乾淨"
    assert git(release_repo, "rev-parse", "--abbrev-ref", "HEAD") == "develop"


async def test_squash_conflict_resets_back_to_stable(tmp_path, release_repo):
    """`merge --squash` 撞衝突時沒有 MERGE_HEAD，只能 `reset --hard` 收。"""
    git(release_repo, "checkout", "main")
    (release_repo / "feature.txt").write_text("穩定分支這邊\n",
                                              encoding="utf-8")
    git(release_repo, "add", "feature.txt")
    git(release_repo, "commit", "-m", "穩定分支也改了同一個檔")
    git(release_repo, "push", "origin", "main")
    before = git(release_repo, "rev-parse", "main")
    git(release_repo, "checkout", "develop")
    cfg = make_config(tmp_path, {"JSAI-Web": release_repo},
                      release={"merge_method": "squash"})
    hub = _RecordingHub()

    outcome = await executor(cfg, hub).execute(make_run([entry()]))

    assert (outcome.status, outcome.reason) == ("failed", "release_partial")
    assert "release_merge_conflict" in outcome.result
    assert git(release_repo, "rev-parse", "main") == before
    assert git(release_repo, "status", "--porcelain") == ""


async def test_dirty_worktree_blocks_the_release(tmp_path, release_repo):
    """未提交的變更不是這次週期的成果，不能替人決定要不要一起上板。"""
    (release_repo / "草稿.txt").write_text("寫到一半\n", encoding="utf-8")
    cfg = make_config(tmp_path, {"JSAI-Web": release_repo})
    hub = _RecordingHub()

    outcome = await executor(cfg, hub).execute(make_run([entry()]))

    assert (outcome.status, outcome.reason) == ("failed", "release_partial")
    assert "release_dirty" in outcome.result
    assert (release_repo / "草稿.txt").exists(), "別人的未提交變更不能被動到"


async def test_missing_stable_branch_fails(tmp_path, release_repo):
    # 分支名用 ASCII：白名單（Hub 與執行器同一條）只放行 `A-Za-z0-9._/-`，
    # 中文的名字在 Hub 就 422，到不了這裡
    cfg = make_config(tmp_path, {"JSAI-Web": release_repo})
    hub = _RecordingHub()

    outcome = await executor(cfg, hub).execute(
        make_run([entry(stable="no-such-branch")]))

    assert (outcome.status, outcome.reason) == ("failed", "release_partial")
    assert "release_stable_missing" in outcome.result


async def test_nothing_to_merge_is_skipped_not_failed(tmp_path,
                                                      release_repo):
    """來源分支已經整個在穩定分支裡 ⇒ 跳過，**不算失敗**。"""
    cfg = make_config(tmp_path, {"JSAI-Web": release_repo})
    hub = _RecordingHub()
    first = await executor(cfg, hub).execute(make_run([entry()]))
    assert first.status == "done", first.result

    second = await executor(cfg, _RecordingHub()).execute(
        make_run([entry()], run_id="r-rel-2"))

    assert (second.status, second.reason) == ("done", "released"), \
        second.result
    assert "release_nothing_to_merge" in second.result


async def test_one_repo_failing_makes_the_run_partial(tmp_path):
    """一個 repo 失敗不影響另一個，但整筆 run 是 `release_partial`。"""
    good, _ = make_repo(tmp_path, "JSAI-Web")
    bad, _ = make_repo(tmp_path, "JSAI-Api")
    (bad / "草稿.txt").write_text("寫到一半\n", encoding="utf-8")
    cfg = make_config(tmp_path, {"JSAI-Web": good, "JSAI-Api": bad})
    hub = _RecordingHub()

    outcome = await executor(cfg, hub).execute(
        make_run([entry("JSAI-Web"), entry("JSAI-Api")]))

    assert (outcome.status, outcome.reason) == ("failed", "release_partial")
    assert "release_dirty" in outcome.result
    # 失敗的那個擋住了，成功的那個照樣上板
    assert git(good, "rev-parse", "main") == git(good, "rev-parse",
                                                 "origin/main")
    assert git(bad, "rev-parse", "main") == git(bad, "rev-parse",
                                                "origin/main")
    assert git(good, "log", "-1", "--format=%s", "main").startswith("release:")


# ── 回報的 git 欄位（契約 C3）──────────────────────────────────

async def test_release_report_body_carries_git_fields(tmp_path,
                                                      release_repo):
    """release 的 `git`：repo 是逗號串、head 欄位留空（多 repo 擠不進一組 sha）。"""
    other, _ = make_repo(tmp_path, "JSAI-Api")
    cfg = make_config(tmp_path, {"JSAI-Web": release_repo,
                                 "JSAI-Api": other})
    hub = _RecordingHub()

    await executor(cfg, hub).execute(
        make_run([entry("JSAI-Web"), entry("JSAI-Api")]))

    status, kw = hub.final()
    assert status == "done"
    assert kw["git"] == {"repo": "JSAI-Api,JSAI-Web", "branch": "",
                         "head_before": "", "head_after": ""}
    # 先報 running 才報終局，不然 Hub 的狀態機會把 done 擋成 409
    assert [s for s, _ in hub.reports] == ["running", "done"]


async def test_push_report_body_carries_git_fields(tmp_path, release_repo):
    """`git` 欄位不是 release 專用：push 也要帶（形狀一致才讀得出差別）。"""
    git(release_repo, "checkout", "develop")
    (release_repo / "又一顆.txt").write_text("x", encoding="utf-8")
    git(release_repo, "add", "又一顆.txt")
    git(release_repo, "commit", "-m", "要推的那顆")
    sha = git(release_repo, "rev-parse", "HEAD")
    cfg = make_config(tmp_path, {"JSAI-Web": release_repo})
    hub = _RecordingHub()
    run = {"id": "r-push", "kind": "push", "project": "ai-website",
           "ref": "JSAI-Web", "brief": f"branch: develop\n{sha}",
           "room_id": "room-1"}

    outcome = await executor(cfg, hub).execute(run)

    assert outcome.status == "done", outcome.result
    _status, kw = hub.final()
    assert kw["git"]["repo"] == "JSAI-Web"
    assert kw["git"]["branch"] == "develop"
    assert kw["git"]["head_after"] == sha


# ── 儀表板（契約 C2）───────────────────────────────────────────

async def test_dashboard_carries_stable_branch_and_release_settings(
        tmp_path, release_repo):
    cfg = make_config(tmp_path, {"JSAI-Web": release_repo},
                      release={"merge_method": "squash",
                               "tag_message": "{objective}"})

    view = await dashboard.build(cfg, {}, "ok", None, "", [], 0,
                                 dashboard.RunnerRuntime())

    repo_view = view["repos"]["ai-website/JSAI-Web"]
    assert repo_view["stable_branch"] == "main"
    assert repo_view["stable_branch_exists"] is True
    assert view["workspaces"]["ai-website"]["release"] == {
        "merge_method": "squash",
        "merge_message": ReleaseConfig().merge_message,
        "tag_message": "{objective}"}


async def test_dashboard_marks_a_missing_stable_branch(tmp_path,
                                                       release_repo):
    """穩定分支兩邊都沒有時要標出來——App 才分得開「沒設」與「設了但不存在」。"""
    cfg = make_config(tmp_path, {"JSAI-Web": release_repo},
                      stable="沒有這條")

    view = await dashboard.build(cfg, {}, "ok", None, "", [], 0,
                                 dashboard.RunnerRuntime())

    repo_view = view["repos"]["ai-website/JSAI-Web"]
    assert repo_view["stable_branch"] == "沒有這條"
    assert repo_view["stable_branch_exists"] is False


# ── 設定（契約 C1）─────────────────────────────────────────────

def test_invalid_merge_method_falls_back_to_default(tmp_path, release_repo,
                                                    caplog):
    """不合法的合併方式退回預設**並留一句 log**：靜默沿用打錯的字串，
    症狀是上板用了不是人類選的那種合併。"""
    with caplog.at_level("WARNING"):
        cfg = make_config(tmp_path, {"JSAI-Web": release_repo},
                          release={"merge_method": "rebase"})

    release = cfg.workspaces["ai-website"].release
    assert release.merge_method == DEFAULT_MERGE_METHOD
    assert any("merge_method" in r.getMessage() for r in caplog.records)


def test_release_defaults_when_the_key_is_absent(tmp_path, release_repo):
    cfg = make_config(tmp_path, {"JSAI-Web": release_repo})

    assert cfg.workspaces["ai-website"].release == ReleaseConfig()
    assert cfg.workspaces["ai-website"].projects[
        "JSAI-Web"].stable_branch == "main"


def test_stable_branch_defaults_to_empty(tmp_path, release_repo):
    """沒設穩定分支 ＝ 不參與上板，**不是**「預設用 main」。"""
    raw = config_raw(tmp_path, release_repo)
    cfg = config_from_dict(raw, base_dir=tmp_path)

    assert cfg.workspaces["ai-website"].projects[
        "JSAI-Web"].stable_branch == ""


# ── git argv 的白名單（契約 C5）──────────────────────────────────

@pytest.mark.parametrize("source", ["--exec=touch pwned", "a..b"])
async def test_argument_looking_source_branch_is_blocked(tmp_path,
                                                         release_repo,
                                                         source):
    """來源分支會原樣進 git argv：`-` 開頭與含 `..` 的值要在組指令前就擋掉，
    而且**一個 git 指令都不能對那個 repo 跑過**。"""
    before = git(release_repo, "rev-parse", "main")
    cfg = make_config(tmp_path, {"JSAI-Web": release_repo})
    hub = _RecordingHub()

    outcome = await executor(cfg, hub).execute(
        make_run([entry(source=source)]))

    assert (outcome.status, outcome.reason) == ("failed", "release_partial")
    assert "release_ref_invalid" in outcome.result
    assert "source_branch" in outcome.result and source in outcome.result
    # repo 沒被動到：分支沒前進、工作樹還在原本那條上
    assert git(release_repo, "rev-parse", "main") == before
    assert git(release_repo, "rev-parse", "--abbrev-ref", "HEAD") == "develop"
    assert not (release_repo / "pwned").exists()


@pytest.mark.parametrize("tag", ["--exec=touch pwned", "v1..0"])
async def test_argument_looking_tag_is_blocked(tmp_path, release_repo, tag):
    """tag 同樣進 git argv（`git tag -a <tag>`／`git push origin <tag>`）。"""
    before = git(release_repo, "rev-parse", "main")
    cfg = make_config(tmp_path, {"JSAI-Web": release_repo})
    hub = _RecordingHub()

    outcome = await executor(cfg, hub).execute(make_run([entry()], tag=tag))

    assert (outcome.status, outcome.reason) == ("failed", "release_partial")
    assert "release_ref_invalid" in outcome.result
    assert "tag" in outcome.result and tag in outcome.result
    # tag 不合法就整個 repo 不上板：合併也不做
    assert git(release_repo, "rev-parse", "main") == before
    assert git(release_repo, "tag", "--list") == ""


async def test_nothing_to_merge_still_tags(tmp_path, release_repo):
    """沒有新 commit 時穩定分支的 HEAD 已經包含來源分支 ⇒ tag 照打照推。

    不打的話，這個週期在 origin 上沒有名字可以指回去。
    """
    cfg = make_config(tmp_path, {"JSAI-Web": release_repo},
                      release={"merge_method": "merge",
                               "tag_message": "{objective}"})
    first = await executor(cfg, _RecordingHub()).execute(make_run([entry()]))
    assert first.status == "done", first.result

    second = await executor(cfg, _RecordingHub()).execute(
        make_run([entry()], tag="v2.0.0", run_id="r-rel-2"))

    assert (second.status, second.reason) == ("done", "released"),         second.result
    assert "release_nothing_to_merge" in second.result
    assert "已打 tag v2.0.0" in second.result
    assert "refs/tags/v2.0.0" in git(release_repo, "ls-remote", "--tags",
                                     "origin"), "沒推上去等於只有本機看得到"


# ── 取消（審查 09/22）────────────────────────────────────────────

class _CancelAfter(asyncio.Event):
    """被問到第 ``after`` 次之後才說「已取消」。

    模擬的是人類在第一個 repo 上板完之後才按下取消——用真的 heartbeat 去設
    這個 event 會變成一條賭時序的測試，而它會在別人的機器上隨機轉綠。
    """

    def __init__(self, after: int) -> None:
        super().__init__()
        self.after = after
        self.asked = 0

    def is_set(self) -> bool:  # type: ignore[override]
        self.asked += 1
        return self.asked > self.after


async def test_cancel_stops_the_remaining_repos(tmp_path):
    """取消之後**剩下的 repo 一個都不能動**。

    多 repo 的上板是逐 repo 的 merge／push。迴圈不看取消的話，人類按下取消
    只停住了畫面，後面幾個照樣被推上 origin——而 push 收不回來。
    """
    first, _ = make_repo(tmp_path, "JSAI-Api")   # 依名稱排序，這個先做
    second, _ = make_repo(tmp_path, "JSAI-Web")
    second_before = git(second, "rev-parse", "main")
    cfg = make_config(tmp_path, {"JSAI-Api": first, "JSAI-Web": second})
    hub = _RecordingHub()
    cancel = _CancelAfter(1)

    outcome = await executor(cfg, hub).execute(
        make_run([entry("JSAI-Api"), entry("JSAI-Web")]), cancel)

    assert (outcome.status, outcome.reason) == ("cancelled",
                                                "cancel_requested"), \
        outcome.result
    # 前面那個照做完（已經推上去的不回滾）
    assert git(first, "rev-parse", "main") == git(first, "rev-parse",
                                                  "origin/main")
    assert git(first, "log", "-1", "--format=%s", "main").startswith("release:")
    # 後面那個**完全沒動**：本機與 origin 都停在原來那一顆
    assert git(second, "rev-parse", "main") == second_before
    assert git(second, "rev-parse", "origin/main") == second_before
    # 結果要講得出「動到哪裡為止」
    assert "JSAI-Api" in outcome.result and "收到取消" in outcome.result
    assert "JSAI-Web" in outcome.result and "完全沒動" in outcome.result
    assert "不會回滾" in outcome.result
    assert outcome.git["repo"] == "JSAI-Api", "沒動到的 repo 不該列進 git 欄位"
    assert [s for s, _ in hub.reports] == ["running", "cancelled"]


async def test_cancel_before_the_first_repo_touches_nothing(tmp_path):
    """取消在第一個 repo 之前就到了 ⇒ 一個 git 寫入動作都不做。"""
    repo, _ = make_repo(tmp_path, "JSAI-Web")
    before = git(repo, "rev-parse", "main")
    cfg = make_config(tmp_path, {"JSAI-Web": repo})
    hub = _RecordingHub()
    cancel = asyncio.Event()
    cancel.set()

    outcome = await executor(cfg, hub).execute(make_run([entry()]), cancel)

    assert outcome.status == "cancelled", outcome.result
    assert git(repo, "rev-parse", "main") == before
    assert git(repo, "rev-parse", "--abbrev-ref", "HEAD") == "develop"


# ── 來源分支：本機 vs origin（審查 09/22）──────────────────────

async def test_source_behind_origin_merges_the_remote_tip(tmp_path,
                                                          release_repo):
    """本機的來源分支落後 origin ⇒ 要合 ``origin/<source>`` 的那一顆。

    無條件用本機 tip 的話，會併進一份**舊的**來源然後回報成功——人類看到
    綠燈，而遠端上那幾顆根本沒上板。
    """
    (release_repo / "遠端那顆.txt").write_text("後來推上去的\n",
                                               encoding="utf-8")
    git(release_repo, "add", "遠端那顆.txt")
    git(release_repo, "commit", "-m", "只在 origin 上的那顆")
    git(release_repo, "push", "origin", "develop")
    # 本機退回去：local develop 是 origin/develop 的祖先
    git(release_repo, "reset", "--hard", "HEAD~1")
    cfg = make_config(tmp_path, {"JSAI-Web": release_repo},
                      release={"merge_method": "merge",
                               "merge_message": "release: 併入 {source}"})
    hub = _RecordingHub()

    outcome = await executor(cfg, hub).execute(make_run([entry()]))

    assert (outcome.status, outcome.reason) == ("done", "released"), \
        outcome.result
    subjects = git(release_repo, "log", "main", "--format=%s")
    assert "只在 origin 上的那顆" in subjects, \
        "合的是本機那顆舊的 tip，origin 上的成果沒上板"
    assert git(release_repo, "rev-parse", "main") == \
        git(release_repo, "rev-parse", "origin/main")


async def test_source_diverged_from_origin_is_refused(tmp_path,
                                                      release_repo):
    """本機與 origin 分岔 ⇒ `release_source_diverged`，兩邊的 sha 都要寫出來。

    挑哪一邊都會漏掉另一邊的成果，而漏掉的那幾顆在報告上與「成功上板」長得
    一模一樣。
    """
    (release_repo / "遠端那顆.txt").write_text("遠端\n", encoding="utf-8")
    git(release_repo, "add", "遠端那顆.txt")
    git(release_repo, "commit", "-m", "只在 origin 上的那顆")
    git(release_repo, "push", "origin", "develop")
    git(release_repo, "reset", "--hard", "HEAD~1")
    (release_repo / "本機那顆.txt").write_text("本機\n", encoding="utf-8")
    git(release_repo, "add", "本機那顆.txt")
    git(release_repo, "commit", "-m", "只在本機的那顆")
    local = git(release_repo, "rev-parse", "develop")
    remote = git(release_repo, "rev-parse", "origin/develop")
    before = git(release_repo, "rev-parse", "main")
    cfg = make_config(tmp_path, {"JSAI-Web": release_repo})
    hub = _RecordingHub()

    outcome = await executor(cfg, hub).execute(make_run([entry()]))

    assert (outcome.status, outcome.reason) == ("failed", "release_partial")
    assert "release_source_diverged" in outcome.result
    assert local[:8] in outcome.result and remote[:8] in outcome.result
    # 一顆都不能併進去
    assert git(release_repo, "rev-parse", "main") == before
    assert git(release_repo, "rev-parse", "origin/main") == before
    assert git(release_repo, "rev-parse", "--abbrev-ref", "HEAD") == "develop"
