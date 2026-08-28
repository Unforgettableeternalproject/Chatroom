"""install-kit 安裝器的回歸測試。

這裡守的兩個行為都屬於「安裝器全程顯示成功、實際裝出壞環境」——不會拋例外、
不會有紅字，只有等到 agent 收不到通知時才會發現。安裝器過去沒有任何測試覆蓋，
正是這兩個缺陷能活下來的原因（2026-08-29 由另一台機器實裝時回報）：

1. ``setup_codex`` 遇到既有 ``[mcp_servers.chatroom]`` 只印警告就 return，
   換機重裝時舊機器的路徑會原封不動留著。
2. ``install.py`` 不產生 watcher 需要的 kit 根目錄 ``.env``，watcher 於是退回
   隨機身分，與 bridge 分裂成兩個 session，一個事件都不發。

install.py 只用標準庫且不在 import 時做任何事，可直接載入來測；建 venv 與
安裝 bridge 的部分不在此涵蓋（需要網路）。
"""

from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tomllib
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
INSTALL_PY = REPO / "install-kit" / "install.py"


@pytest.fixture(scope="module")
def inst():
    spec = importlib.util.spec_from_file_location("install_kit_installer", INSTALL_PY)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


EXISTING_CONFIG = """\
[model]
name = "gpt-5"

[mcp_servers.chatroom]
command = 'C:\\舊機器\\不存在\\chatroom-mcp.exe'
args = []
enabled = false

[mcp_servers.chatroom.env]
CHATROOM_URL = "http://old-hub"

[mcp_servers.other]
command = 'other'
"""

EXE = Path("C:/新機器/kit/venv/Scripts/chatroom-mcp.exe")


# ---------- strip_codex_block ----------


def test_strip_removes_table_and_subtables(inst):
    remainder, removed = inst.strip_codex_block(EXISTING_CONFIG)
    assert removed
    assert "chatroom" not in remainder
    assert "[model]" in remainder and "[mcp_servers.other]" in remainder


def test_strip_is_noop_without_block(inst):
    text = "[model]\nname = 'x'\n"
    assert inst.strip_codex_block(text) == (text, False)


def test_strip_does_not_touch_prefix_collision(inst):
    """``chatroom_backup`` 不是 ``chatroom`` 的子表，不可被連坐刪除。"""
    text = "[mcp_servers.chatroom_backup]\na = 1\n"
    assert inst.strip_codex_block(text) == (text, False)


# ---------- setup_codex ----------


def test_setup_codex_rewrites_stale_block(inst, tmp_path, capsys):
    """換機重裝：舊機器的路徑必須被換掉，而不是只印個警告就跳過。"""
    cfg = tmp_path / ".codex" / "config.toml"
    cfg.parent.mkdir(parents=True)
    cfg.write_text(EXISTING_CONFIG, encoding="utf-8")

    inst.setup_codex(EXE, "http://hub:8787", "TOK", "諾薇亞", cfg)

    data = tomllib.loads(cfg.read_text(encoding="utf-8"))
    chatroom = data["mcp_servers"]["chatroom"]
    assert chatroom["command"] == str(EXE)
    assert chatroom["args"] == []
    assert "enabled" not in chatroom  # 舊機器留下的 enabled = false 必須消失
    assert chatroom["env"] == {
        "CHATROOM_URL": "http://hub:8787",
        "CHATROOM_AGENT_KIND": "codex",
        "CHATROOM_DEFAULT_NAME": "諾薇亞",
        "CHATROOM_TOKEN": "TOK",
    }
    # 別人的設定不能被波及
    assert data["model"]["name"] == "gpt-5"
    assert data["mcp_servers"]["other"]["command"] == "other"
    assert any(p.name.startswith("config.toml.bak-") for p in cfg.parent.iterdir())


def test_setup_codex_is_idempotent(inst, tmp_path):
    cfg = tmp_path / "config.toml"
    cfg.write_text(EXISTING_CONFIG, encoding="utf-8")
    inst.setup_codex(EXE, "http://hub:8787", "TOK", "諾薇亞", cfg)
    once = cfg.read_text(encoding="utf-8")
    inst.setup_codex(EXE, "http://hub:8787", "TOK", "諾薇亞", cfg)
    assert cfg.read_text(encoding="utf-8") == once
    assert once.count("[mcp_servers.chatroom]") == 1


def test_setup_codex_creates_missing_config(inst, tmp_path):
    cfg = tmp_path / "fresh" / "config.toml"
    inst.setup_codex(EXE, "http://hub:8787", "", "諾薇亞", cfg)
    chatroom = tomllib.loads(cfg.read_text(encoding="utf-8"))["mcp_servers"]["chatroom"]
    assert "CHATROOM_TOKEN" not in chatroom["env"]  # 無 token 時不寫空值
    assert not any(p.name.startswith("config.toml.bak-") for p in cfg.parent.iterdir())


# ---------- write_env_file ----------


@pytest.fixture
def kit_dir(inst, tmp_path, monkeypatch):
    monkeypatch.setattr(inst, "KIT_DIR", tmp_path)
    return tmp_path


def _env_values(path: Path) -> dict[str, str]:
    return dict(
        line.split("=", 1)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line and not line.startswith("#")
    )


def test_env_file_carries_connection_info_only(inst, kit_dir):
    """.env 只放跨 agent 共用的連線資訊，身分相關的值一律不寫。

    ``CHATROOM_AGENT_KIND`` 寫進共用檔就得在 claude 與 codex 之間二選一：填
    claude 時，同機用 ``--codex-thread`` 跑的 Codex watcher 會沿用
    ``CLAUDE_CODE_SESSION_ID``，與母 Claude session 撞成同一個 participant
    ——正是 identity.session_key 的註解要防的事（2026-08-29 實測複現）。
    """
    path = inst.write_env_file("http://hub:8787", "TOK")
    assert path == kit_dir / ".env"
    assert _env_values(path) == {
        "CHATROOM_URL": "http://hub:8787",
        "CHATROOM_TOKEN": "TOK",
    }


def test_env_file_omits_empty_token(inst, kit_dir):
    assert "CHATROOM_TOKEN" not in _env_values(inst.write_env_file("http://hub:8787", ""))


def test_env_file_warns_when_removing_legacy_identity_values(inst, kit_dir, capsys):
    """舊版的 .env 是那些機器唯一的 kind 來源，拿掉它必須明講。

    使用者若沒同時把 --kind 補進 Monitor 指令，watcher 會退回隨機身分——
    而舊版沒有 kind=other 警告，斷了也不會有人知道。
    """
    (kit_dir / ".env").write_text(
        "CHATROOM_URL=http://old\nCHATROOM_AGENT_KIND=claude\n"
        "CHATROOM_DEFAULT_NAME=諾薇亞\n",
        encoding="utf-8",
    )
    inst.write_env_file("http://hub:8787", "TOK")
    out = capsys.readouterr().out
    assert "CHATROOM_AGENT_KIND" in out and "--kind" in out
    assert list(kit_dir.glob(".env.bak-*"))  # 舊值還原得回來


def test_env_file_stays_quiet_for_fresh_install(inst, kit_dir, capsys):
    """全新安裝沒有遷移問題，不該印那段警告變成人人略過的雜訊。"""
    inst.write_env_file("http://hub:8787", "TOK")
    assert "--kind" not in capsys.readouterr().out


def test_env_file_backs_up_only_on_change(inst, kit_dir):
    inst.write_env_file("http://hub:8787", "TOK")
    inst.write_env_file("http://hub:8787", "TOK")
    assert not list(kit_dir.glob(".env.bak-*"))
    inst.write_env_file("http://hub2:8787", "TOK")
    assert list(kit_dir.glob(".env.bak-*"))
    assert _env_values(kit_dir / ".env")["CHATROOM_URL"] == "http://hub2:8787"


def test_env_file_is_where_the_watcher_looks(inst, kit_dir, monkeypatch):
    """關鍵的一項：寫出來的位置必須正好是 envfile 載入器的搜尋候選。

    kit 解壓後的版面是 kit/{.env, bridge/chatroom_mcp/}，而 load_env_file 的候選
    清單裡有「bridge 套件的上一層」——兩者要對得起來，`.env` 才會被 watcher 讀到。
    """
    from chatroom_mcp.envfile import load_env_file

    expected = inst.write_env_file("http://hub:8787", "TOK")
    for key in ("CHATROOM_URL", "CHATROOM_TOKEN"):
        monkeypatch.delenv(key, raising=False)

    watcher_dir = kit_dir / "bridge" / "chatroom_mcp"
    watcher_dir.mkdir(parents=True)
    assert load_env_file(start=watcher_dir) == expected
    assert os.environ["CHATROOM_URL"] == "http://hub:8787"


# ---------- pip 中斷後的殘骸還原 ----------


def test_restores_leftovers_when_new_version_missing(inst, tmp_path):
    """pip 沒回滾時，venv 裡會完全不存在 chatroom_mcp。

    當下毫無症狀（bridge 進程已把模組載入記憶體），下次重啟 agent 才炸
    ModuleNotFoundError——那時沒人會聯想到幾天前那次失敗的安裝。
    """
    (tmp_path / "~hatroom_mcp").mkdir()
    (tmp_path / "~hatroom_mcp" / "server.py").write_text("x", encoding="utf-8")
    (tmp_path / "~hatroom_mcp-0.1.0.dist-info").mkdir()

    restored = inst.restore_pip_leftovers(tmp_path)

    assert sorted(restored) == ["chatroom_mcp", "chatroom_mcp-0.1.0.dist-info"]
    assert (tmp_path / "chatroom_mcp" / "server.py").is_file()
    assert not list(tmp_path.glob("~*"))


def test_discards_leftovers_when_new_version_landed(inst, tmp_path):
    """新版已就位時殘骸只是垃圾——還原回去會蓋掉新版。"""
    (tmp_path / "~hatroom_mcp").mkdir()
    (tmp_path / "chatroom_mcp").mkdir()
    (tmp_path / "chatroom_mcp" / "new.py").write_text("new", encoding="utf-8")

    assert inst.restore_pip_leftovers(tmp_path) == []
    assert (tmp_path / "chatroom_mcp" / "new.py").is_file()
    assert not list(tmp_path.glob("~*"))


def test_leaves_other_packages_leftovers_alone(inst, tmp_path):
    """只收拾自己的殘骸；別人的備份不歸這支安裝器管。"""
    (tmp_path / "~equests").mkdir()
    (tmp_path / "~ttpx-0.27.0.dist-info").mkdir()

    assert inst.restore_pip_leftovers(tmp_path) == []
    assert (tmp_path / "~equests").is_dir()
    assert (tmp_path / "~ttpx-0.27.0.dist-info").is_dir()


def test_no_leftovers_is_a_noop(inst, tmp_path):
    (tmp_path / "chatroom_mcp").mkdir()
    assert inst.restore_pip_leftovers(tmp_path) == []


def test_site_packages_resolves_for_a_real_interpreter(inst):
    """殘骸還原找不到 site-packages 就等於沒做——用真的直譯器驗一次。"""
    site = inst.site_packages(Path(sys.executable))
    assert site is not None and site.is_dir()


def test_locked_exe_failure_explains_the_real_cause(
    inst, tmp_path, capsys, monkeypatch
):
    """pip 的原始 OSError 看不出跟 agent 有關，使用者會往別的方向查。"""
    (tmp_path / "~hatroom_mcp").mkdir()
    monkeypatch.setattr(inst, "site_packages", lambda py: tmp_path)
    done = subprocess.CompletedProcess(
        args=[], returncode=1, stdout="",
        stderr="ERROR: Could not install packages due to an OSError: "
               "[WinError 32] 程序無法存取檔案，因為檔案正由另一個程序使用。",
    )

    with pytest.raises(SystemExit):
        inst._report_install_failure(
            done, Path(sys.executable), tmp_path / "chatroom-mcp.exe")

    out = capsys.readouterr().out
    assert "已還原" in out  # 先把 venv 修回可用，才談失敗原因
    assert "關閉" in out and "chatroom-mcp.exe" in out
    assert (tmp_path / "chatroom_mcp").is_dir()


# ---------- watcher 的身分旗標 ----------


@pytest.fixture
def clean_identity_env(monkeypatch):
    for key in ("CHATROOM_SESSION_KEY", "CHATROOM_AGENT_KIND",
                "CHATROOM_DEFAULT_NAME", "CLAUDE_CODE_SESSION_ID"):
        monkeypatch.delenv(key, raising=False)


def test_codex_watcher_does_not_collide_with_parent_claude_session(clean_identity_env):
    """從 Claude session 拉起的 Codex watcher 不可與母 session 撞 key。

    這是 ``.env`` 不能寫 ``CHATROOM_AGENT_KIND`` 的理由本身：kind 一旦被共用檔
    填成 claude，下面兩個 session_key 會完全相同，兩個 agent 合併成同一個
    participant，訊息混流。
    """
    from chatroom_mcp import identity

    os.environ["CLAUDE_CODE_SESSION_ID"] = "MOTHER"
    mother = identity.session_key("claude")
    codex = identity.session_key("codex")
    assert mother == "claude-MOTHER"
    assert codex != mother and codex.startswith("codex-")


def test_watch_kind_flag_overrides_env_file_value(clean_identity_env):
    """命令列的 --kind 要蓋得過 .env 補進來的值（顯式 > 檔案）。"""
    from chatroom_mcp import identity, watch

    os.environ["CHATROOM_AGENT_KIND"] = "claude"  # 模擬舊版 .env 留下的值
    os.environ["CLAUDE_CODE_SESSION_ID"] = "MOTHER"
    args = watch.build_parser().parse_args(["--kind", "codex", "--label", "諾薇亞"])
    # main() 在 load_env_file 之後套用旗標，這裡直接驗證那段語意
    os.environ["CHATROOM_AGENT_KIND"] = args.kind
    os.environ["CHATROOM_DEFAULT_NAME"] = args.label
    assert identity.agent_kind() == "codex"
    assert identity.session_key() != "claude-MOTHER"


def test_watch_rejects_unknown_kind():
    from chatroom_mcp import watch

    with pytest.raises(SystemExit):
        watch.build_parser().parse_args(["--kind", "gemini"])
