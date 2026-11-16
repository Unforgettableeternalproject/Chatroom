"""執行器的 macOS／Linux 支援：進程群組、憑證 helper、路徑、登入提示。

POSIX 專屬的行為在 Windows 上用 monkeypatch 驗命令組裝；真的殺進程樹那一條
只在 POSIX 上跑（`skipif`），Windows 上的證據是 WSL／Docker 的實測。
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import pytest

from chatroom_runner import config as config_mod
from chatroom_runner import procs
from chatroom_runner import run as run_mod
from chatroom_runner.loop import login_hint_for
from chatroom_runner.run import RunExecutor
from chatroom_runner.usage import UsageStore

from ._fixtures import make_config


def _executor(cfg):
    return RunExecutor(cfg, None, usage_store=UsageStore(cfg.usage_db))


# ── 進程群組：spawn 與 kill_tree ──────────────────────────────

def test_new_session_kwargs_on_posix(monkeypatch):
    monkeypatch.setattr(sys, "platform", "linux")
    assert procs.new_session_kwargs() == {"start_new_session": True}
    monkeypatch.setattr(sys, "platform", "darwin")
    assert procs.new_session_kwargs() == {"start_new_session": True}


def test_new_session_kwargs_on_windows(monkeypatch):
    monkeypatch.setattr(sys, "platform", "win32")
    assert procs.new_session_kwargs() == {}


def _fake_posix(monkeypatch, *, pgid: int):
    """讓 `kill_tree` 走 POSIX 分支，並記錄它打了哪些訊號。"""
    calls: list[tuple] = []
    monkeypatch.setattr(run_mod.os, "name", "posix")
    monkeypatch.setattr(run_mod.os, "getpgid", lambda pid: pgid, raising=False)
    monkeypatch.setattr(run_mod.os, "killpg",
                        lambda g, s: calls.append(("killpg", g, s)),
                        raising=False)
    monkeypatch.setattr(run_mod.os, "kill",
                        lambda p, s: calls.append(("kill", p, s)))
    monkeypatch.setattr(run_mod.signal, "SIGKILL", 9, raising=False)
    return calls


def test_kill_tree_kills_the_whole_process_group(monkeypatch):
    """組長（pgid == pid）：整個群組 SIGKILL，不是只殺父進程。"""
    calls = _fake_posix(monkeypatch, pgid=4321)
    run_mod.kill_tree(4321)
    assert calls == [("killpg", 4321, 9)]


def test_kill_tree_never_kills_the_runners_own_group(monkeypatch):
    """不是組長（沒走 new_session 起的）：pgid 是執行器自己的群組。

    這裡打 killpg 會連執行器一起殺掉，所以只能退回單殺那個進程。
    """
    calls = _fake_posix(monkeypatch, pgid=1111)
    run_mod.kill_tree(4321)
    assert calls == [("kill", 4321, 9)]


def test_kill_tree_ignores_already_gone_process(monkeypatch):
    calls = _fake_posix(monkeypatch, pgid=4321)

    def gone(pid):
        raise ProcessLookupError

    monkeypatch.setattr(run_mod.os, "getpgid", gone, raising=False)
    run_mod.kill_tree(4321)
    assert calls == []


@pytest.mark.skipif(sys.platform == "win32", reason="需要 POSIX 的進程群組")
def test_kill_tree_really_kills_grandchildren(tmp_path):
    """實測：子孫在殺完之後確實不在了（原本只殺父進程，孫進程會殘留）。"""
    pidfile = tmp_path / "grandchild.pid"
    # sh 起一個背景 sleep（孫進程）並記下它的 pid，自己也 sleep 著
    proc = subprocess.Popen(
        ["sh", "-c", f"sleep 300 & echo $! > '{pidfile}'; sleep 300"],
        **procs.new_session_kwargs())
    try:
        deadline = time.monotonic() + 10
        while not pidfile.exists() or not pidfile.read_text().strip():
            assert time.monotonic() < deadline, "孫進程沒有起來"
            time.sleep(0.05)
        grandchild = int(pidfile.read_text().strip())
        os.kill(grandchild, 0)  # 殺之前確實活著

        run_mod.kill_tree(proc.pid)
        proc.wait(timeout=10)

        deadline = time.monotonic() + 10
        while True:
            try:
                os.kill(grandchild, 0)
            except ProcessLookupError:
                break
            assert time.monotonic() < deadline, "孫進程殺完還活著"
            time.sleep(0.05)
    finally:
        if proc.poll() is None:
            proc.kill()
        if pidfile.exists() and pidfile.read_text().strip():
            try:
                os.kill(int(pidfile.read_text().strip()), signal.SIGKILL)
            except (ProcessLookupError, AttributeError):
                pass


# ── 推送憑證 helper ───────────────────────────────────────────

@pytest.mark.parametrize("platform,expected", [
    ("win32", "manager"),
    ("darwin", "osxkeychain"),
    ("linux", ""),       # 沿用使用者既有的 git 設定
])
def test_push_helper_default_per_platform(tmp_path, work_repo, monkeypatch,
                                          platform, expected):
    monkeypatch.setattr(sys, "platform", platform)
    cfg = make_config(tmp_path, work_repo)
    assert cfg.push_credential_helper_name == expected


def test_push_helper_is_configurable(tmp_path, work_repo, monkeypatch):
    monkeypatch.setattr(sys, "platform", "linux")
    cfg = make_config(tmp_path, work_repo, push_credential_helper="store")
    assert cfg.push_credential_helper_name == "store"
    assert _executor(cfg)._push_credential_args() == [
        "-c", "credential.helper=store"]


def test_push_args_do_not_override_when_inheriting(tmp_path, work_repo,
                                                   monkeypatch):
    """Linux 預設：什麼都不加，使用者的 credential.helper 照常生效。"""
    monkeypatch.setattr(sys, "platform", "linux")
    cfg = make_config(tmp_path, work_repo)
    assert _executor(cfg)._push_credential_args() == []


def test_release_fix_env_keeps_user_helpers_when_inheriting(
        tmp_path, work_repo, monkeypatch):
    """release_fix 在 Linux 預設不能把 helper 清單清空，否則推送沒有憑證。"""
    monkeypatch.setattr(sys, "platform", "linux")
    cfg = make_config(tmp_path, work_repo)
    env = _executor(cfg)._child_env(
        {"id": "r-1", "kind": run_mod.RELEASE_FIX_KIND}, tmp_path)
    keys = [v for k, v in env.items() if k.startswith("GIT_CONFIG_KEY_")]
    assert "credential.helper" not in keys
    assert env["GIT_TERMINAL_PROMPT"] == "0"


def test_ordinary_run_still_clears_helpers_on_linux(tmp_path, work_repo,
                                                    monkeypatch):
    """一般 run 一律清空 helper：隔離的前提不能因為平台預設而鬆掉。"""
    monkeypatch.setattr(sys, "platform", "linux")
    cfg = make_config(tmp_path, work_repo)
    env = _executor(cfg)._child_env({"id": "r-2"}, tmp_path)
    assert env["GIT_CONFIG_KEY_0"] == "credential.helper"
    assert env["GIT_CONFIG_VALUE_0"] == ""


def test_release_fix_env_uses_configured_helper(tmp_path, work_repo,
                                                monkeypatch):
    monkeypatch.setattr(sys, "platform", "darwin")
    cfg = make_config(tmp_path, work_repo)
    env = _executor(cfg)._child_env(
        {"id": "r-3", "kind": run_mod.RELEASE_FIX_KIND}, tmp_path)
    assert env["GIT_CONFIG_KEY_0"] == "credential.helper"
    assert env["GIT_CONFIG_VALUE_0"] == "osxkeychain"


def test_ssh_keygen_default_is_not_a_windows_path(tmp_path, work_repo):
    cfg = make_config(tmp_path, work_repo)
    assert cfg.ssh_keygen_program == "ssh-keygen"


# ── 路徑與提示 ────────────────────────────────────────────────

@pytest.mark.parametrize("platform,sub", [
    ("darwin", Path("Library") / "Application Support" / "UEP" / "Chatroom"),
    ("linux", Path(".local") / "share" / "uep" / "chatroom"),
])
def test_default_state_dir_per_platform(monkeypatch, tmp_path, platform, sub):
    monkeypatch.setattr(sys, "platform", platform)
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("USERPROFILE", str(tmp_path))
    monkeypatch.delenv("XDG_DATA_HOME", raising=False)
    # 不能被 Windows 開發機的 LOCALAPPDATA 帶偏
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path / "ignored"))
    assert config_mod.default_state_dir() == tmp_path / sub / "runner"


def test_default_state_dir_honours_xdg_data_home(monkeypatch, tmp_path):
    monkeypatch.setattr(sys, "platform", "linux")
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "xdg"))
    assert config_mod.default_state_dir() == (
        tmp_path / "xdg" / "uep" / "chatroom" / "runner")


def test_default_state_dir_ignores_relative_xdg(monkeypatch, tmp_path):
    monkeypatch.setattr(sys, "platform", "linux")
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("USERPROFILE", str(tmp_path))
    monkeypatch.setenv("XDG_DATA_HOME", "relative/dir")
    assert config_mod.default_state_dir() == (
        tmp_path / ".local" / "share" / "uep" / "chatroom" / "runner")


def test_login_hint_matches_the_shell():
    cfg_dir = Path("/x/claude-config")
    win = login_hint_for("win32", cfg_dir)
    assert "$env:CLAUDE_CONFIG_DIR" in win and "claude auth login" in win
    for plat in ("linux", "darwin"):
        posix = login_hint_for(plat, cfg_dir)
        assert posix.startswith("登入：export CLAUDE_CONFIG_DIR=")
        assert "$env:" not in posix and "claude auth login" in posix


def test_example_config_has_neutral_paths():
    example = (Path(__file__).resolve().parents[1]
               / "config.example.json").read_text(encoding="utf-8")
    assert "C:/path" not in example.split('"workspaces"', 1)[1]
