"""`CHATROOM_ENV_FILE`：連線資訊的單一真相（2026-09-12，艾斯維爾提）。

安裝器原本把 token 寫兩個地方——MCP client 設定的 `env`，以及 kit 根目錄的
`.env`（watcher 是獨立進程，拿不到前者）。換一次 token 要改兩處，而漏改一處
的症狀是「看起來換好了、實際還在用舊的」。

根因：bridge 進程的 cwd 是**使用者自己的專案目錄**，往上搜尋找不到 kit 的
`.env`。所以 MCP 設定改成只放一個指向那個檔的路徑。
"""

from __future__ import annotations

import os

import pytest

from chatroom_mcp.envfile import load_env_file


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    for key in ("CHATROOM_ENV_FILE", "CHATROOM_URL", "CHATROOM_TOKEN",
                "CHATROOM_HUMAN_TOKEN"):
        monkeypatch.delenv(key, raising=False)


def test_the_pinned_file_is_used_even_from_an_unrelated_cwd(tmp_path,
                                                            monkeypatch):
    """重點就是這個：bridge 的 cwd 在使用者的專案裡，搜尋是找不到的。"""
    kit = tmp_path / "kit"
    kit.mkdir()
    (kit / ".env").write_text(
        "CHATROOM_URL=http://hub:8787\nCHATROOM_TOKEN=TOK\n", encoding="utf-8")
    elsewhere = tmp_path / "somebody" / "project"
    elsewhere.mkdir(parents=True)

    monkeypatch.setenv("CHATROOM_ENV_FILE", str(kit / ".env"))
    assert load_env_file(start=elsewhere) == kit / ".env"
    assert os.environ["CHATROOM_TOKEN"] == "TOK"


def test_a_pinned_file_that_does_not_exist_reads_nothing(tmp_path,
                                                         monkeypatch):
    """指到不存在的檔就是沒有設定——**不要默默退回搜尋**。

    退回去的話，路徑打錯的人會連到「剛好在附近的某個 .env」所描述的 Hub，
    而那與他打算連的不是同一台。一個明確的「沒有」比一個安靜的「別的」好。
    """
    monkeypatch.setenv("CHATROOM_ENV_FILE", str(tmp_path / "沒有這個檔"))
    (tmp_path / ".env").write_text("CHATROOM_URL=http://別台\n",
                                   encoding="utf-8")
    assert load_env_file(start=tmp_path) is None
    assert "CHATROOM_URL" not in os.environ


def test_the_pinned_file_still_goes_through_the_whitelist(tmp_path,
                                                          monkeypatch):
    """🚨 指定的檔案也套 `_BRIDGE_KEYS`。

    這個值是設定檔裡的一個字串，指到 Hub 的 `server/.env` 是很自然的一個
    誤設——而那份裡面有 `CHATROOM_HUMAN_TOKEN`（人類憑證）。整份灌進來的話，
    每個 agent 的環境裡都躺著一把它不該有的鑰匙。Hub 那三道閘擋得住冒充，
    擋不住「client 自己手上就有」。
    """
    env = tmp_path / ".env"
    env.write_text(
        "CHATROOM_URL=http://hub:8787\n"
        "CHATROOM_TOKEN=agent-tok\n"
        "CHATROOM_HUMAN_TOKEN=人類憑證\n"
        "CHATROOM_DB_PATH=/hub/chatroom.db\n",
        encoding="utf-8")

    monkeypatch.setenv("CHATROOM_ENV_FILE", str(env))
    load_env_file(start=tmp_path)

    assert os.environ["CHATROOM_TOKEN"] == "agent-tok"
    assert "CHATROOM_HUMAN_TOKEN" not in os.environ
    assert "CHATROOM_DB_PATH" not in os.environ


def test_real_environment_still_wins(tmp_path, monkeypatch):
    """載入器一貫的規則：只補缺、不覆寫。指定檔案不改變這件事。"""
    env = tmp_path / ".env"
    env.write_text("CHATROOM_TOKEN=檔案裡的\n", encoding="utf-8")
    monkeypatch.setenv("CHATROOM_ENV_FILE", str(env))
    monkeypatch.setenv("CHATROOM_TOKEN", "環境裡的")

    load_env_file(start=tmp_path)
    assert os.environ["CHATROOM_TOKEN"] == "環境裡的"
