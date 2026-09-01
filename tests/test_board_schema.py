"""T-01：Board 三張表、room 兩個欄位、認領用的 partial index。

驗收重點不是「新表建得出來」——那是 CREATE TABLE 的保證。真正會出事的是
**既有 DB**：使用者手上是一個一直在跑的 `chatroom.db`，新表要能長在舊庫上，
而 `_migrate` 必須可重入（Hub 每次啟動都會跑一次）。
"""

import aiosqlite
import pytest

from chatroom_server.db import open_db

# 還沒有 board 的舊庫（只留這個測試會碰到的表）
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
"""

BOARD_TABLES = ["board_objective", "board_checklist", "board_task"]


async def _columns(db, table):
    rows = await (await db.execute(f"PRAGMA table_info({table})")).fetchall()
    return {r["name"] for r in rows}


async def _index_names(db, table):
    rows = await (await db.execute(f"PRAGMA index_list({table})")).fetchall()
    return {r["name"] for r in rows}


@pytest.mark.asyncio
async def test_board_tables_exist_on_fresh_db(tmp_path):
    db = await open_db(str(tmp_path / "fresh.db"))
    try:
        for table in BOARD_TABLES:
            cols = await _columns(db, table)
            assert cols, f"{table} 不存在"
            # 三張表都要有增量讀取用的 tombstone 與水位
            assert {"deleted", "board_seq", "room_id"} <= cols, table
    finally:
        await db.close()


@pytest.mark.asyncio
async def test_task_claim_is_a_separate_dimension(tmp_path):
    """認領欄位與 status 正交——孤兒只動 claim_*，做到哪不能被抹掉。"""
    db = await open_db(str(tmp_path / "fresh.db"))
    try:
        cols = await _columns(db, "board_task")
        assert {
            "status",
            "claim_participant_id",
            "claim_session_key",
            "claim_name",
            "claim_state",
            "claimed_at",
            "orphaned_at",
        } <= cols
        # 孤兒釋放要靠這條索引以 participant 一次撈出他領走的全部
        assert "idx_btask_claim" in await _index_names(db, "board_task")
    finally:
        await db.close()


@pytest.mark.asyncio
async def test_legacy_db_gains_board_without_losing_rows(tmp_path):
    path = str(tmp_path / "legacy.db")
    async with aiosqlite.connect(path) as db:
        await db.executescript(LEGACY)
        await db.execute(
            "INSERT INTO room (id, name, created_at) VALUES ('r1','舊房','2026-01-01')"
        )
        await db.commit()

    db = await open_db(path)
    try:
        assert {"board_seq", "board_supervisor_session_key"} <= await _columns(db, "room")
        for table in BOARD_TABLES:
            assert await _columns(db, table), f"{table} 沒長在舊庫上"
        row = await (await db.execute("SELECT name FROM room WHERE id='r1'")).fetchone()
        assert row["name"] == "舊房"
        # 舊房的水位從 0 起算，而不是 NULL——增量 client 拿 NULL 會整個壞掉
        row = await (await db.execute("SELECT board_seq FROM room WHERE id='r1'")).fetchone()
        assert row["board_seq"] == 0
    finally:
        await db.close()


@pytest.mark.asyncio
async def test_open_db_is_reentrant(tmp_path):
    """Hub 每次啟動都會跑一次 open_db，跑第二次不能炸。"""
    path = str(tmp_path / "twice.db")
    db = await open_db(path)
    await db.close()
    db = await open_db(path)
    try:
        assert await _columns(db, "board_task")
    finally:
        await db.close()
