"""舊資料庫的欄位升級。

使用者手上是一個一直在跑的 `chatroom.db`——新欄位不是「重建一次就好」，
而是要能在既有資料上補起來，且不改變舊資料的語意（舊房一律維持公開）。
"""

import aiosqlite
import pytest

from chatroom_server.db import open_db

# 加上 visibility / reply_to_seq 之前的樣子（只留這個測試會碰到的欄位）
LEGACY = """
CREATE TABLE room (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    topic TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'active',
    next_seq INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,
    archived_at TEXT
);
CREATE TABLE message (
    id TEXT PRIMARY KEY,
    room_id TEXT NOT NULL,
    seq INTEGER NOT NULL,
    sender_id TEXT,
    kind TEXT NOT NULL DEFAULT 'chat',
    content TEXT NOT NULL,
    mentions TEXT NOT NULL DEFAULT '[]',
    reply_to TEXT,
    pinned INTEGER NOT NULL DEFAULT 0,
    pinned_by TEXT,
    deleted INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
);
"""


async def _columns(db, table):
    rows = await (await db.execute(f"PRAGMA table_info({table})")).fetchall()
    return {r["name"] for r in rows}


@pytest.mark.asyncio
async def test_legacy_db_gains_new_columns_without_losing_rows(tmp_path):
    path = str(tmp_path / "legacy.db")
    async with aiosqlite.connect(path) as db:
        await db.executescript(LEGACY)
        await db.execute(
            "INSERT INTO room (id, name, created_at) VALUES ('r1','舊房','2026-01-01')"
        )
        await db.execute(
            "INSERT INTO message (id, room_id, seq, kind, content, created_at)"
            " VALUES ('m1','r1',1,'chat','舊訊息','2026-01-01')"
        )
        await db.commit()

    db = await open_db(path)
    try:
        assert "visibility" in await _columns(db, "room")
        assert "reply_to_seq" in await _columns(db, "message")
        # 舊房維持公開：把既有的房悄悄變成私人，等於讓它們從所有人的
        # 列表上無聲消失
        row = await (
            await db.execute("SELECT visibility FROM room WHERE id='r1'")
        ).fetchone()
        assert row["visibility"] == "public"
        # 舊房維持詳細：那是這個欄位存在之前的實際行為。升級一次資料庫就
        # 讓所有房間的語氣改變，沒有人會預期
        assert "style" in await _columns(db, "room")
        row = await (
            await db.execute(
                "SELECT style, style_instructions FROM room WHERE id='r1'"
            )
        ).fetchone()
        assert row["style"] == "verbose"
        assert row["style_instructions"] == ""
        row = await (
            await db.execute("SELECT content, reply_to_seq FROM message WHERE id='m1'")
        ).fetchone()
        assert row["content"] == "舊訊息"
        assert row["reply_to_seq"] is None
    finally:
        await db.close()


@pytest.mark.asyncio
async def test_open_db_is_reentrant(tmp_path):
    """開兩次不該因為欄位已存在而炸掉。"""
    path = str(tmp_path / "twice.db")
    db = await open_db(path)
    await db.close()
    db = await open_db(path)
    try:
        assert "visibility" in await _columns(db, "room")
    finally:
        await db.close()
