"""安裝前的 agent 能力檢查。

裝得起來但通知永遠不來，是這套系統最糟的失效方式：指派送出了、Hub 收下了，
只是沒有人被叫醒，而且沒有任何錯誤訊息。所以在動任何檔案之前先問清楚。

⚠️ 這裡測的是 install-kit/install.py，它不是 bridge 套件的一部分（安裝器
自己不會被安裝）。用檔案路徑載入，因為 repo 裡沒有它的 import 路徑。
"""

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

_INSTALL = (Path(__file__).resolve().parents[2] / "install-kit" / "install.py")


def _load():
    spec = importlib.util.spec_from_file_location("chatroom_install", _INSTALL)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


inst = _load()


def test_version_parsing_takes_the_first_triple():
    """`2.1.238 (Claude Code)` / `codex-cli 0.150.1` 都要抓得出來。"""
    class Done:
        returncode = 0

        def __init__(self, out):
            self.stdout = out
            self.stderr = ""

    def fake(cmd, **kw):
        return Done("2.1.238 (Claude Code)\n")

    orig = subprocess.run
    subprocess.run = fake
    try:
        assert inst._cli_version("whatever") == (2, 1, 238)
    finally:
        subprocess.run = orig


def test_codex_without_queue_stops_the_install(monkeypatch, capsys):
    """Codex 少了 queue 是硬性阻擋——App 的指派就是靠它送進 Codex session。"""
    monkeypatch.setattr(inst.shutil, "which", lambda name: f"/fake/{name}")

    class Failed:
        returncode = 1
        stdout = ""
        stderr = "unrecognized subcommand"

    monkeypatch.setattr(inst.subprocess, "run", lambda cmd, **kw: Failed())
    with pytest.raises(SystemExit):
        inst.check_agent_capabilities({"codex"})
    out = capsys.readouterr().out
    assert "queue" in out
    # 要講清楚後果，不然使用者只會覺得安裝器在找麻煩
    assert "指派" in out
    # 也要給出路，不然他只能卡在這裡
    assert "0.149.0" in out or "升級" in out


def test_old_claude_only_warns(monkeypatch, capsys):
    """Claude Code 的版本門檻只警告不擋。

    Monitor 是模型端的工具，CLI 問不到，只能比版本號——而版本號這條路已經
    被實測打臉一次：公開資料說 Monitor 從 2.1.242 起才有，2.1.238 的機器上
    它卻運作正常。擋掉一台其實能用的機器，比放行一台不能用的更糟。
    """
    monkeypatch.setattr(inst.shutil, "which",
                        lambda name: "/fake/claude" if name == "claude" else None)
    monkeypatch.setattr(inst, "_cli_version", lambda exe: (2, 0, 1))
    inst.check_agent_capabilities({"claude"})  # 不該拋 SystemExit
    out = capsys.readouterr().out
    assert "2.0.1" in out
    assert "watcher" in out


def test_this_machine_passes_silently():
    """開發機自己要能安靜通過——不然這個檢查第一天就會被當成雜訊忽略。"""
    if not inst.shutil.which("claude") and not inst.shutil.which("codex"):
        pytest.skip("這台沒有裝 claude/codex")
    inst.check_agent_capabilities({"claude", "codex"})


def test_version_lookup_uses_the_resolved_path_not_the_bare_name():
    """必須用 which 解析出的完整路徑去問版本。

    同一台機器上可能裝了不只一份：實測用名稱叫到的是 2.1.92，用完整路徑
    叫到的是 2.1.238。檢查錯的那份，結論當然也是錯的。
    """
    src = _INSTALL.read_text(encoding="utf-8")
    assert '_cli_version("claude")' not in src
    assert '_cli_version("codex")' not in src
    assert "_cli_version(claude_exe)" in src
    assert "_cli_version(exe)" in src


def test_check_runs_before_anything_is_written():
    """檢查要排在動檔案之前——裝到一半才失敗，殘骸要使用者自己收拾。"""
    src = _INSTALL.read_text(encoding="utf-8")
    body = src[src.index("def main()"):]
    assert body.index("check_agent_capabilities(") < body.index("install_bridge()")


if sys.platform != "win32":  # pragma: no cover - 這個專案只在 Windows 上跑
    pass
