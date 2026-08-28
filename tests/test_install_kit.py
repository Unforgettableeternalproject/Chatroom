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


def test_env_file_has_watcher_values_and_no_session_key(inst, kit_dir):
    path = inst.write_env_file("http://hub:8787", "TOK", "claude", "諾薇亞")
    assert path == kit_dir / ".env"
    lines = path.read_text(encoding="utf-8").splitlines()
    values = dict(
        line.split("=", 1) for line in lines if line and not line.startswith("#")
    )
    assert values == {
        "CHATROOM_URL": "http://hub:8787",
        "CHATROOM_AGENT_KIND": "claude",
        "CHATROOM_DEFAULT_NAME": "諾薇亞",
        "CHATROOM_TOKEN": "TOK",
    }
    # 固定 session key 會讓多個 session 合併成同一個聊天室身分——絕不能寫
    assert "CHATROOM_SESSION_KEY" not in values


def test_env_file_backs_up_only_on_change(inst, kit_dir):
    inst.write_env_file("http://hub:8787", "TOK", "claude", "諾薇亞")
    inst.write_env_file("http://hub:8787", "TOK", "claude", "諾薇亞")
    assert not list(kit_dir.glob(".env.bak-*"))
    inst.write_env_file("http://hub2:8787", "TOK", "claude", "諾薇亞")
    assert list(kit_dir.glob(".env.bak-*"))
    assert "CHATROOM_URL=http://hub2:8787" in (kit_dir / ".env").read_text(encoding="utf-8")


def test_env_file_is_where_the_watcher_looks(inst, kit_dir, monkeypatch):
    """關鍵的一項：寫出來的位置必須正好是 envfile 載入器的搜尋候選。

    kit 解壓後的版面是 kit/{.env, bridge/chatroom_mcp/}，而 load_env_file 的候選
    清單裡有「bridge 套件的上一層」——兩者要對得起來，`.env` 才會被 watcher 讀到。
    """
    from chatroom_mcp.envfile import load_env_file

    expected = inst.write_env_file("http://hub:8787", "TOK", "claude", "諾薇亞")
    for key in ("CHATROOM_URL", "CHATROOM_TOKEN", "CHATROOM_AGENT_KIND",
                "CHATROOM_DEFAULT_NAME"):
        monkeypatch.delenv(key, raising=False)

    watcher_dir = kit_dir / "bridge" / "chatroom_mcp"
    watcher_dir.mkdir(parents=True)
    assert load_env_file(start=watcher_dir) == expected
    # kind 沒補上的話 session_key() 不會採用 CLAUDE_CODE_SESSION_ID，
    # watcher 就會拿到一把與 bridge 不同的隨機身分
    assert os.environ["CHATROOM_AGENT_KIND"] == "claude"
