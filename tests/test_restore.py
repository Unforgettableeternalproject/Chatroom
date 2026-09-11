"""還原的回歸測試。

還原是這個 kit 唯一會毀掉現有資料的操作，所以這裡守的每一條都是
「在毀掉之前停下來」，而不是「還原得成功」。

最要緊的是 Hub 還跑著那一條：SQLite 的檔案被換掉時，連著的進程仍握著舊的
handle，寫回去會蓋掉剛還原的東西——**而當下完全看不出來**，要到下次重啟
才發現還原沒有生效，那時人已經以為資料回來了。
"""

from __future__ import annotations

import importlib.util
import json
import socket
import sqlite3
import sys
import threading
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
RESTORE_PY = REPO / "scripts" / "restore.py"


def load_restore():
    spec = importlib.util.spec_from_file_location("chatroom_restore", RESTORE_PY)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["chatroom_restore"] = module
    spec.loader.exec_module(module)
    return module


def make_kit(tmp_path: Path, port: int = 0, rows: tuple[str, ...] = ("現況",)):
    """一個最小的 kit：server/.env + db + 一個附件。"""
    server = tmp_path / "server"
    server.mkdir(exist_ok=True)
    (server / ".env").write_text(
        f"CHATROOM_PORT={port}\nCHATROOM_TOKEN=keep-me\n", encoding="utf-8")
    conn = sqlite3.connect(server / "chatroom.db")
    conn.execute("CREATE TABLE message (body TEXT)")
    conn.executemany("INSERT INTO message VALUES (?)", [(r,) for r in rows])
    conn.commit()
    conn.close()
    attachments = server / "attachments"
    attachments.mkdir(exist_ok=True)
    (attachments / "now").write_bytes(b"current")
    return tmp_path


def make_backup(path: Path, rows: tuple[str, ...], with_attachments: bool = True):
    path.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path / "chatroom.db")
    conn.execute("CREATE TABLE message (body TEXT)")
    conn.executemany("INSERT INTO message VALUES (?)", [(r,) for r in rows])
    conn.commit()
    conn.close()
    if with_attachments:
        (path / "attachments").mkdir(exist_ok=True)
        (path / "attachments" / "old").write_bytes(b"archived")
    (path / "manifest.json").write_text(
        json.dumps({"created_at": "2026-09-11T00:00:00+00:00",
                    "attachments_existed": with_attachments,
                    "db_bytes": 1, "attachment_files": 1 if with_attachments else 0}),
        encoding="utf-8")
    return path


def db_rows(db: Path) -> list[str]:
    conn = sqlite3.connect(db)
    try:
        return [r[0] for r in conn.execute("SELECT body FROM message")]
    finally:
        conn.close()


def test_refuses_while_hub_is_listening(tmp_path: Path):
    """🔴 Hub 還在跑就中止，而且**一個位元組都還沒動**。

    這條紅起來的樣子最惡劣：還原「成功」，使用者以為資料回來了，
    然後跑著的 Hub 把舊資料寫回去，下次重啟才發現什麼都沒變。
    """
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    port = listener.getsockname()[1]
    threading.Thread(target=lambda: listener.accept(), daemon=True).start()

    try:
        kit = make_kit(tmp_path, port=port)
        src = make_backup(tmp_path / "backups" / "20260911-000000", ("備份裡的",))
        restore = load_restore()

        with pytest.raises(RuntimeError, match="Hub"):
            restore.restore(src, repo=kit)

        # 現況必須原封不動
        assert db_rows(kit / "server" / "chatroom.db") == ["現況"]
        assert (kit / "server" / "attachments" / "now").exists()
    finally:
        listener.close()


def test_refuses_an_unopenable_backup(tmp_path: Path):
    """備份的 db 打不開就拒絕——**在覆蓋之前**發現，不是之後。"""
    kit = make_kit(tmp_path)
    src = tmp_path / "backups" / "broken"
    src.mkdir(parents=True)
    (src / "chatroom.db").write_bytes(b"this is not a database")
    restore = load_restore()

    with pytest.raises(ValueError, match="打不開"):
        restore.restore(src, repo=kit)

    assert db_rows(kit / "server" / "chatroom.db") == ["現況"]


def test_restores_db_and_attachments_together(tmp_path: Path):
    kit = make_kit(tmp_path)
    src = make_backup(tmp_path / "backups" / "20260911-000000", ("備份裡的",))
    restore = load_restore()

    result = restore.restore(src, repo=kit)

    assert db_rows(kit / "server" / "chatroom.db") == ["備份裡的"]
    assert (kit / "server" / "attachments" / "old").read_bytes() == b"archived"
    # 舊的附件被取代，不是合併——備份是一致快照，混起來就不再一致
    assert not (kit / "server" / "attachments" / "now").exists()
    assert result["attachments_restored"] is True


def test_takes_a_safety_backup_before_overwriting(tmp_path: Path):
    """還原前的現況要留著——拿錯備份時那是唯一的退路。"""
    kit = make_kit(tmp_path)
    src = make_backup(tmp_path / "backups" / "20260911-000000", ("備份裡的",))
    restore = load_restore()

    result = restore.restore(src, repo=kit)

    safety = Path(str(result["safety_backup"]))
    assert safety.exists()
    assert db_rows(safety / "chatroom.db") == ["現況"], "退路裡不是還原前的資料"
    assert (safety / "attachments" / "now").exists()


def test_env_is_not_touched(tmp_path: Path):
    """token 與 port 屬於設定，不屬於資料。還原不可以動它。"""
    kit = make_kit(tmp_path)
    src = make_backup(tmp_path / "backups" / "20260911-000000", ("備份裡的",))
    restore = load_restore()

    restore.restore(src, repo=kit)

    assert "keep-me" in (kit / "server" / ".env").read_text(encoding="utf-8")


def test_stale_wal_is_removed(tmp_path: Path):
    """舊的 -wal / -shm 留著，SQLite 會拿它們去「修復」剛換上的資料庫。

    症狀是還原完打開卻看到舊資料的片段，而檔案本身明明已經換過了。
    """
    kit = make_kit(tmp_path)
    wal = kit / "server" / "chatroom.db-wal"
    wal.write_bytes(b"stale wal")
    src = make_backup(tmp_path / "backups" / "20260911-000000", ("備份裡的",))
    restore = load_restore()

    restore.restore(src, repo=kit)

    assert not wal.exists()


def test_backup_without_attachments_leaves_existing_ones_alone(tmp_path: Path):
    """備份不含附件時，不要把現有的附件刪掉。

    刪掉的話，一份「只有 db」的備份會連帶毀掉還能用的附件——
    而那些附件本來跟這次還原無關。
    """
    kit = make_kit(tmp_path)
    src = make_backup(
        tmp_path / "backups" / "20260911-000000", ("備份裡的",),
        with_attachments=False)
    restore = load_restore()

    result = restore.restore(src, repo=kit)

    assert result["attachments_restored"] is False
    assert (kit / "server" / "attachments" / "now").exists()


def test_list_marks_backups_without_manifest(tmp_path: Path):
    """來歷不明的目錄要列出來但標記，不是藏起來。

    藏起來的話，使用者在畫面上找不到一個他明明看得到資料夾的東西。
    """
    kit = make_kit(tmp_path)
    make_backup(tmp_path / "backups" / "20260911-000000", ("好的",))
    mystery = tmp_path / "backups" / "someone-put-this-here"
    mystery.mkdir(parents=True)
    (mystery / "chatroom.db").write_bytes(b"")
    restore = load_restore()

    items = {i["name"]: i for i in restore.list_backups(repo=kit)}

    assert items["20260911-000000"]["complete"] is True
    assert items["someone-put-this-here"]["complete"] is False


def test_list_is_empty_when_there_are_no_backups(tmp_path: Path):
    restore = load_restore()
    assert restore.list_backups(repo=make_kit(tmp_path)) == []
