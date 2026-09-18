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
    # 用位置取（table_info 的第 1 欄是名字）：升級前的 DB 是原始連線，
    # row_factory 要 open_db 才設，用鍵取會 TypeError
    return {r[1] for r in rows}


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


# Remote Ops（REMOTE-OPS-PLAN §4）之前的樣子：房沒有 kind，四張新表都不存在
REMOTE_OPS_TABLES = ("agent_run", "agent_run_event", "runner", "runner_command")


async def _tables(db):
    rows = await (await db.execute(
        "SELECT name FROM sqlite_master WHERE type='table'")).fetchall()
    return {r[0] for r in rows}


@pytest.mark.asyncio
async def test_pre_remote_ops_db_gains_room_kind_and_the_new_tables(tmp_path):
    """升級到 Remote Ops：既有 DB 要補 `room.kind` 與四張新表，舊房仍可讀。

    `kind` 的預設**必須是 chat**：反過來預設 ops 會讓整個 Hub 上的房間全部
    停止自動封存，而沒有任何地方會報錯——那是一個只會在幾天後才被發現的
    行為改變。四張表則是「建得起來」的問題：少一張的話，症狀不是啟動失敗，
    而是第一次有人派工時才 no such table。
    """
    path = str(tmp_path / "preops.db")
    async with aiosqlite.connect(path) as db:
        await db.executescript(LEGACY)
        await db.execute(
            "INSERT INTO room (id, name, created_at)"
            " VALUES ('r1','升級前的房','2026-01-01')"
        )
        await db.execute(
            "INSERT INTO message (id, room_id, seq, kind, content, created_at)"
            " VALUES ('m1','r1',1,'chat','升級前的訊息','2026-01-01')"
        )
        await db.commit()
        before = await _tables(db)
        assert not (before & set(REMOTE_OPS_TABLES)), (
            "升級前的 schema 就已經有這些表了，這條測試等於沒驗")
        assert "kind" not in await _columns(db, "room")

    db = await open_db(path)
    try:
        assert "kind" in await _columns(db, "room")
        row = await (
            await db.execute("SELECT name, kind FROM room WHERE id='r1'")
        ).fetchone()
        assert row["name"] == "升級前的房"
        assert row["kind"] == "chat", "既有房被改成 ops 的話，它們會停止自動封存"
        # 舊訊息仍讀得到（補欄不動資料）
        row = await (
            await db.execute("SELECT content FROM message WHERE id='m1'")
        ).fetchone()
        assert row["content"] == "升級前的訊息"

        now = await _tables(db)
        missing = [t for t in REMOTE_OPS_TABLES if t not in now]
        assert not missing, f"升級後還是少了這幾張表：{missing}"
        # 建得起來還不夠：每一張都要真的寫得進去（欄位對得上）
        for table in REMOTE_OPS_TABLES:
            await db.execute(f"SELECT * FROM {table} LIMIT 1")
        assert "token_sha256" in await _columns(db, "runner")
        # run 成員的標記。**舊 DB 補不到這一欄的話，症狀不是啟動失敗**，
        # 而是每一次 join 都 no such column——整間 Hub 沒有人進得來
        assert "run_id" in await _columns(db, "participant")
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


@pytest.mark.asyncio
async def test_stale_runner_commands_are_backfilled_as_applied(tmp_path):
    """卡在「已收到、沒生效」的舊命令要一次收乾淨（實機 2026-09-18）。

    App 把 `applied_at IS NULL` 當成進行中 → 重啟鈕與恢復鈕一起停用。正式
    Hub 上有四筆這樣的命令（功能上線前的 pause／resume，以及舊版執行器領走
    就退出的 restart），人看到的是一台永遠按不動的執行器。

    回填成 `applied_at = acked_at`：那筆命令真正發生的時刻就是被取走的那一
    刻，寫成「現在」等於在面板上編一個新的事件。
    """
    path = str(tmp_path / "cmds.db")
    db = await open_db(path)
    await db.execute(
        "INSERT INTO runner (id, host, label, status, max_parallel, projects,"
        " registered_at, last_seen_at)"
        " VALUES ('rn1','esvel-pc','main','offline',1,'[]',"
        "'2026-09-17T00:00:00Z','2026-09-17T00:00:00Z')")
    await db.execute(
        "INSERT INTO runner_command (id, runner_id, command, created_at,"
        " acked_at, applied_at) VALUES"
        " ('c1','rn1','restart','2026-09-18T09:11:00Z',"
        "  '2026-09-18T09:12:00Z', NULL),"
        " ('c2','rn1','pause','2026-09-17T01:00:00Z', NULL, NULL)")
    # 回到這次遷移之前的版次
    await db.execute("PRAGMA user_version=4")
    await db.commit()
    await db.close()

    db = await open_db(path)
    rows = {r["id"]: r for r in await (await db.execute(
        "SELECT id, acked_at, applied_at, note FROM runner_command")
    ).fetchall()}
    await db.close()
    assert rows["c1"]["applied_at"] == rows["c1"]["acked_at"]
    assert "舊版執行器" in rows["c1"]["note"]
    assert rows["c2"]["applied_at"] is None, (
        "還沒被取走的命令也被收掉了——那筆命令執行器根本還沒看到")
