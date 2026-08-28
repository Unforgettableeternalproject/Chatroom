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
