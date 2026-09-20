"""runner-kit：打包內容與安裝器的回歸測試。

守的兩類都是「打包／安裝全程顯示成功，收到的人拿到壞東西」：

1. **少帶了東西**。`bridge/` 漏掉的話執行器照樣上線、照樣領單，只是它起的
   claude **連不上聊天室**（No module named chatroom_mcp），而失敗只出現在
   run 的 stream log 裡。`install-task.ps1` 漏掉的話則是連排程都註冊不了。
2. **多帶了東西**。`.env`、`state.json`、`logs/`、`usage.db` 帶的是這台開發機
   的 token、房間 id 與 run brief；`config.example.json` 帶的是這台機器的
   絕對路徑與幾個私有 repo 的名字。交付包發出去就收不回來了。

另外驗安裝器的兩個「顯示成功、實際弄壞」：設定檔被覆寫（使用者加好的專案
全消失，執行器照樣上線但領不到單），以及註冊檔欄位改名（App 會當成沒裝）。
"""

from __future__ import annotations

import importlib.util
import json
import sys
import zipfile
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
KIT = REPO / "runner-kit"


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def builder():
    return _load("_runner_kit_build", KIT / "build.py")


@pytest.fixture()
def installer(tmp_path: Path):
    """載入安裝器，並把會寫到家目錄的那份常數指到 tmp。

    不改的話這些測試會動到**真的** `~/.chatroom/runner-kit.json`——那是這台
    機器上 App 正在讀的指路牌。
    """
    module = _load("_runner_kit_install", KIT / "install.py")
    module.REGISTRY = tmp_path / "home" / ".chatroom" / "runner-kit.json"
    return module


@pytest.fixture(scope="module")
def packed(tmp_path_factory, builder):
    """真的打一份包出來驗內容，但打在 tmp——不覆蓋 dist/ 裡正在發的那份。"""
    dist = tmp_path_factory.mktemp("dist")
    zip_path, info, _head = builder.build(dist)
    with zipfile.ZipFile(zip_path) as zf:
        names = zf.namelist()
    return zip_path, info, names, dist


# ---------- 打包內容 ----------


def _rel(names: list[str]) -> set[str]:
    """去掉 zip 內的 `chatroom-runner-kit/` 前綴。"""
    return {n.split("/", 1)[1] for n in names if "/" in n}


def test_zip_has_the_pieces_that_make_it_run(packed):
    """少一個都是「裝得起來、跑不動」，而且症狀都不指向缺件。"""
    files = _rel(packed[2])
    for need in (
        "install.py",
        # 雙擊入口。漏了它，不會下 python 指令的人手上就只有一包原始碼——
        # 而那正是這包要解決的那件事
        "install.bat",
        "install-help.txt",      # bat 在找不到 Python 時印的中文說明
        "README.md",
        "runner/install-task.ps1",       # 沒有它就註冊不了排程工作
        "runner/config.example.json",    # install.py 以它為底產生設定
        "runner/README.md",
        "runner/chatroom_runner/__main__.py",
        "runner/chatroom_runner/loop.py",
        "runner/chatroom_runner/hooks/pretooluse.py",  # 守衛 hook，漏了就沒人擋
        "bridge/chatroom_mcp/server.py",  # 漏了 → run 裡的 claude 連不上聊天室
    ):
        assert need in files, f"交付包缺 {need}"


def test_zip_does_not_leak_this_machine(packed):
    """開發機的 token、房間 id、run brief 不可以跟著發出去。"""
    files = _rel(packed[2])
    assert not [f for f in files if "__pycache__" in f]
    assert not [f for f in files if Path(f).name.startswith(".env")]
    assert not [f for f in files if f.startswith("runner/tests/")]
    assert not [f for f in files if f.startswith("bridge/tests/")]
    assert not [f for f in files if f.startswith("runner/logs/")]
    assert not [f for f in files if Path(f).name == "state.json"]
    assert not [f for f in files if Path(f).suffix == ".db"]


def test_packaged_example_config_has_no_machine_paths(packed):
    """交付出去的樣板不可以是**開發機的現場**。

    repo 內那份寫著本機絕對路徑、機器名與幾個私有 repo——對 repo 使用者剛好
    合用，發出去卻等於把一台不相干機器的目錄結構交給收件人。
    """
    zip_path = packed[0]
    with zipfile.ZipFile(zip_path) as zf:
        raw = zf.read("chatroom-runner-kit/runner/config.example.json")
    text = raw.decode("utf-8")
    cfg = json.loads(text)
    assert cfg["workspaces"] == {}
    assert cfg["host"] == "this-machine"
    assert "C:/Users/" not in text and "C:\\Users\\" not in text


def test_build_stamp_is_written_on_both_halves(packed):
    """執行器與它自帶的 bridge 是同一次打包出去的，版本理當一致。"""
    files = _rel(packed[2])
    assert "runner/chatroom_runner/_build.json" in files
    assert "bridge/chatroom_mcp/_build.json" in files
    with zipfile.ZipFile(packed[0]) as zf:
        runner = json.loads(
            zf.read("chatroom-runner-kit/runner/chatroom_runner/_build.json"))
        bridge = json.loads(
            zf.read("chatroom-runner-kit/bridge/chatroom_mcp/_build.json"))
    assert runner == bridge == packed[1]
    assert runner["version"] and runner["built_at"]


def test_expect_gate_aborts_on_the_wrong_commit(tmp_path, builder):
    """`--expect` 對不上就不該產出 zip——半個產物比沒有產物更難察覺。"""
    dist = tmp_path / "dist"
    with pytest.raises(SystemExit):
        builder.build(dist, expect="0000000deadbeef")
    assert not (dist / "chatroom-runner-kit.zip").exists()


# ---------- 安裝器 ----------


def test_config_is_never_overwritten(installer, tmp_path):
    """🔴 使用者加好的專案不可以被重裝洗掉。

    洗掉的樣子：執行器照常上線、儀表板上看得到它，但**一筆單都領不到**
    ——而安裝器從頭到尾顯示成功。
    """
    config = tmp_path / "runner" / "config.json"
    config.parent.mkdir(parents=True)
    original = '{"hub_url": "http://192.0.2.9:8787", "workspaces": {"a": {}}}\n'
    config.write_text(original, encoding="utf-8")

    wrote = installer.write_config(config, {"hub_url": "http://127.0.0.1:1"})

    assert wrote is False
    assert config.read_text(encoding="utf-8") == original


def test_config_is_written_when_there_is_none(installer, tmp_path):
    config = tmp_path / "runner" / "config.json"
    assert installer.write_config(config, {"hub_url": "http://127.0.0.1:1"})
    assert json.loads(config.read_text(encoding="utf-8"))["hub_url"] \
        == "http://127.0.0.1:1"
    # 沒有留下半個暫存檔——執行器會拿它當設定嗎？不會，但它是安裝失敗的證據
    assert not list(config.parent.glob("*.tmp"))


def test_generated_config_points_at_this_kit(installer, tmp_path):
    """產出的設定要指得到這一包，而且不留樣板裡那台機器的東西。"""
    example = json.loads(
        (REPO / "runner" / "config.example.json").read_text(encoding="utf-8"))
    kit = tmp_path / "kit"
    state = tmp_path / "state"

    cfg = installer.build_config(
        example, hub_url="http://192.0.2.10:8787", agent_token="tok",
        host="box", label="lab", kit_dir=kit, state_dir=state)

    assert cfg["hub_url"] == "http://192.0.2.10:8787"
    assert cfg["agent_token"] == "tok"
    assert cfg["host"] == "box" and cfg["label"] == "lab"
    # run.py 靠這個路徑把 chatroom MCP 掛給 claude
    assert cfg["bridge_path"] == str(kit / "bridge")
    assert cfg["state_dir"] == str(state)
    # 樣板指到 repo 的 server/.env，kit 形態下那個檔案不存在
    assert cfg["token_env_file"] == ""
    # 工作區要人自己加：安裝當下答不出專案路徑與允許分支
    assert cfg["workspaces"] == {}
    # 舊鍵不留在產出的設定裡（留著會變成「新舊同時存在」的警告）
    assert "projects" not in cfg
    # 樣板的說明鍵不進實際設定
    assert not [k for k in cfg if k.startswith("_")]
    # 其餘欄位沿用樣板，不重寫一份預設值
    assert cfg["backoff_minutes"] == example["backoff_minutes"]


def test_readme_and_installer_state_the_supported_agent(installer):
    """支援範圍要在 README 開頭與安裝器開頭各講一次。

    「我用 Codex，裝起來應該也能派工吧」是裝完才發現最貴的誤會。
    """
    readme = (KIT / "README.md").read_text(encoding="utf-8")
    head = readme.split("## ", 1)[0]
    assert "只支援 Claude Code" in head
    assert "Codex" in head
    assert "只支援 Claude Code" in installer.DISCLAIMER
    assert "Codex" in installer.DISCLAIMER


def test_login_hint_follows_the_existing_config(installer, tmp_path):
    """設定檔沒被覆寫時，登入指令要指到**它**寫的 `claude_config_dir`。

    照安裝器自己的預設算一個路徑出來的話，人會登入到一個執行器不看的目錄，
    然後對著「已登入卻還是派不了工」發呆。
    """
    config = tmp_path / "state" / "config.json"
    config.parent.mkdir(parents=True)
    elsewhere = tmp_path / "別的地方" / "claude-config"
    config.write_text(json.dumps({"claude_config_dir": str(elsewhere)}),
                      encoding="utf-8")

    assert installer.claude_config_dir_for(config) == elsewhere
    hint = installer.login_hint(elsewhere)
    assert str(elsewhere) in hint and "CLAUDE_CONFIG_DIR" in hint
    assert "claude auth login" in hint
    # 沒有設定檔時退回 <state_dir>/claude-config
    assert installer.claude_config_dir_for(tmp_path / "無" / "config.json") \
        == tmp_path / "無" / "claude-config"


def test_login_detection_defaults_to_requiring_login(installer, tmp_path):
    """偵測不到憑證就當成「還沒登入」——不確定要落在安全的那一邊。"""
    empty = tmp_path / "claude-config"
    empty.mkdir()
    assert installer.has_claude_login(empty) is False
    assert installer.has_claude_login(tmp_path / "根本沒有") is False

    (empty / ".credentials.json").write_text(
        '{"claudeAiOauth":{"accessToken":"x"}}', encoding="utf-8")
    assert installer.has_claude_login(empty) is True


def test_registry_shape_is_the_contract_with_the_app(installer, tmp_path):
    """欄位改名＝App 當成「這台沒裝執行器」，而一切看起來都成功。"""
    kit = tmp_path / "kit"
    python = kit / ".venv" / "Scripts" / "python.exe"
    config = tmp_path / "runner" / "config.json"

    installer.write_registry(kit, python, config)
    data = json.loads(installer.REGISTRY.read_text(encoding="utf-8"))

    # 這四個是 App 現在讀的欄位，**一個都不能改名或消失**（多幾個是可以的：
    # 版本欄位是後來補的，App 讀不懂的鍵會被忽略）
    assert {"kit_dir", "python", "config", "installed_at"} <= set(data)
    assert data["kit_dir"] == str(kit)
    assert data["python"] == str(python)
    assert data["config"] == str(config)
    assert data["installed_at"].endswith("+00:00")


def test_staging_copies_the_kit_without_the_venv(installer, tmp_path,
                                                 monkeypatch):
    """搬包時不可以把 `.venv` 一起搬——裡面是絕對路徑，搬過去就是壞的。"""
    src = tmp_path / "src"
    (src / "runner" / "chatroom_runner").mkdir(parents=True)
    (src / "bridge" / "chatroom_mcp").mkdir(parents=True)
    (src / "runner" / "chatroom_runner" / "loop.py").write_text("x")
    (src / "bridge" / "chatroom_mcp" / "server.py").write_text("x")
    (src / "install.py").write_text("x")
    (src / "README.md").write_text("x")
    (src / ".venv").mkdir()
    (src / ".venv" / "pyvenv.cfg").write_text("x")
    monkeypatch.setattr(installer, "KIT", src)

    target = tmp_path / "dest"
    installer.stage_kit(target)

    assert (target / "runner" / "chatroom_runner" / "loop.py").exists()
    assert (target / "bridge" / "chatroom_mcp" / "server.py").exists()
    assert not (target / ".venv").exists()


def test_staging_a_broken_package_fails_loudly(installer, tmp_path,
                                               monkeypatch):
    """少了 runner/ 或 bridge/ 的解壓結果要當場喊，不要裝出半台執行器。"""
    src = tmp_path / "src"
    (src / "runner").mkdir(parents=True)
    monkeypatch.setattr(installer, "KIT", src)
    with pytest.raises(SystemExit):
        installer.stage_kit(tmp_path / "dest")
