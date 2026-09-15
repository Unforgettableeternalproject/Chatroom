"""P3 追加：.env 載入器——只補缺不覆寫、解析規則。"""

import os

from chatroom_mcp.envfile import load_env_file


def test_loads_missing_keys_only(tmp_path, monkeypatch):
    monkeypatch.setenv("ENVFILE_EXISTING", "來自真實環境")
    monkeypatch.delenv("ENVFILE_NEW", raising=False)
    (tmp_path / ".env").write_text(
        "ENVFILE_EXISTING=來自檔案\nENVFILE_NEW=補進來\n", encoding="utf-8"
    )

    used = load_env_file(tmp_path)

    assert used == tmp_path / ".env"
    # 真實環境變數優先，.env 不可覆寫
    assert os.environ["ENVFILE_EXISTING"] == "來自真實環境"
    assert os.environ["ENVFILE_NEW"] == "補進來"


def test_parses_comments_blanks_and_quotes(tmp_path, monkeypatch):
    monkeypatch.delenv("ENVFILE_QUOTED", raising=False)
    monkeypatch.delenv("ENVFILE_PLAIN", raising=False)
    (tmp_path / ".env").write_text(
        "# 註解行\n\nENVFILE_QUOTED=\"帶引號的值\"\nENVFILE_PLAIN = 前後有空白 \n沒有等號的行\n",
        encoding="utf-8",
    )

    load_env_file(tmp_path)

    assert os.environ["ENVFILE_QUOTED"] == "帶引號的值"
    assert os.environ["ENVFILE_PLAIN"] == "前後有空白"


def test_searches_upward(tmp_path, monkeypatch):
    monkeypatch.delenv("ENVFILE_UPWARD", raising=False)
    (tmp_path / ".env").write_text("ENVFILE_UPWARD=在上層\n", encoding="utf-8")
    nested = tmp_path / "a" / "b"
    nested.mkdir(parents=True)

    used = load_env_file(nested)

    assert used == tmp_path / ".env"
    assert os.environ["ENVFILE_UPWARD"] == "在上層"


def test_the_hubs_env_only_lends_the_bridge_what_it_needs(tmp_path, monkeypatch):
    """Hub 的 `server/.env` 是**Hub 的**設定，不是 bridge 的。

    2026-09-07 起它裡面有 `CHATROOM_HUMAN_TOKEN`——人類憑證，Hub 的三道閘
    （`role=human`／主持人視角／發放邀請）只認它。整份灌進 bridge 進程的話，
    每一個 agent 的環境裡都躺著一把它不該有的鑰匙：那三道閘擋得住冒充，擋不住
    「client 自己手上就有」。

    ⚠️ 實測過 bridge **沒有**拿它當 Authorization，但「沒有被用」不等於
    「不在」，而這條測試收的是後者。
    """
    from chatroom_mcp import envfile

    repo = tmp_path / "repo"
    (repo / "server").mkdir(parents=True)
    (repo / "bridge" / "chatroom_mcp").mkdir(parents=True)
    (repo / "server" / ".env").write_text(
        "CHATROOM_TOKEN=agent-key\n"
        "CHATROOM_HUMAN_TOKEN=human-key\n"
        "CHATROOM_DB=hub.db\n", encoding="utf-8")
    monkeypatch.setattr(envfile, "__file__",
                        str(repo / "bridge" / "chatroom_mcp" / "envfile.py"))
    for k in ("CHATROOM_TOKEN", "CHATROOM_HUMAN_TOKEN", "CHATROOM_DB"):
        monkeypatch.delenv(k, raising=False)

    # cwd 那條路上沒有 .env，所以會一路走到 repo_root/server
    used = envfile.load_env_file(tmp_path / "elsewhere")
    assert used == repo / "server" / ".env"
    assert os.environ["CHATROOM_TOKEN"] == "agent-key"
    assert "CHATROOM_HUMAN_TOKEN" not in os.environ
    # Hub 專屬的其他設定同樣不該進來——白名單是列舉的，不是「擋掉那一個」
    assert "CHATROOM_DB" not in os.environ
