"""備份腳本的回歸測試。

這裡守的每一條都屬於「備份看起來成功了，還原時才發現少東西」——
備份是那種平常沒人驗、要用的時候才知道好不好的功能，所以它的失敗
一律是靜默的（`docs/FAILURE-PATTERNS.md` 的共通形狀）。

最重要的一條是 WAL：直接複製 `chatroom.db` 會拿到一個**開得起來**但
缺了最近訊息的檔案。那正是備份最不該有的失敗方式。
"""

from __future__ import annotations

import importlib.util
import json
import sqlite3
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
BACKUP_PY = REPO / "scripts" / "backup.py"


def load_backup():
    spec = importlib.util.spec_from_file_location("chatroom_backup", BACKUP_PY)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["chatroom_backup"] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def fake_kit(tmp_path: Path):
    """一個最小的 kit：server/.env + WAL 模式的 db + 一個附件。"""
    server = tmp_path / "server"
    server.mkdir()
    (server / ".env").write_text(
        "# 註解要被略過\nCHATROOM_HOST=127.0.0.1\nCHATROOM_PORT=8787\n"
        "CHATROOM_TOKEN=abc=def\n",
        encoding="utf-8",
    )

    db = server / "chatroom.db"
    conn = sqlite3.connect(db)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("CREATE TABLE message (id INTEGER PRIMARY KEY, body TEXT)")
    conn.execute("INSERT INTO message (body) VALUES ('第一則')")
    conn.commit()
    # 刻意不 close、不 checkpoint——讓資料留在 WAL 裡，這正是「複製 .db
    # 會漏掉」的那個狀態
    attachments = server / "attachments"
    attachments.mkdir()
    (attachments / "ab").mkdir()
    (attachments / "ab" / "abcdef").write_bytes(b"\x89PNG fake")

    yield tmp_path, conn, db
    conn.close()


def test_wal_committed_rows_are_in_the_backup(fake_kit):
    """WAL 裡已提交但還沒 checkpoint 的資料必須進備份。

    這條紅起來的樣子是：備份的 db 開得起來、表也在，就是少了最後幾則訊息。
    """
    root, conn, _ = fake_kit
    backup = load_backup()

    # 再寫一筆，同樣不 checkpoint
    conn.execute("INSERT INTO message (body) VALUES ('WAL 裡的那則')")
    conn.commit()

    result = backup.backup(out_root=root / "backups", repo=root)
    copied = sqlite3.connect(Path(str(result["dest"])) / "chatroom.db")
    try:
        bodies = [r[0] for r in copied.execute("SELECT body FROM message")]
    finally:
        copied.close()

    assert bodies == ["第一則", "WAL 裡的那則"]


def test_attachments_are_copied_with_the_db(fake_kit):
    """db 與 attachments/ 是兩份東西，只有兩份都在才算備份成功。

    少了附件的備份還原後訊息都在、圖全變 410——而那時原件已經沒了。
    """
    root, _, _ = fake_kit
    backup = load_backup()

    result = backup.backup(out_root=root / "backups", repo=root)
    dest = Path(str(result["dest"]))

    assert (dest / "attachments" / "ab" / "abcdef").read_bytes() == b"\x89PNG fake"
    assert result["attachment_files"] == 1
    assert result["attachments_existed"] is True


def test_missing_attachments_dir_is_recorded_not_silently_skipped(tmp_path: Path):
    """來源沒有 attachments/ 時，備份要**講出來**而不是靜靜成功。

    「0 個附件」與「沒有備份附件」在磁碟上長得一模一樣，還原時的意義
    卻完全相反——所以判準必須寫進 manifest，不能靠事後推論。
    """
    server = tmp_path / "server"
    server.mkdir()
    conn = sqlite3.connect(server / "chatroom.db")
    conn.execute("CREATE TABLE t (x INTEGER)")
    conn.commit()
    conn.close()

    backup = load_backup()
    result = backup.backup(out_root=tmp_path / "backups", repo=tmp_path)
    dest = Path(str(result["dest"]))

    assert result["attachments_existed"] is False
    assert not (dest / "attachments").exists()
    manifest = json.loads((dest / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["attachments_existed"] is False


def test_env_value_may_contain_equals(tmp_path: Path):
    """token 這種值裡會有 `=`，只能切第一個——與 App 端的解析一致。"""
    backup = load_backup()
    env_file = tmp_path / ".env"
    env_file.write_text("CHATROOM_TOKEN=ab=cd=\n#註解\n\nCHATROOM_PORT=9\n",
                        encoding="utf-8")
    values = backup.load_env(env_file)
    assert values == {"CHATROOM_TOKEN": "ab=cd=", "CHATROOM_PORT": "9"}


def test_custom_attachment_dir_is_honoured(tmp_path: Path):
    """`CHATROOM_ATTACHMENT_DIR` 指到別處時要跟著走。

    沒跟著走的話備份的是一個空的預設目錄，而**備份仍然成功**——
    這是這支腳本最容易長出來的假綠燈。
    """
    server = tmp_path / "server"
    server.mkdir()
    elsewhere = tmp_path / "somewhere-else"
    elsewhere.mkdir()
    (elsewhere / "blob").write_bytes(b"x" * 10)
    (server / ".env").write_text(
        f"CHATROOM_ATTACHMENT_DIR={elsewhere}\n", encoding="utf-8"
    )
    conn = sqlite3.connect(server / "chatroom.db")
    conn.execute("CREATE TABLE t (x INTEGER)")
    conn.commit()
    conn.close()

    backup = load_backup()
    result = backup.backup(out_root=tmp_path / "backups", repo=tmp_path)
    dest = Path(str(result["dest"]))
    assert (dest / "attachments" / "blob").read_bytes() == b"x" * 10


def test_missing_db_fails_loudly(tmp_path: Path):
    """沒有 db 就不能產生一個「只有附件」的備份目錄冒充成功。"""
    (tmp_path / "server").mkdir()
    backup = load_backup()
    with pytest.raises(FileNotFoundError):
        backup.backup(out_root=tmp_path / "backups", repo=tmp_path)
