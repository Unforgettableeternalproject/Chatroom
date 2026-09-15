"""換 token 的回歸測試。

這支腳本改的是 Hub 起不起得來的那個檔案，所以它的失敗代價不對稱：
換不成功只是白做一次，**換壞了則是 Hub 起不來**。這裡守的幾條都指向
後者——寫壞、清空、把別的設定一起弄丟。
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
ROTATE_PY = REPO / "scripts" / "rotate-token.py"


def load_rotate():
    spec = importlib.util.spec_from_file_location("chatroom_rotate", ROTATE_PY)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["chatroom_rotate"] = module
    spec.loader.exec_module(module)
    return module


def make_env(tmp_path: Path, text: str) -> Path:
    server = tmp_path / "server"
    server.mkdir(exist_ok=True)
    env_file = server / ".env"
    env_file.write_text(text, encoding="utf-8")
    return env_file


def test_only_the_token_line_changes(tmp_path: Path):
    """其他設定與註解一個字都不能動。

    這條紅起來的樣子最惡劣：token 換好了、Hub 起不來，因為 port 或
    附件目錄在重寫的過程中消失了。
    """
    rotate = load_rotate()
    env_file = make_env(
        tmp_path,
        "# Chatroom Hub 設定\n"
        "CHATROOM_HOST=26.176.231.43\n"
        "CHATROOM_PORT=8787\n"
        "CHATROOM_TOKEN=old-token\n"
        "CHATROOM_PURGE_DAYS=15\n",
    )

    result = rotate.rotate(repo=tmp_path)
    after = env_file.read_text(encoding="utf-8").splitlines()

    assert after[0] == "# Chatroom Hub 設定"
    assert after[1] == "CHATROOM_HOST=26.176.231.43"
    assert after[2] == "CHATROOM_PORT=8787"
    assert after[3] == f"CHATROOM_TOKEN={result['token']}"
    assert after[4] == "CHATROOM_PURGE_DAYS=15"


def test_old_env_is_backed_up(tmp_path: Path):
    """舊 token 是隨機字串，沒備份就回不去了。"""
    rotate = load_rotate()
    make_env(tmp_path, "CHATROOM_TOKEN=the-old-one\n")

    result = rotate.rotate(repo=tmp_path)
    backup = Path(str(result["backup"]))

    assert backup.read_text(encoding="utf-8") == "CHATROOM_TOKEN=the-old-one\n"
    assert result["had_previous"] is True


def test_missing_token_line_is_appended_not_silently_dropped(tmp_path: Path):
    """原本沒有 TOKEN 行時要補上，不能什麼都沒做卻回報成功。"""
    rotate = load_rotate()
    env_file = make_env(tmp_path, "CHATROOM_PORT=8787\n")

    result = rotate.rotate(repo=tmp_path)
    text = env_file.read_text(encoding="utf-8")

    assert "CHATROOM_PORT=8787" in text
    assert f"CHATROOM_TOKEN={result['token']}" in text
    assert result["had_previous"] is False


def test_appending_works_when_file_has_no_trailing_newline(tmp_path: Path):
    """檔尾沒有換行時補上的那行不可以黏在前一行後面。

    黏起來的結果是 `CHATROOM_PORT=8787CHATROOM_TOKEN=...`——兩個設定
    同時失效，而檔案看起來還是有內容的。
    """
    rotate = load_rotate()
    env_file = make_env(tmp_path, "CHATROOM_PORT=8787")

    result = rotate.rotate(repo=tmp_path)
    lines = env_file.read_text(encoding="utf-8").splitlines()

    assert lines == ["CHATROOM_PORT=8787", f"CHATROOM_TOKEN={result['token']}"]


def test_token_with_surrounding_space_is_rejected(tmp_path: Path):
    """帶空白的 token 寫進去讀回來會不一樣，寧可擋在這裡。"""
    rotate = load_rotate()
    make_env(tmp_path, "CHATROOM_TOKEN=old\n")

    with pytest.raises(ValueError):
        rotate.rotate(token="  spaced  ", repo=tmp_path)


def test_empty_token_is_rejected(tmp_path: Path):
    """空 token 等於把 Hub 對所有人敞開。"""
    rotate = load_rotate()
    make_env(tmp_path, "CHATROOM_TOKEN=old\n")

    with pytest.raises(ValueError):
        rotate.rotate(token="   ", repo=tmp_path)


def test_env_is_never_left_truncated(tmp_path: Path):
    """換完的 .env 不可以是空的——先截斷再寫的那種寫法會留下 0 位元組。"""
    rotate = load_rotate()
    env_file = make_env(tmp_path, "CHATROOM_TOKEN=old\nCHATROOM_PORT=1\n")

    rotate.rotate(repo=tmp_path)

    assert env_file.stat().st_size > 0
    assert "CHATROOM_PORT=1" in env_file.read_text(encoding="utf-8")


def test_generated_tokens_are_distinct(tmp_path: Path):
    """兩次換出同一把 token 等於沒換。"""
    rotate = load_rotate()
    assert rotate.generate_token() != rotate.generate_token()


def test_missing_env_fails_loudly(tmp_path: Path):
    """沒有 .env 時不可以憑空生一個——那會少掉所有其他設定。"""
    rotate = load_rotate()
    (tmp_path / "server").mkdir()

    with pytest.raises(FileNotFoundError):
        rotate.rotate(repo=tmp_path)


def test_human_flag_rotates_only_the_human_key(tmp_path: Path):
    """🔴 換人類那把時，agent 那把一個字都不能動。

    這條紅起來的樣子：主持人想換自己的鑰匙，結果所有 agent 一起斷線
    ——而他完全不會預期那件事。反過來同樣成立。
    """
    rotate = load_rotate()
    env_file = make_env(
        tmp_path,
        "CHATROOM_TOKEN=agent-key\nCHATROOM_HUMAN_TOKEN=human-key\n")

    result = rotate.rotate(repo=tmp_path, key=rotate.HUMAN_KEY)
    text = env_file.read_text(encoding="utf-8")

    assert "CHATROOM_TOKEN=agent-key" in text, "agent 那把被動到了"
    assert f"CHATROOM_HUMAN_TOKEN={result['token']}" in text
    assert result["audience"] == "human"


def test_default_rotates_the_agent_key_only(tmp_path: Path):
    rotate = load_rotate()
    env_file = make_env(
        tmp_path,
        "CHATROOM_TOKEN=agent-key\nCHATROOM_HUMAN_TOKEN=human-key\n")

    result = rotate.rotate(repo=tmp_path)
    text = env_file.read_text(encoding="utf-8")

    assert "CHATROOM_HUMAN_TOKEN=human-key" in text, "人類那把被動到了"
    assert f"CHATROOM_TOKEN={result['token']}" in text
    assert result["audience"] == "agent"


def test_result_says_which_key_it_changed(tmp_path: Path):
    """只回 token 的話，呼叫端分不出這一串是誰的鑰匙——而發錯對象的
    後果是把主持人的權力交出去。"""
    rotate = load_rotate()
    make_env(tmp_path, "CHATROOM_TOKEN=old\n")

    result = rotate.rotate(repo=tmp_path)

    assert result["key"] == "CHATROOM_TOKEN"
    assert result["audience"] == "agent"
