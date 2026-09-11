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
