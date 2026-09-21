"""專案必守 skill 的四端（設定→參數→契約→守衛）。

這一份守的是「四端不一致」那種安靜失敗：設定放行了但 `--add-dir` 沒加、
契約叫了一個不存在的 skill、或守衛把 skill 要求的產出目錄擋掉——三種都會讓
遠端看到一筆「跑完了、但沒照規則做」的 run，而沒有任何錯誤訊息。
"""

from __future__ import annotations

import json

import pytest

from chatroom_runner import prompts
from chatroom_runner.config import ConfigError, config_from_dict
from chatroom_runner.guard import GuardContext, check_path, check_tool
from chatroom_runner.run import RunExecutor, allowed_tools
from chatroom_runner.usage import UsageStore

from ._fixtures import make_config

SKILL_NAME = "jira-ticket-workflow"


class _NullHub:
    async def report(self, run_id, payload):
        return {}


def _skill_dir(tmp_path, name: str = SKILL_NAME):
    """造一個 `<dir>/.claude/skills/<name>/SKILL.md`。"""
    root = tmp_path / "AI-Website"
    manifest = root / ".claude" / "skills" / name / "SKILL.md"
    manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text("# skill", encoding="utf-8")
    return root


def _with_skills(tmp_path, work_repo, **project_extra):
    root = _skill_dir(tmp_path)
    cfg = make_config(tmp_path, work_repo)
    raw_project = {
        "default_project": "JSAI-Web",
        "skill_dirs": [str(root)],
        "skills": {"ticket": [SKILL_NAME]},
        "projects": {"JSAI-Web": {
            "path": str(work_repo),
            "allowed_branches": ["jsai_dev", "feature/*"],
            "push_branches": ["jsai_dev"]}},
    }
    raw_project.update(project_extra)
    return make_config(tmp_path, work_repo,
                       workspaces={"ai-website": raw_project}), root


# ---------- 設定 ----------

def test_config_reads_skill_slots(tmp_path, work_repo):
    cfg, root = _with_skills(
        tmp_path, work_repo,
        extra_write_dirs=[str(tmp_path / "AI-Website" / "global_docs")])
    project = cfg.workspace("ai-website")
    assert project.skill_dirs == [root]
    assert project.skills_for("ticket") == [SKILL_NAME]
    assert project.skills_for("investigate") == []
    assert project.extra_write_dirs == [
        tmp_path / "AI-Website" / "global_docs"]


def test_config_rejects_a_skill_with_no_manifest(tmp_path, work_repo):
    """缺 SKILL.md 就是設定錯誤。

    只留 warning 的話，契約照樣會叫 run 去跑一個載不進來的 skill，
    而 headless 那邊沒有人會發現它其實是照自己的想法做完的。
    """
    root = _skill_dir(tmp_path)
    with pytest.raises(ConfigError) as exc:
        config_from_dict({"workspaces": {"ai-website": {
            "skill_dirs": [str(root)],
            "skills": {"ticket": ["no-such-skill"]},
            "projects": {"JSAI-Web": {"path": str(work_repo)}}}}})
    assert "no-such-skill" in str(exc.value)


def test_selfcheck_flags_a_missing_skill_dir(tmp_path, work_repo):
    cfg = make_config(tmp_path, work_repo, workspaces={"ai-website": {
        "skill_dirs": [str(tmp_path / "not-here")],
        "projects": {"JSAI-Web": {"path": str(work_repo),
                                  "allowed_branches": ["jsai_dev"]}}}})
    from chatroom_runner.loop import RunnerLoop
    loop = RunnerLoop(cfg, _NullHub())
    problems = loop._check_skill_dirs()
    assert problems and "not-here" in problems[0]


def test_primary_skill_is_validated_like_the_kind_skills(tmp_path,
                                                         work_repo):
    """優先載入的 skill 缺 SKILL.md 一樣是設定錯誤，不是 warning。"""
    root = _skill_dir(tmp_path)
    with pytest.raises(ConfigError) as exc:
        config_from_dict({"workspaces": {"ai-website": {
            "skill_dirs": [str(root)],
            "primary_skill": "no-such-skill",
            "projects": {"JSAI-Web": {"path": str(work_repo)}}}}})
    assert "no-such-skill" in str(exc.value)

    cfg, _root = _with_skills(tmp_path, work_repo, primary_skill=SKILL_NAME)
    ws = cfg.workspace("ai-website")
    assert ws.primary_skill == SKILL_NAME
    # 不分 kind 都要在，而且不跟 kind 的必守清單重複
    assert ws.all_skills_for("ticket") == [SKILL_NAME]
    assert ws.all_skills_for("investigate") == [SKILL_NAME]
    assert cfg.workspace("ai-website").skills_for("investigate") == []


# ---------- 參數 ----------

def test_allowed_tools_preauthorizes_the_skill():
    tools = allowed_tools("ticket", ["mcp__x__*"], [SKILL_NAME])
    assert f"Skill({SKILL_NAME})" in tools
    # 沒指定 skill 的 kind 不該多出一個授權
    assert not any(t.startswith("Skill(")
                   for t in allowed_tools("investigate", [], []))


def test_argv_adds_skill_dirs_and_skill_tool(tmp_path, work_repo):
    cfg, root = _with_skills(tmp_path, work_repo)
    ex = RunExecutor(cfg, _NullHub(), usage_store=UsageStore(cfg.usage_db))
    project = cfg.workspace("ai-website")
    argv = ex._argv("p", "c", project, tmp_path, "", "ticket")
    assert argv[argv.index("--add-dir") + 1] == str(root)
    tools = argv[argv.index("--allowedTools") + 1].split(",")
    assert f"Skill({SKILL_NAME})" in tools
    # kind 沒設 skill 時只加目錄，不加授權
    other = ex._argv("p", "c", project, tmp_path, "", "investigate")
    assert "--add-dir" in other
    assert not any(t.startswith("Skill(")
                   for t in other[other.index("--allowedTools") + 1].split(","))


def test_primary_skill_reaches_allowed_tools_for_every_kind(tmp_path,
                                                            work_repo):
    """沒進 `--allowedTools` 的話，契約叫它就卡在權限提示。"""
    _skill_dir(tmp_path, "always-on")
    cfg, _root = _with_skills(tmp_path, work_repo,
                              primary_skill="always-on")
    ex = RunExecutor(cfg, _NullHub(), usage_store=UsageStore(cfg.usage_db))
    ws = cfg.workspace("ai-website")
    for kind in ("ticket", "investigate"):
        argv = ex._argv("p", "c", ws, tmp_path, "", kind)
        tools = argv[argv.index("--allowedTools") + 1].split(",")
        assert "Skill(always-on)" in tools, kind


# ---------- 契約 ----------

def test_contract_states_the_overrides_when_a_skill_is_required():
    block = prompts.skills_block([SKILL_NAME])
    contract = prompts.build_contract({"run_id": "r", "kind": "ticket",
                                       "project": "p", "room_id": "room",
                                       "ref": "t", "cwd": "C:/x",
                                       "allowed_branches": "jsai_dev",
                                       "skills_block": block})
    assert f"/{SKILL_NAME}" in contract
    # 契約優先的那幾條：少一條，run 就會停在一個沒有人能回答的地方
    for must in ("Plan Mode", "不 push", "transition", "global_docs"):
        assert must in contract


def test_contract_has_no_leftovers_without_skills():
    contract = prompts.build_contract({"run_id": "r", "kind": "ticket",
                                       "project": "p", "room_id": "room",
                                       "ref": "t", "cwd": "C:/x",
                                       "allowed_branches": "jsai_dev",
                                       "skills_block": prompts.skills_block([])})
    assert "{{skills_block}}" not in contract
    assert "必須遵守的 skill" not in contract
    assert "\n\n\n" not in contract


def test_contract_tells_the_run_to_load_the_primary_skill_first():
    block = prompts.primary_skill_block("always-on")
    contract = prompts.build_contract({"run_id": "r", "kind": "investigate",
                                       "project": "p", "room_id": "room",
                                       "ref": "t", "cwd": "C:/x",
                                       "allowed_branches": "jsai_dev",
                                       "primary_skill_block": block})
    assert "/always-on" in contract
    assert "一開始就啟動它" in contract
    # 沒設時契約不留下半句話
    plain = prompts.build_contract({"run_id": "r", "kind": "investigate",
                                    "project": "p", "room_id": "room",
                                    "ref": "t", "cwd": "C:/x",
                                    "allowed_branches": "jsai_dev"})
    assert "{{primary_skill_block}}" not in plain
    assert "開工先載入的 skill" not in plain
    assert "\n\n\n" not in plain


# ---------- 守衛 ----------

def test_guard_allows_extra_write_dirs_but_still_blocks_env(tmp_path):
    cwd = tmp_path / "repo"
    cwd.mkdir()
    extra = tmp_path / "global_docs" / "analysis"
    extra.mkdir(parents=True)
    ctx = GuardContext(cwd=cwd, extra_write_dirs=[extra])
    assert check_path(str(extra / "JSAI-1.md"), ctx).allowed
    assert check_tool("Write", {"file_path": str(extra / "JSAI-1.md")},
                      ctx).allowed
    # 放行的是位置，不是「什麼檔都行」
    assert not check_path(str(extra / ".env"), ctx).allowed
    # 清單以外的 cwd 外路徑照擋
    outside = tmp_path / "elsewhere" / "x.md"
    assert not check_path(str(outside), ctx).allowed
    # 序列化要帶著它，不然 hook 端看不到這個放行
    assert GuardContext.from_dict(ctx.to_dict()).extra_write_dirs == [extra]


def test_run_files_carry_extra_write_dirs(tmp_path, work_repo):
    cfg, _root = _with_skills(
        tmp_path, work_repo,
        extra_write_dirs=[str(tmp_path / "AI-Website" / "global_docs")])
    ex = RunExecutor(cfg, _NullHub(), usage_store=UsageStore(cfg.usage_db))
    project = cfg.workspace("ai-website")
    run_dir = cfg.runs_dir / "r-skill"
    run_dir.mkdir(parents=True)
    ex._write_run_files(run_dir, {"id": "r-skill"},
                        project.projects["JSAI-Web"], project)
    guard = json.loads((run_dir / "guard.json").read_text("utf-8"))
    assert guard["extra_write_dirs"] == [
        str(tmp_path / "AI-Website" / "global_docs")]
