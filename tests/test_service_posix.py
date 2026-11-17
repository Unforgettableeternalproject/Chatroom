"""非 Windows 的服務管理（scripts/service.py）與 macOS／Linux 的打包產物。

systemd／launchd 在 CI 與 Windows 上都不存在，所以這裡驗的是**組出來的內容
與指令**（unit／plist 的欄位、systemctl／launchctl 的呼叫順序），真的註冊與
啟停由 WSL（systemd）實測；macOS 無法實測，這裡是 launchd 分支唯一的守門員。
"""

from __future__ import annotations

import importlib.util
import json
import plistlib
import subprocess
import sys
import zipfile
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def svc():
    return _load("_uep_service", REPO / "scripts" / "service.py")


class FakeRun:
    """記錄每一條外部指令；`replies` 以 argv 前綴決定回什麼。"""

    def __init__(self, replies=None):
        self.calls: list[list[str]] = []
        self.replies = replies or {}

    def __call__(self, argv, timeout=30.0):
        self.calls.append(list(argv))
        for prefix, (code, out) in self.replies.items():
            if " ".join(argv).startswith(prefix):
                return subprocess.CompletedProcess(argv, code, out, "")
        return subprocess.CompletedProcess(argv, 0, "", "")

    def joined(self) -> list[str]:
        return [" ".join(c) for c in self.calls]


@pytest.fixture()
def kit(tmp_path):
    """一個長得像已安裝 kit 的目錄（含 venv python、server、runner）。"""
    root = tmp_path / "kit"
    # 兩種平台的直譯器路徑都放：測試會 monkeypatch sys.platform
    for sub in ("Scripts/python.exe", "bin/python"):
        py = root / ".venv" / sub
        py.parent.mkdir(parents=True)
        py.write_text("", encoding="utf-8")
    (root / "server" / "chatroom_server").mkdir(parents=True)
    (root / "server" / ".env").write_text("CHATROOM_PORT=9191\n",
                                          encoding="utf-8")
    (root / "runner" / "chatroom_runner").mkdir(parents=True)
    return root


@pytest.fixture()
def home(tmp_path, monkeypatch, svc):
    h = tmp_path / "home"
    h.mkdir()
    monkeypatch.setenv("HOME", str(h))
    monkeypatch.setenv("USERPROFILE", str(h))
    monkeypatch.delenv("XDG_DATA_HOME", raising=False)
    monkeypatch.delenv("XDG_CONFIG_HOME", raising=False)
    monkeypatch.delenv("CHATROOM_PORT", raising=False)
    return h


# ── 安裝根目錄：三處必須給同一個答案 ───────────────────────────

@pytest.mark.parametrize("platform", ["linux", "darwin"])
def test_install_root_is_the_same_everywhere(svc, home, monkeypatch, platform):
    """service.py、執行器 config、runner-kit 安裝器對根目錄的判斷一致。

    原本 runner-kit 在非 Windows 退回 `~/AppData/Local`，而執行器自己找設定
    的位置是 `~/.local/share/...`——安裝器寫的設定檔執行器永遠讀不到。
    """
    from chatroom_runner import config as cfg_mod

    inst = _load("_runner_kit_install_posix", REPO / "runner-kit" / "install.py")
    monkeypatch.setattr(sys, "platform", platform)
    monkeypatch.setenv("LOCALAPPDATA", str(home / "must-be-ignored"))

    root = svc.install_root()
    assert cfg_mod.default_install_root() == root
    assert inst.install_root() == root
    assert cfg_mod.default_state_dir() == root / "runner"
    assert inst.default_config_path() == root / "runner" / "config.json"
    assert inst.default_install_dir() == root / "runner-kit"
    if platform == "darwin":
        assert root == home / "Library" / "Application Support" / "UEP" / "Chatroom"
    else:
        assert root == home / ".local" / "share" / "uep" / "chatroom"


def test_install_root_windows_unchanged(svc, monkeypatch, tmp_path):
    from chatroom_runner import config as cfg_mod

    monkeypatch.setattr(sys, "platform", "win32")
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path / "lad"))
    assert svc.install_root() == tmp_path / "lad" / "UEP" / "Chatroom"
    assert cfg_mod.default_state_dir() == (
        tmp_path / "lad" / "UEP" / "Chatroom" / "runner")


# ── systemd unit ─────────────────────────────────────────────

def test_systemd_unit_content(svc, home, kit, monkeypatch):
    monkeypatch.setattr(sys, "platform", "linux")
    spec = svc.make_spec("runner", kit, config=home / "my config.json")
    unit = svc.build_systemd_unit(spec, "/usr/bin:/home/u/.local/bin")
    assert "Restart=always" in unit
    assert "RestartSec=60" in unit
    assert f"StandardOutput=append:{spec.log_file}" in unit
    assert f"StandardError=append:{spec.log_file}" in unit
    assert spec.log_file == (home / ".local" / "share" / "uep" / "chatroom"
                             / "runner" / "logs" / "service.log")
    # 含空白的路徑必須加引號，否則 systemd 會把它切成兩個參數
    assert svc._sd_word(str(home / "my config.json")) in unit
    assert svc._sd_word(str(home / "my config.json")).startswith('"')
    assert "-m chatroom_runner --config" in unit
    assert 'Environment="PATH=/usr/bin:/home/u/.local/bin"' in unit
    assert "WantedBy=default.target" in unit
    assert f"WorkingDirectory={kit}" in unit


def test_systemd_unit_for_hub_uses_server_dir(svc, home, kit, monkeypatch):
    monkeypatch.setattr(sys, "platform", "linux")
    spec = svc.make_spec("hub", kit)
    unit = svc.build_systemd_unit(spec, "")
    assert spec.unit == "uep-chatroom-hub.service"
    assert f"WorkingDirectory={kit / 'server'}" in unit
    assert "-m chatroom_server" in unit
    assert "RestartSec=60" in unit
    assert "Environment=" not in unit  # PATH 空就不寫
    assert spec.port == "9191"  # 從 server/.env 讀


def test_systemd_escapes_percent(svc):
    assert svc._sd_word("100%") == "100%%"
    assert svc._sd_word("a b") == '"a b"'


def test_install_runs_daemon_reload_and_enable_without_starting(
        svc, home, kit, monkeypatch):
    monkeypatch.setattr(sys, "platform", "linux")
    fake = FakeRun()
    monkeypatch.setattr(svc, "run_cmd", fake)
    monkeypatch.setattr(svc.shutil, "which", lambda name: f"/bin/{name}")
    spec = svc.make_spec("hub", kit)
    detail = svc.systemd_install(spec)
    unit_file = home / ".config" / "systemd" / "user" / "uep-chatroom-hub.service"
    assert unit_file.exists()
    assert "Restart=always" in unit_file.read_text(encoding="utf-8")
    cmds = fake.joined()
    assert cmds[0] == "systemctl --user daemon-reload"
    assert "systemctl --user enable uep-chatroom-hub.service" in cmds
    # install 不啟動（與 Windows 的 hub-service.ps1 install 一致）
    assert not any(" start " in c or "--now" in c for c in cmds)
    assert "還沒啟動" in detail
    assert spec.log_file.parent.is_dir()


def test_stop_disables_so_restart_policy_cannot_revive_it(
        svc, home, kit, monkeypatch):
    """Windows 的 stop 會停用觸發器；這裡對應的是 `disable --now`。"""
    monkeypatch.setattr(sys, "platform", "linux")
    fake = FakeRun()
    monkeypatch.setattr(svc, "run_cmd", fake)
    monkeypatch.setattr(svc, "port_owners", lambda port: [])
    spec = svc.make_spec("hub", kit)
    svc.systemd_stop(spec)
    assert fake.joined()[0] == "systemctl --user disable --now uep-chatroom-hub.service"


def test_start_requires_install_and_re_enables(svc, home, kit, monkeypatch):
    monkeypatch.setattr(sys, "platform", "linux")
    fake = FakeRun()
    monkeypatch.setattr(svc, "run_cmd", fake)
    spec = svc.make_spec("runner", kit)
    with pytest.raises(svc.ServiceError):
        svc.systemd_start(spec)  # 還沒 install
    unit_dir = home / ".config" / "systemd" / "user"
    unit_dir.mkdir(parents=True)
    (unit_dir / spec.unit).write_text("", encoding="utf-8")
    svc.systemd_start(spec)
    assert fake.joined()[-1] == f"systemctl --user enable --now {spec.unit}"


def test_systemd_status_contract(svc, home, kit, monkeypatch):
    monkeypatch.setattr(sys, "platform", "linux")
    fake = FakeRun({
        "systemctl --user is-enabled": (0, "enabled\n"),
        "systemctl --user is-active": (0, "active\n"),
    })
    monkeypatch.setattr(svc, "run_cmd", fake)
    spec = svc.make_spec("runner", kit)
    unit_dir = home / ".config" / "systemd" / "user"
    unit_dir.mkdir(parents=True)
    (unit_dir / spec.unit).write_text("", encoding="utf-8")
    status = svc.systemd_status(spec)
    assert set(status) == {"manager", "installed", "enabled", "running", "detail"}
    assert status["manager"] == "systemd"
    assert status["installed"] and status["enabled"] and status["running"]
    assert isinstance(status["detail"], str)


def test_status_when_not_installed(svc, home, kit, monkeypatch):
    monkeypatch.setattr(sys, "platform", "linux")
    monkeypatch.setattr(svc, "run_cmd", FakeRun({
        "systemctl --user is-enabled": (1, "disabled\n"),
        "systemctl --user is-active": (3, "inactive\n"),
    }))
    status = svc.systemd_status(svc.make_spec("hub", kit))
    assert (status["installed"], status["enabled"], status["running"]) == (
        False, False, False)


# ── launchd plist ────────────────────────────────────────────

def test_launchd_plist_content(svc, home, kit, monkeypatch):
    monkeypatch.setattr(sys, "platform", "darwin")
    spec = svc.make_spec("runner", kit)
    data = plistlib.loads(svc.build_launchd_plist(spec, "/opt/homebrew/bin:/usr/bin"))
    assert data["Label"] == "com.uep.chatroom.runner"
    assert data["RunAtLoad"] is True
    assert data["KeepAlive"] is True
    assert data["ThrottleInterval"] == 60
    assert data["ProgramArguments"][1:4] == ["-m", "chatroom_runner", "--config"]
    assert data["WorkingDirectory"] == str(kit)
    log = (home / "Library" / "Application Support" / "UEP" / "Chatroom"
           / "runner" / "logs" / "service.log")
    assert data["StandardOutPath"] == str(log)
    assert data["StandardErrorPath"] == str(log)
    assert data["EnvironmentVariables"]["PATH"] == "/opt/homebrew/bin:/usr/bin"


def test_launchd_hub_label_and_dir(svc, home, kit, monkeypatch):
    monkeypatch.setattr(sys, "platform", "darwin")
    spec = svc.make_spec("hub", kit)
    data = plistlib.loads(svc.build_launchd_plist(spec, ""))
    assert data["Label"] == "com.uep.chatroom.hub"
    assert data["WorkingDirectory"] == str(kit / "server")
    assert "EnvironmentVariables" not in data


@pytest.fixture()
def posix_uid(svc, monkeypatch):
    monkeypatch.setattr(svc.os, "getuid", lambda: 501, raising=False)


def test_launchd_install_writes_plist_and_enables(
        svc, home, kit, monkeypatch, posix_uid):
    monkeypatch.setattr(sys, "platform", "darwin")
    fake = FakeRun()
    monkeypatch.setattr(svc, "run_cmd", fake)
    spec = svc.make_spec("runner", kit)
    svc.launchd_install(spec)
    plist = home / "Library" / "LaunchAgents" / "com.uep.chatroom.runner.plist"
    assert plistlib.loads(plist.read_bytes())["Label"] == spec.label
    assert fake.joined() == ["launchctl enable gui/501/com.uep.chatroom.runner"]


def test_launchd_start_bootstraps_when_not_loaded(
        svc, home, kit, monkeypatch, posix_uid):
    monkeypatch.setattr(sys, "platform", "darwin")
    fake = FakeRun({"launchctl print gui/501/": (113, "")})  # 沒載入
    monkeypatch.setattr(svc, "run_cmd", fake)
    spec = svc.make_spec("hub", kit)
    agents = home / "Library" / "LaunchAgents"
    agents.mkdir(parents=True)
    plist = agents / "com.uep.chatroom.hub.plist"
    plist.write_bytes(b"x")
    svc.launchd_start(spec)
    assert fake.joined() == [
        "launchctl enable gui/501/com.uep.chatroom.hub",
        "launchctl print gui/501/com.uep.chatroom.hub",
        f"launchctl bootstrap gui/501 {plist}",
        "launchctl kickstart gui/501/com.uep.chatroom.hub",
    ]


def test_launchd_stop_boots_out_and_disables(
        svc, home, kit, monkeypatch, posix_uid):
    monkeypatch.setattr(sys, "platform", "darwin")
    fake = FakeRun()  # print 回 0 ＝ 已載入
    monkeypatch.setattr(svc, "run_cmd", fake)
    monkeypatch.setattr(svc, "port_owners", lambda port: [])
    svc.launchd_stop(svc.make_spec("hub", kit))
    assert fake.joined() == [
        "launchctl print gui/501/com.uep.chatroom.hub",
        "launchctl bootout gui/501/com.uep.chatroom.hub",
        "launchctl disable gui/501/com.uep.chatroom.hub",
    ]


def test_launchd_status_running_and_disabled_flags(
        svc, home, kit, monkeypatch, posix_uid):
    monkeypatch.setattr(sys, "platform", "darwin")
    fake = FakeRun({
        "launchctl print gui/501/": (0, "state = running\n\tpid = 42\n"),
        "launchctl print-disabled": (
            0, '\t"com.uep.chatroom.runner" => disabled\n'),
    })
    monkeypatch.setattr(svc, "run_cmd", fake)
    spec = svc.make_spec("runner", kit)
    agents = home / "Library" / "LaunchAgents"
    agents.mkdir(parents=True)
    (agents / "com.uep.chatroom.runner.plist").write_bytes(b"x")
    status = svc.launchd_status(spec)
    assert status["manager"] == "launchd"
    assert status["installed"] is True
    assert status["running"] is True
    assert status["enabled"] is False  # 被 stop 停用了


# ── 分派、無管理員、埠擁有者 ───────────────────────────────────

def test_status_json_when_no_manager(svc, monkeypatch, capsys):
    monkeypatch.setattr(svc, "detect_manager", lambda: "none")
    code = svc.main(["hub", "status", "--json"])
    out = json.loads(capsys.readouterr().out)
    assert code == 0
    assert out["manager"] == "none"
    assert (out["installed"], out["enabled"], out["running"]) == (
        False, False, False)
    assert out["detail"]


def test_install_without_manager_fails_loudly(svc, monkeypatch, capsys):
    monkeypatch.setattr(svc, "detect_manager", lambda: "none")
    code = svc.main(["runner", "install", "--json"])
    out = json.loads(capsys.readouterr().out)
    assert code == 1 and out["ok"] is False and out["detail"]


def test_detect_manager_needs_a_reachable_user_bus(svc, monkeypatch):
    monkeypatch.setattr(sys, "platform", "linux")
    monkeypatch.setattr(svc.shutil, "which", lambda name: f"/bin/{name}")
    monkeypatch.setattr(svc, "run_cmd", FakeRun(
        {"systemctl --user show-environment": (1, "")}))
    assert svc.detect_manager() == "none"
    monkeypatch.setattr(svc, "run_cmd", FakeRun())
    assert svc.detect_manager() == "systemd"
    monkeypatch.setattr(sys, "platform", "darwin")
    assert svc.detect_manager() == "launchd"
    monkeypatch.setattr(sys, "platform", "win32")
    assert svc.detect_manager() == "none"


def test_install_refuses_missing_interpreter(svc, home, tmp_path, monkeypatch):
    monkeypatch.setattr(sys, "platform", "linux")
    empty = tmp_path / "empty-kit"
    empty.mkdir()
    with pytest.raises(svc.ServiceError):
        svc.make_spec("runner", empty)
    # 但 status／stop／uninstall 在 kit 被刪掉之後仍然要能用
    assert svc.make_spec("runner", empty, check=False).unit.startswith("uep-")


def test_free_port_only_kills_python(svc, home, kit, monkeypatch):
    monkeypatch.setattr(sys, "platform", "linux")
    spec = svc.make_spec("hub", kit)
    killed: list[tuple] = []
    monkeypatch.setattr(svc, "port_owners", lambda port: [111, 222])
    monkeypatch.setattr(svc, "_proc_name",
                        lambda pid: {111: "python3.12", 222: "nginx"}[pid])
    monkeypatch.setattr(svc.os, "kill",
                        lambda pid, sig: killed.append((pid, sig)))
    monkeypatch.setattr(svc, "_alive", lambda pid: False)
    note = svc.free_port(spec)
    assert [pid for pid, _ in killed] == [111]
    assert "nginx" in note and "不動它" in note


def test_free_port_noop_for_runner(svc, home, kit, monkeypatch):
    monkeypatch.setattr(sys, "platform", "linux")
    monkeypatch.setattr(svc, "port_owners",
                        lambda port: pytest.fail("runner 沒有埠，不該去查"))
    assert svc.free_port(svc.make_spec("runner", kit)) == ""


# ── 打包：執行位元與 LF ───────────────────────────────────────

def test_write_zip_sets_unix_modes_and_lf(tmp_path):
    bs = _load("_buildstamp_for_zip", REPO / "scripts" / "buildstamp.py")
    stage = tmp_path / "stage" / "kit"
    stage.mkdir(parents=True)
    (stage / "install.sh").write_bytes(b"#!/bin/sh\r\necho hi\r\n")
    (stage / "readme.txt").write_bytes(b"a\r\nb\r\n")
    out = tmp_path / "x.zip"
    bs.write_zip(out, stage, tmp_path / "stage")
    with zipfile.ZipFile(out) as zf:
        sh = zf.getinfo("kit/install.sh")
        txt = zf.getinfo("kit/readme.txt")
        assert (sh.external_attr >> 16) & 0o777 == 0o755
        assert (txt.external_attr >> 16) & 0o777 == 0o644
        assert sh.create_system == 3
        assert zf.read("kit/install.sh") == b"#!/bin/sh\necho hi\n"
        assert zf.read("kit/readme.txt") == b"a\r\nb\r\n"  # 只動 .sh


@pytest.mark.parametrize("kit_name,builder,zipname,sh_files,svc_path", [
    ("host-kit", "host-kit/build.py", "chatroom-hub-kit.zip",
     ["install.sh", "scripts/run-hub.sh", "scripts/run-tunnel.sh"],
     "scripts/service.py"),
    ("runner-kit", "runner-kit/build.py", "chatroom-runner-kit.zip",
     ["install.sh", "runner/chatroom_runner/hooks/askpass-deny.sh"],
     "scripts/service.py"),
])
def test_built_kits_carry_posix_entrypoints(tmp_path, monkeypatch, kit_name,
                                            builder, zipname, sh_files,
                                            svc_path):
    """兩個要裝服務的 kit：.sh 有執行位元、帶 service.py，且 service.py 是同一份。"""
    monkeypatch.setattr(sys, "argv", ["build.py"])  # build 的 argparse 吃 argv
    mod = _load(f"_build_{kit_name.replace('-', '_')}", REPO / builder)
    if kit_name == "runner-kit":
        zip_path, _info, _head = mod.build(tmp_path)
    else:
        mod.DIST = tmp_path
        mod.main()
        zip_path = tmp_path / zipname
    prefix = zip_path.stem.replace("chatroom-", "chatroom-")
    with zipfile.ZipFile(zip_path) as zf:
        names = zf.namelist()
        root = names[0].split("/", 1)[0]
        for rel in sh_files:
            info = zf.getinfo(f"{root}/{rel}")
            assert (info.external_attr >> 16) & 0o111, f"{rel} 沒有執行位元"
            assert b"\r" not in zf.read(info), f"{rel} 帶了 CR"
        assert (zf.read(f"{root}/{svc_path}")
                == (REPO / "scripts" / "service.py").read_bytes()
                or zf.read(f"{root}/{svc_path}").replace(b"\r\n", b"\n")
                == (REPO / "scripts" / "service.py").read_bytes()
                .replace(b"\r\n", b"\n"))
    assert prefix


def test_install_kit_ships_install_sh(tmp_path, monkeypatch):
    monkeypatch.setattr(sys, "argv", ["build.py"])
    mod = _load("_build_install_kit", REPO / "install-kit" / "build.py")
    mod.DIST = tmp_path
    mod.main()
    with zipfile.ZipFile(tmp_path / "chatroom-mcp-kit.zip") as zf:
        info = zf.getinfo("chatroom-mcp-kit/install.sh")
        assert (info.external_attr >> 16) & 0o111


# ── 入口腳本本身 ──────────────────────────────────────────────

SH_FILES = [
    "install-kit/install.sh", "host-kit/install.sh", "runner-kit/install.sh",
    "scripts/run-hub.sh", "scripts/run-tunnel.sh",
]


@pytest.mark.parametrize("rel", SH_FILES)
def test_shell_scripts_are_lf_posix_sh(rel):
    raw = (REPO / rel).read_bytes()
    assert raw.startswith(b"#!/bin/sh\n"), f"{rel} 的 shebang 不對"
    assert b"\r" not in raw, f"{rel} 帶了 CR（會讓 shebang 失效）"
    assert b"[[" not in raw, f"{rel} 用了 bash 專有語法"


@pytest.mark.parametrize("rel", SH_FILES + [
    "runner/chatroom_runner/hooks/askpass-deny.sh"])
def test_shell_scripts_are_committed_executable(rel):
    """git index 裡的模式是 100755：clone 之後直接可執行、build 也不必猜。"""
    out = subprocess.run(["git", "ls-files", "-s", "--", rel], cwd=REPO,
                         capture_output=True, text=True)
    if out.returncode != 0 or not out.stdout.strip():
        pytest.skip(f"{rel} 還沒進 index（或不在 git repo 內）")
    assert out.stdout.split()[0] == "100755", out.stdout
