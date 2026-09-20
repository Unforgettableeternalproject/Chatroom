"""三包安裝器的**非互動契約**：App 是以子進程跑它們的。

桌面 App 從 GitHub Release 抓 kit 下來、解壓、然後 `python install.py --yes`。
那條路上沒有人在鍵盤前面，所以安裝器有三件事必須成立，而且三包要一致：

1. **不可以問問題。** `input()` 讀到的是一個沒有人會回答的管道——安裝就地
   停住，而 App 那邊只看得到「沒有輸出、也沒有結束」。這裡的做法是把
   `builtins.input` 換成會爆炸的東西：問了就紅。
2. **最後一行是 `RESULT {...}`。** App 只解析這一行，上面的人類文字它不讀。
   格式漂掉 = App 判成裝失敗，而安裝其實成功了。
3. **登錄檔要寫，而且欄位齊全**（kit_root / kit_version / commit /
   installed_at）——少一個 App 就顯示不出「這台裝的是哪一份程式碼」。

建 venv 與 pip 安裝不在這裡涵蓋（要網路、要好幾分鐘）：那些步驟被換成假的，
被驗的是**安裝器自己的流程與輸出契約**。
"""

from __future__ import annotations

import builtins
import importlib.util
import json
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]


def load(path: Path, name: str):
    """載入一支 install.py。三包都只用標準庫、import 時不做事。"""
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def no_input(monkeypatch):
    """問問題就是錯。這條線比任何字串比對都準——它抓的是行為。"""
    def boom(*_args, **_kwargs):
        raise AssertionError("非互動模式下不可以呼叫 input()")
    monkeypatch.setattr(builtins, "input", boom)


def result_line(out: str) -> dict:
    """取出並解析最後那行 `RESULT {...}`。"""
    lines = [ln for ln in out.splitlines() if ln.strip()]
    assert lines, "安裝器什麼都沒印"
    last = lines[-1]
    assert last.startswith("RESULT "), f"最後一行不是 RESULT：{last!r}"
    return json.loads(last[len("RESULT "):])


def write_stamp(path: Path, version: str, commit: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"version": version, "commit": commit,
                                "built_at": "2026-09-19T00:00:00+00:00"}),
                    encoding="utf-8")


# ---------- host-kit ----------


def test_host_kit_yes_is_silent_and_reports(tmp_path, monkeypatch, capsys,
                                            no_input):
    inst = load(REPO / "host-kit" / "install.py", "host_kit_installer_ni")
    kit = tmp_path / "kit"
    (kit / "server").mkdir(parents=True)
    monkeypatch.setattr(inst, "KIT", kit)
    monkeypatch.setattr(inst, "ENV_FILE", kit / "server" / ".env")
    monkeypatch.setattr(inst, "REGISTRY", tmp_path / "home" / "host-kit.json")
    write_stamp(kit / "server" / "chatroom_server" / "_build.json",
                "1.2.3", "abc123def456")
    monkeypatch.setattr(inst, "STAMP",
                        kit / "server" / "chatroom_server" / "_build.json")
    # venv 與隧道要網路，換成假的——這裡驗的是流程與輸出，不是 pip
    monkeypatch.setattr(inst, "ensure_venv", lambda: None)
    monkeypatch.setattr(inst, "prepare_tunnel", lambda: False)
    monkeypatch.setattr(sys, "argv", [
        "install.py", "--yes", "--no-tunnel",
        "--host", "127.0.0.1", "--port", "9999", "--token", "agent-key",
    ])

    inst.main()

    payload = result_line(capsys.readouterr().out)
    assert payload["ok"] is True
    assert payload["kit"] == "host-kit"
    assert payload["kit_root"] == str(kit)
    assert payload["version"] == "1.2.3"
    assert payload["commit"] == "abc123def456"
    assert payload["port"] == "9999"
    # 預設不註冊自啟：那是會改動這台機器排程的事，要明講才做
    assert payload["service_registered"] is False

    registry = json.loads(
        (tmp_path / "home" / "host-kit.json").read_text(encoding="utf-8"))
    assert registry["kit_root"] == str(kit)
    assert registry["kit_version"] == "1.2.3"
    assert registry["commit"] == "abc123def456"
    assert registry["installed_at"]
    # `version` 是登錄檔的格式版本，不是 kit 的版本——混用過一次就分不開
    assert registry["version"] == 1

    env = (kit / "server" / ".env").read_text(encoding="utf-8")
    assert "CHATROOM_TOKEN=agent-key" in env
    assert "CHATROOM_HUMAN_TOKEN=" in env


def test_host_kit_register_service_is_opt_in(tmp_path, monkeypatch, capsys,
                                             no_input):
    """`--register-service` 才呼叫 hub-service.ps1，而且結果要進 RESULT。"""
    inst = load(REPO / "host-kit" / "install.py", "host_kit_installer_svc")
    kit = tmp_path / "kit"
    (kit / "server").mkdir(parents=True)
    monkeypatch.setattr(inst, "KIT", kit)
    monkeypatch.setattr(inst, "ENV_FILE", kit / "server" / ".env")
    monkeypatch.setattr(inst, "REGISTRY", tmp_path / "home" / "host-kit.json")
    monkeypatch.setattr(inst, "STAMP", kit / "沒有這個檔.json")
    monkeypatch.setattr(inst, "ensure_venv", lambda: None)
    monkeypatch.setattr(inst, "prepare_tunnel", lambda: False)
    calls: list[bool] = []
    monkeypatch.setattr(inst, "register_service",
                        lambda: calls.append(True) or True)
    monkeypatch.setattr(sys, "argv", [
        "install.py", "--yes", "--no-tunnel", "--register-service",
    ])

    inst.main()

    payload = result_line(capsys.readouterr().out)
    assert calls == [True]
    assert payload["service_registered"] is True
    # 沒有 _build.json（原始碼樹）時是空字串，不是編出來的版本
    assert payload["version"] == "" and payload["commit"] == ""


def test_host_kit_failure_goes_to_stderr_with_nonzero_exit(
        tmp_path, monkeypatch, capsys):
    inst = load(REPO / "host-kit" / "install.py", "host_kit_installer_fail")
    monkeypatch.setattr(inst, "REGISTRY", tmp_path / "home" / "host-kit.json")

    with pytest.raises(SystemExit) as exc:
        inst.die("裝不起來")

    assert exc.value.code == 1
    captured = capsys.readouterr()
    assert "裝不起來" in captured.err, "失敗原因要走 stderr"
    payload = result_line(captured.out)
    assert payload == {"ok": False, "kit": "host-kit", "error": "裝不起來"}


# ---------- mcp-kit（install-kit） ----------


def test_mcp_kit_yes_is_silent_and_reports(tmp_path, monkeypatch, capsys,
                                           no_input):
    inst = load(REPO / "install-kit" / "install.py", "mcp_kit_installer_ni")
    kit = tmp_path / "kit"
    kit.mkdir()
    monkeypatch.setattr(inst, "KIT_DIR", kit)
    monkeypatch.setattr(inst, "REGISTRY", tmp_path / "home" / "mcp-kit.json")
    write_stamp(kit / "bridge" / "chatroom_mcp" / "_build.json",
                "1.2.3", "feedfacecafe")
    monkeypatch.setattr(inst, "STAMP",
                        kit / "bridge" / "chatroom_mcp" / "_build.json")
    # 建 venv／寫 MCP 設定都會動到這台機器，換成假的
    monkeypatch.setattr(inst, "check_agent_capabilities", lambda targets: None)
    monkeypatch.setattr(inst, "install_bridge",
                        lambda: kit / "venv" / "chatroom-mcp.exe")
    monkeypatch.setattr(inst, "setup_claude", lambda *a, **k: None)
    monkeypatch.setattr(inst, "setup_skill", lambda *a, **k: None)
    monkeypatch.setattr(inst, "setup_codex", lambda *a, **k: None)
    # 🔴 連不上 Hub 是這條路上最可能發生的事（Hub 沒開、還沒進 VPN）。
    # 互動模式會在這裡問「仍要繼續嗎」——`--yes` 下問了就是掛住
    monkeypatch.setattr(inst, "check_hub", lambda url, token: False)
    monkeypatch.setattr(sys, "argv", [
        "install.py", "--yes", "--url", "http://127.0.0.1:8787",
        "--token", "agent-key", "--name", "測試", "--targets", "claude",
    ])

    inst.main()

    payload = result_line(capsys.readouterr().out)
    assert payload["ok"] is True
    assert payload["kit"] == "mcp-kit"
    assert payload["kit_root"] == str(kit)
    assert payload["version"] == "1.2.3"
    assert payload["commit"] == "feedfacecafe"
    assert payload["targets"] == ["claude"]
    assert payload["has_token"] is True

    registry = json.loads(
        (tmp_path / "home" / "mcp-kit.json").read_text(encoding="utf-8"))
    assert registry["kit_root"] == str(kit)
    assert registry["kit_version"] == "1.2.3"
    assert registry["commit"] == "feedfacecafe"
    assert registry["installed_at"]

    env = (kit / ".env").read_text(encoding="utf-8-sig")
    assert "CHATROOM_TOKEN=agent-key" in env


def test_mcp_kit_yes_needs_no_value_at_all(tmp_path, monkeypatch, capsys,
                                           no_input):
    """一個參數都不給也不可以問——留空是合法狀態（之後填進 .env）。"""
    inst = load(REPO / "install-kit" / "install.py", "mcp_kit_installer_bare")
    kit = tmp_path / "kit"
    kit.mkdir()
    monkeypatch.setattr(inst, "KIT_DIR", kit)
    monkeypatch.setattr(inst, "REGISTRY", tmp_path / "home" / "mcp-kit.json")
    monkeypatch.setattr(inst, "STAMP", kit / "沒有這個檔.json")
    monkeypatch.setattr(inst, "check_agent_capabilities", lambda targets: None)
    monkeypatch.setattr(inst, "install_bridge",
                        lambda: kit / "venv" / "chatroom-mcp.exe")
    monkeypatch.setattr(inst, "setup_claude", lambda *a, **k: None)
    monkeypatch.setattr(inst, "setup_skill", lambda *a, **k: None)
    monkeypatch.setattr(inst, "setup_codex", lambda *a, **k: None)
    monkeypatch.setattr(sys, "argv", ["install.py", "--yes"])

    inst.main()

    payload = result_line(capsys.readouterr().out)
    assert payload["ok"] is True
    assert payload["url"] == "" and payload["has_token"] is False


# ---------- runner-kit ----------


def _fake_stage(inst, kit_src: Path, monkeypatch, *, version="1.2.3",
                commit="0badc0ffee11"):
    """把「搬檔案 + 建 venv」換成假的，留下 write_config 與登錄檔那段真的跑。"""
    def stage(target: Path) -> None:
        (target / "runner" / "chatroom_runner").mkdir(parents=True,
                                                      exist_ok=True)
        (target / "runner" / "config.example.json").write_text(
            (kit_src / "runner" / "config.example.json")
            .read_text(encoding="utf-8"), encoding="utf-8")
        write_stamp(target / "runner" / "chatroom_runner" / "_build.json",
                    version, commit)

    monkeypatch.setattr(inst, "stage_kit", stage)
    monkeypatch.setattr(inst, "ensure_venv",
                        lambda target: target / ".venv" / "python.exe")
    monkeypatch.setattr(inst, "write_pth", lambda python, target: True)


def test_runner_kit_yes_is_silent_and_reports(tmp_path, monkeypatch, capsys,
                                              no_input):
    inst = load(REPO / "runner-kit" / "install.py", "runner_kit_installer_ni")
    monkeypatch.setattr(inst, "REGISTRY", tmp_path / "home" / "runner-kit.json")
    _fake_stage(inst, REPO, monkeypatch)
    target = tmp_path / "install"
    config = tmp_path / "state" / "config.json"

    inst.main(["--yes", "--dir", str(target), "--config", str(config),
               "--no-task", "--hub-url", "http://127.0.0.1:8787",
               "--token", "agent-key", "--label", "runner-a"])

    payload = result_line(capsys.readouterr().out)
    assert payload["ok"] is True
    assert payload["kit"] == "runner-kit"
    assert payload["kit_root"] == str(target)
    assert payload["config"] == str(config)
    assert payload["version"] == "1.2.3"
    assert payload["commit"] == "0badc0ffee11"
    assert payload["config_written"] is True
    assert payload["task_registered"] is False

    registry = json.loads(
        (tmp_path / "home" / "runner-kit.json").read_text(encoding="utf-8"))
    # `kit_dir` 是 App 現在讀的欄位，`kit_root` 是三包共用的名字——都要在
    assert registry["kit_dir"] == str(target)
    assert registry["kit_root"] == str(target)
    assert registry["kit_version"] == "1.2.3"
    assert registry["commit"] == "0badc0ffee11"
    assert registry["installed_at"]

    cfg = json.loads(config.read_text(encoding="utf-8"))
    assert cfg["hub_url"] == "http://127.0.0.1:8787"
    assert cfg["agent_token"] == "agent-key"
    assert cfg["label"] == "runner-a"
    assert cfg["workspaces"] == {}


def test_runner_kit_yes_reports_login_required_and_does_not_log_in(
        tmp_path, monkeypatch, capsys, no_input):
    """`--yes` 下**不起登入流程**，只在 RESULT 講「還要登入」與那一行指令。

    App 是以子進程跑這支的，stdin 是 null——起 `claude auth login` 等於掛在
    一個沒有人的終端機前面。少了 `login_required`，App 會顯示「可以開跑了」，
    而執行器第一筆單就會因為沒登入而失敗。
    """
    inst = load(REPO / "runner-kit" / "install.py", "runner_kit_installer_login")
    monkeypatch.setattr(inst, "REGISTRY", tmp_path / "home" / "runner-kit.json")
    _fake_stage(inst, REPO, monkeypatch)
    # 起了登入就是錯：這條線抓的是行為，不是字串
    monkeypatch.setattr(inst, "run_login", lambda _dir: pytest.fail(
        "非互動模式下不可以起登入流程"))
    config = tmp_path / "state" / "config.json"

    inst.main(["--yes", "--dir", str(tmp_path / "install"),
               "--config", str(config), "--no-task"])

    out = capsys.readouterr().out
    payload = result_line(out)
    assert payload["login_required"] is True
    assert str(tmp_path / "state" / "claude-config") in payload["login_hint"]
    assert "CLAUDE_CONFIG_DIR" in payload["login_hint"]
    assert "claude auth login" in payload["login_hint"]
    # 免責聲明照印（走 stdout、不擋流程）
    assert "只支援 Claude Code" in out
    assert "Codex" in out


def test_runner_kit_yes_sees_an_existing_login(tmp_path, monkeypatch, capsys,
                                               no_input):
    """憑證在就不要叫人再登一次——`login_required` 要是 false。"""
    inst = load(REPO / "runner-kit" / "install.py", "runner_kit_installer_in")
    monkeypatch.setattr(inst, "REGISTRY", tmp_path / "home" / "runner-kit.json")
    _fake_stage(inst, REPO, monkeypatch)
    config = tmp_path / "state" / "config.json"
    claude_config = config.parent / "claude-config"
    claude_config.mkdir(parents=True)
    (claude_config / ".credentials.json").write_text(
        '{"claudeAiOauth":{"accessToken":"x"}}', encoding="utf-8")

    inst.main(["--yes", "--dir", str(tmp_path / "install"),
               "--config", str(config), "--no-task"])

    assert result_line(capsys.readouterr().out)["login_required"] is False


def test_runner_kit_yes_keeps_an_existing_config_and_says_so(
        tmp_path, monkeypatch, capsys, no_input):
    """設定檔已存在時不覆寫——而 RESULT 要講出「這次沒寫」。

    不講的話 App 會顯示「已套用新的 Hub 位址」，而實際上那兩個值根本沒進去。
    """
    inst = load(REPO / "runner-kit" / "install.py", "runner_kit_installer_keep")
    monkeypatch.setattr(inst, "REGISTRY", tmp_path / "home" / "runner-kit.json")
    _fake_stage(inst, REPO, monkeypatch)
    config = tmp_path / "state" / "config.json"
    config.parent.mkdir(parents=True)
    config.write_text('{"hub_url": "http://舊的:8787"}\n', encoding="utf-8")

    inst.main(["--yes", "--dir", str(tmp_path / "install"),
               "--config", str(config), "--no-task",
               "--hub-url", "http://新的:8787"])

    payload = result_line(capsys.readouterr().out)
    assert payload["ok"] is True
    assert payload["config_written"] is False
    assert json.loads(config.read_text(encoding="utf-8"))["hub_url"] \
        == "http://舊的:8787"


def test_runner_kit_incomplete_package_fails_loudly(tmp_path, monkeypatch,
                                                    capsys):
    """交付包缺了 runner/：要非 0 退出、stderr 有原因、stdout 仍有 RESULT。"""
    inst = load(REPO / "runner-kit" / "install.py", "runner_kit_installer_bad")
    kit = tmp_path / "kit"
    kit.mkdir()
    monkeypatch.setattr(inst, "KIT", kit)
    monkeypatch.setattr(inst, "REGISTRY", tmp_path / "home" / "runner-kit.json")

    with pytest.raises(SystemExit) as exc:
        inst.stage_kit(tmp_path / "install")

    assert exc.value.code == 1
    captured = capsys.readouterr()
    assert "不完整" in captured.err
    assert result_line(captured.out)["ok"] is False


# ---------- 三包一致 ----------


def test_result_key_shape_is_the_same_across_kits():
    """三包的 RESULT 共用欄位必須同名同義，App 才寫得出一套解析。"""
    common = {"ok", "kit", "registry", "kit_root", "version", "commit",
              "installed_at"}
    for path, name in (
        (REPO / "host-kit" / "install.py", "host_shape"),
        (REPO / "install-kit" / "install.py", "mcp_shape"),
        (REPO / "runner-kit" / "install.py", "runner_shape"),
    ):
        source = path.read_text(encoding="utf-8")
        assert 'print("RESULT "' in source, f"{name} 沒有 RESULT 行"
        for key in common:
            assert f'"{key}"' in source, f"{name} 的 RESULT 缺 {key}"
