"""SQLite schema 與連線管理（aiosqlite, WAL 模式）。"""

import aiosqlite

SCHEMA = """
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS room (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    topic       TEXT NOT NULL DEFAULT '',
    status      TEXT NOT NULL DEFAULT 'active',   -- active / archived
    next_seq    INTEGER NOT NULL DEFAULT 1,       -- 訊息序號發放計數器
    created_at  TEXT NOT NULL,
    activated_at TEXT,                            -- 最近一次變為 active 的時間（建立或解封）
    archived_at TEXT,
    creator_session_key TEXT,                     -- 建立者（管理員）的 session；不外流
    archive_pending_since TEXT                    -- 自動封存倒數的起點；NULL = 未在倒數
);

CREATE TABLE IF NOT EXISTS participant (
    id           TEXT PRIMARY KEY,
    room_id      TEXT NOT NULL REFERENCES room(id),
    kind         TEXT NOT NULL,                   -- claude / codex / human / other
    session_key  TEXT NOT NULL,
    display_name TEXT NOT NULL,
    role         TEXT NOT NULL DEFAULT 'agent',   -- agent / human
    status       TEXT NOT NULL DEFAULT 'active',  -- active / left / removed
    joined_at    TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    left_at      TEXT,
    join_ip      TEXT                              -- 加入時的來源 IP（重名消歧用）
);
CREATE INDEX IF NOT EXISTS idx_participant_room ON participant(room_id, status);
CREATE INDEX IF NOT EXISTS idx_participant_session ON participant(session_key, status);
-- 房內唯一名稱只約束 active 成員
CREATE UNIQUE INDEX IF NOT EXISTS idx_participant_name
    ON participant(room_id, display_name) WHERE status = 'active';

CREATE TABLE IF NOT EXISTS message (
    id         TEXT PRIMARY KEY,
    room_id    TEXT NOT NULL REFERENCES room(id),
    seq        INTEGER NOT NULL,
    sender_id  TEXT REFERENCES participant(id),   -- NULL = 系統訊息
    kind       TEXT NOT NULL DEFAULT 'chat',      -- chat / system
    content    TEXT NOT NULL,
    mentions   TEXT NOT NULL DEFAULT '[]',        -- JSON list of display_name
    reply_to   TEXT,
    pinned     INTEGER NOT NULL DEFAULT 0,
    pinned_by  TEXT,
    deleted    INTEGER NOT NULL DEFAULT 0,
    -- 釘選/刪除等變更時從房間計數器領的新序號；推播用 max(seq, update_seq)
    -- 判斷增量，讓既有訊息的狀態變更也能被同一個 cursor 掃到
    update_seq INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    UNIQUE(room_id, seq)
);
CREATE INDEX IF NOT EXISTS idx_message_room_seq ON message(room_id, seq);

CREATE TABLE IF NOT EXISTS assignment (
    id                 TEXT PRIMARY KEY,
    room_id            TEXT NOT NULL REFERENCES room(id),
    target_session_key TEXT NOT NULL,
    note               TEXT NOT NULL DEFAULT '',
    status             TEXT NOT NULL DEFAULT 'pending', -- pending/accepted/declined/expired
    created_at         TEXT NOT NULL,
    resolved_at        TEXT
);
CREATE INDEX IF NOT EXISTS idx_assignment_target ON assignment(target_session_key, status);
"""

# 既有 DB 的欄位補齊：CREATE TABLE IF NOT EXISTS 對已存在的表不會加新欄，
# 這裡列出各版本新增的欄位，open_db 時缺哪補哪（可重入）。
# 注意：ALTER TABLE ADD COLUMN 的 NOT NULL 欄位必須帶 DEFAULT。
MIGRATIONS: list[tuple[str, str, str]] = [
    # (table, column, 完整欄位定義)
    ("room", "activated_at", "activated_at TEXT"),
    ("message", "update_seq", "update_seq INTEGER NOT NULL DEFAULT 0"),
    ("participant", "join_ip", "join_ip TEXT"),
    ("room", "creator_session_key", "creator_session_key TEXT"),
    ("room", "archive_pending_since", "archive_pending_since TEXT"),
]


async def _migrate(db: aiosqlite.Connection) -> None:
    """為舊版 DB 補上後續版本新增的欄位（冪等）。"""
    for table, column, ddl in MIGRATIONS:
        rows = await (await db.execute(f"PRAGMA table_info({table})")).fetchall()
        existing = {r["name"] for r in rows}
        if column not in existing:
            await db.execute(f"ALTER TABLE {table} ADD COLUMN {ddl}")


async def open_db(path: str) -> aiosqlite.Connection:
    """開啟資料庫並確保 schema 存在（含舊版 DB 的欄位升級）。"""
    db = await aiosqlite.connect(path)
    db.row_factory = aiosqlite.Row
    await db.executescript(SCHEMA)
    await _migrate(db)
    await db.commit()
    return db
