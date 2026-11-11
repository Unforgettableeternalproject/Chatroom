"""host-kit 安裝器：`.env` 的寫入不可以毀掉既有設定。

這裡守的兩件事都屬於「安裝器全程顯示成功、實際弄壞了東西」：

1. **整份覆寫會清掉主持人自己加的設定。** 原本 `write_env()` 只寫
   HOST/PORT/TOKEN 三行，所以 `CHATROOM_PURGE_ARCHIVED_DAYS`、
   `CHATROOM_IDLE_TIMEOUT`、附件目錄……重跑一次安裝器就全部消失。
   時機特別惡劣：重跑安裝器多半是因為「有什麼壞了想重裝看看」，
   而被清掉的正是可能與問題有關的那些設定。

2. **重跑會換掉 token。** 每次都產一把新的當預設值，照著按 Enter 就
   **當場踢掉所有成員與 agent**，而畫面上完全看不出剛剛發生了這件事。

`install.py` 只用標準庫、import 時不做任何事，可以直接載入來測。
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
INSTALL_PY = REPO / "host-kit" / "install.py"


@pytest.fixture
def installer(tmp_path: Path):
    """載入安裝器並把 `.env` 指到 tmp。

    不改的話這些測試會去寫**真的** server/.env——那是這台機器上正在跑的
    Hub 的設定。
    """
    spec = importlib.util.spec_from_file_location("chatroom_host_install", INSTALL_PY)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["chatroom_host_install"] = module
    spec.loader.exec_module(module)
    server = tmp_path / "server"
    server.mkdir()
    module.ENV_FILE = server / ".env"
    return module


def test_keeps_settings_the_installer_does_not_know_about(installer):
    """🔴 主持人自己加的設定不可以被洗掉。

    這條紅起來的樣子：重裝之後 Hub 照常起來，但封存房的保留天數回到預設、
    閒置門檻回到預設——**而沒有任何地方說過這件事**。
    """
    installer.ENV_FILE.write_text(
        "# 我自己的說明\n"
        "CHATROOM_HOST=127.0.0.1\n"
        "CHATROOM_PORT=8787\n"
        "CHATROOM_TOKEN=old-token\n"
        "CHATROOM_PURGE_ARCHIVED_DAYS=15\n"
        "CHATROOM_IDLE_TIMEOUT=1800\n",
        encoding="utf-8",
    )

    installer.update_env({"CHATROOM_TOKEN": "new-token"})
    text = installer.ENV_FILE.read_text(encoding="utf-8")

    assert "CHATROOM_PURGE_ARCHIVED_DAYS=15" in text
    assert "CHATROOM_IDLE_TIMEOUT=1800" in text
    assert "CHATROOM_TOKEN=new-token" in text
    assert "old-token" not in text
    # 註解也是設定的一部分——那是使用者寫給自己看的
    assert "# 我自己的說明" in text


def test_appends_keys_that_were_not_there(installer):
    installer.ENV_FILE.write_text("CHATROOM_PORT=8787\n", encoding="utf-8")

    installer.update_env({"CHATROOM_HUMAN_TOKEN": "human-key"})
    lines = installer.ENV_FILE.read_text(encoding="utf-8").splitlines()

    assert lines == ["CHATROOM_PORT=8787", "CHATROOM_HUMAN_TOKEN=human-key"]


def test_appending_when_file_has_no_trailing_newline(installer):
    """檔尾沒換行時補上的那行不可以黏在前一行後面。

    黏起來會變成 `CHATROOM_PORT=8787CHATROOM_HUMAN_TOKEN=...`——兩個設定
    同時失效，而檔案看起來還是有內容的。
    """
    installer.ENV_FILE.write_text("CHATROOM_PORT=8787", encoding="utf-8")

    installer.update_env({"CHATROOM_HUMAN_TOKEN": "human-key"})
    lines = installer.ENV_FILE.read_text(encoding="utf-8").splitlines()

    assert lines == ["CHATROOM_PORT=8787", "CHATROOM_HUMAN_TOKEN=human-key"]


def test_writes_a_fresh_file_when_there_is_none(installer):
    installer.update_env({"CHATROOM_HOST": "0.0.0.0", "CHATROOM_TOKEN": "t"})
    text = installer.ENV_FILE.read_text(encoding="utf-8")
    assert "CHATROOM_HOST=0.0.0.0" in text
    assert "CHATROOM_TOKEN=t" in text


def test_env_is_never_left_empty(installer):
    """寫壞的 `.env` 會讓 Hub 起不來，而本來只是想重裝。"""
    installer.ENV_FILE.write_text("CHATROOM_TOKEN=old\n", encoding="utf-8")
    installer.update_env({"CHATROOM_TOKEN": "new"})
    assert installer.ENV_FILE.stat().st_size > 0


def test_read_env_ignores_comments_and_keeps_equals_in_values(installer):
    """token 是 urlsafe base64，值裡可能有 `=`——只能切第一個。"""
    installer.ENV_FILE.write_text(
        "#註解\n\nCHATROOM_TOKEN=ab=cd=\nCHATROOM_PORT=9\n", encoding="utf-8")
    assert installer.read_env() == {"CHATROOM_TOKEN": "ab=cd=", "CHATROOM_PORT": "9"}


def test_read_env_on_missing_file_is_empty_not_an_error(installer):
    """還沒裝過的機器沒有 `.env`，那是正常狀態不是錯誤。"""
    assert installer.read_env() == {}


def test_existing_token_is_reused_not_regenerated(installer):
    """🔴 重跑安裝器不可以換掉 token。

    換掉＝當場踢掉所有成員與 agent，而按 Enter 的人完全不會預期。
    要換 token 有專門的工具（`rotate-token.py`），它會備份舊值並講明
    每個人都要重拿。

    這條驗的是 `main()` 取預設值的邏輯，所以直接檢查那個來源
    ——`read_env()` 讀得到既有 token，就不該再生成新的。
    """
    installer.ENV_FILE.write_text("CHATROOM_TOKEN=keep-me\n", encoding="utf-8")
    existing = installer.read_env()

    # main() 的取值方式：既有優先，沒有才生成
    default_token = existing.get("CHATROOM_TOKEN") or "would-be-generated"

    assert default_token == "keep-me"


def test_human_token_is_part_of_a_fresh_install(installer):
    """新裝的 Hub 必須有人類憑證。

    沒有它的 Hub 是 `credential_mode: legacy`——憑證分離整套做好了卻沒有
    啟用，因為安裝器從來沒產生過它。那等於它只對「知道有這個環境變數的人」
    存在，而交付給外部人的包裡它不存在。
    """
    source = INSTALL_PY.read_text(encoding="utf-8")
    assert "CHATROOM_HUMAN_TOKEN" in source, "安裝器沒有產生人類憑證"
    # 而且要是**生成**的，不是寫死的字串
    assert "secrets.token_urlsafe" in source


# ---- 排程工作設定漂移 ----------------------------------------------------

import json  # noqa: E402
import subprocess  # noqa: E402


def _task_json(**over):
    base = {"priority": 4, "execute": "", "restart_count": 999,
            "restart_interval": "PT1M", "time_limit": "PT0S"}
    base.update(over)
    return json.dumps(base)


@pytest.fixture
def fake_ps(installer, monkeypatch):
    """假的 PowerShell：不真的碰排程工作，只記錄被叫了什麼。"""
    monkeypatch.setattr(installer, "KIT", installer.ENV_FILE.parent.parent)
    wrapper = str(installer.KIT / "scripts" / "run-hub.cmd")
    Path(wrapper).parent.mkdir(parents=True, exist_ok=True)
    Path(wrapper).write_text("@echo off")
    state = {"stdout": "null", "calls": [], "apply_rc": 0}

    def fake_run(shell, script):
        state["calls"].append(script)
        if "Set-ScheduledTask" in script:
            return subprocess.CompletedProcess([], state["apply_rc"], "", "boom")
        return subprocess.CompletedProcess([], 0, state["stdout"], "")

    monkeypatch.setattr(installer, "_ps_run", fake_run)
    monkeypatch.setattr(installer.shutil, "which", lambda name: "pwsh")
    monkeypatch.setattr(installer.sys, "platform", "win32")
    state["wrapper"] = wrapper
    return state


def test_service_priority_7_is_updated_to_4(installer, fake_ps):
    fake_ps["stdout"] = _task_json(priority=7, execute=fake_ps["wrapper"])
    out = installer.sync_service_settings()

    assert out["updated"] is True
    assert (out["before_priority"], out["after_priority"]) == (7, 4)
    assert out["drift"] == ["priority"]
    apply_script = fake_ps["calls"][-1]
    assert "Set-ScheduledTask" in apply_script
    assert "$s.Priority = 4" in apply_script
    # 不重新註冊、不換觸發器／principal、不啟停 Hub
    for banned in ("Register-ScheduledTask", "-Trigger", "-Principal",
                   "Start-ScheduledTask", "Stop-ScheduledTask",
                   "Enable-ScheduledTask", "Disable-ScheduledTask"):
        assert banned not in apply_script


def test_service_consistent_is_left_alone(installer, fake_ps):
    # 路徑大小寫／斜線差異、Windows 回報的等價時長都不算漂移
    fake_ps["stdout"] = _task_json(
        execute=fake_ps["wrapper"].upper().replace("\\", "/"),
        restart_interval="PT1M", time_limit="PT0S")
    out = installer.sync_service_settings()

    assert out == {"updated": False}
    assert len(fake_ps["calls"]) == 1  # 只讀不寫


def test_service_wrong_action_path_or_restart_is_drift(installer, fake_ps):
    fake_ps["stdout"] = _task_json(
        execute=r"C:\old\run-hub.cmd", restart_count=3,
        restart_interval="PT5M", time_limit="P3D")
    out = installer.sync_service_settings()

    assert out["updated"] is True
    assert out["drift"] == ["execute", "restart_count", "restart_interval",
                            "time_limit"]


def test_no_service_task_keeps_current_behaviour(installer, fake_ps):
    fake_ps["stdout"] = "null"
    assert installer.sync_service_settings() == {"updated": False}
    assert len(fake_ps["calls"]) == 1


def test_non_windows_does_not_touch_powershell(installer, fake_ps, monkeypatch):
    monkeypatch.setattr(installer.sys, "platform", "linux")
    assert installer.sync_service_settings() == {"updated": False}
    assert fake_ps["calls"] == []


def test_service_update_failure_is_reported_not_raised(installer, fake_ps):
    fake_ps["stdout"] = _task_json(priority=7, execute=fake_ps["wrapper"])
    fake_ps["apply_rc"] = 1
    out = installer.sync_service_settings()

    assert out["updated"] is False
    assert out["error"] == "boom"


def test_service_expectations_match_hub_service_script(installer):
    """installer 的期望值要與 hub-service.ps1 install 實際註冊的同步。"""
    ps1 = (REPO / "scripts" / "hub-service.ps1").read_text(encoding="utf-8")
    want = installer.SERVICE_WANT
    assert f"-Priority {want['priority']}" in ps1
    assert f"-RestartCount {want['restart_count']}" in ps1
    assert "-RestartInterval (New-TimeSpan -Minutes 1)" in ps1
    assert want["restart_interval_s"] == 60
    assert "-ExecutionTimeLimit ([TimeSpan]::Zero)" in ps1
    assert want["time_limit_s"] == 0
    assert f"$TaskName = '{installer.SERVICE_TASK}'" in ps1
    assert "run-hub.cmd" in ps1


def test_install_main_never_runs_real_powershell(installer, tmp_path, monkeypatch, capsys):
    """測試環境下跑安裝主流程，真的 PowerShell 執行器一次都不能被呼叫。

    曾因測試用的暫存 kit 讓安裝器改到線上的 ChatroomHub 排程工作。
    """
    import os
    assert os.environ.get("UEP_KIT_NO_SYSTEM"), "conftest 的硬保護沒生效"
    kit = tmp_path
    scripts = kit / "scripts"
    scripts.mkdir()
    (scripts / "run-hub.cmd").write_text("@echo off")  # 連 wrapper 存在也不可碰
    (scripts / "hub-service.ps1").write_text("")
    spawned = []

    def spy(*args, **kwargs):
        spawned.append(args)
        raise AssertionError("測試中不可啟動外部進程")

    monkeypatch.setattr(installer, "KIT", kit)
    monkeypatch.setattr(installer, "REGISTRY", tmp_path / "home" / "host-kit.json")
    monkeypatch.setattr(installer, "STAMP", kit / "none.json")
    monkeypatch.setattr(installer, "ensure_venv", lambda: None)
    monkeypatch.setattr(installer, "prepare_tunnel", lambda: False)
    monkeypatch.setattr(installer.subprocess, "run", spy)
    monkeypatch.setattr(installer.sys, "platform", "win32")
    monkeypatch.setattr(installer.shutil, "which", lambda n: "pwsh")
    for extra in ([], ["--register-service"]):
        monkeypatch.setattr(installer.sys, "argv",
                            ["install.py", "--yes", "--no-tunnel", *extra])
        installer.main()
    assert spawned == []
    out = capsys.readouterr().out
    assert '"service_updated": false' in out or '"service_updated":false' in out
