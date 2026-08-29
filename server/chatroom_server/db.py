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
    join_ip      TEXT,                             -- 加入時的來源 IP（重名消歧用）
    -- 加入時用的那張 access_token（空＝主 token 或開放模式）。踢出要連著撤銷
    -- 它：session_key 是被踢者自己產的，只封那個等於沒封
    join_token   TEXT NOT NULL DEFAULT ''
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
    -- system 訊息的機器可讀型別（join / leave / kick / idle_removed /
    -- archive / archive_pending / unarchive）。內容是給人看的中文，client
    -- 要精確過濾就只能解析字串——那會在改一個字時無聲壞掉
    system_event TEXT NOT NULL DEFAULT '',
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
    -- 指派者預先取的名字；agent 依此指派加入時優先於自取名與名字池
    assigned_name      TEXT NOT NULL DEFAULT '',
    -- cancelled 是指派方收回，與被指派方婉拒的 declined 是兩件事，不可合併
    status             TEXT NOT NULL DEFAULT 'pending', -- pending/accepted/declined/cancelled/expired
    created_at         TEXT NOT NULL,
    resolved_at        TEXT
);
CREATE INDEX IF NOT EXISTS idx_assignment_target ON assignment(target_session_key, status);

-- Hub 見過的 session 名錄：bridge/watcher 帶 session_key 的呼叫都會 upsert。
-- 指派 UI 據此列出「掃描到的 session」，不必使用者手抄 key。
CREATE TABLE IF NOT EXISTS session (
    session_key   TEXT PRIMARY KEY,
    kind          TEXT NOT NULL DEFAULT 'other',  -- claude / codex / human / other
    label         TEXT NOT NULL DEFAULT '',       -- bridge 自報的代稱（CHATROOM_DEFAULT_NAME）
    first_seen_at TEXT NOT NULL,
    last_seen_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_session_seen ON session(last_seen_at);

-- Agent 向指定人類提出的問題。刻意**不進 message 流**：問題是定向的，
-- 灌進公開時間軸會變成噪音，也會讓其他人以為該由自己回答。
-- 房內成員仍查得到（agent 發問前可先看有沒有人問過同一件事，這正是這個
-- 機制要解決的問題），但人類 UI 只顯示指派給自己的那些。
CREATE TABLE IF NOT EXISTS question (
    id            TEXT PRIMARY KEY,
    room_id       TEXT NOT NULL REFERENCES room(id),
    asker_id      TEXT REFERENCES participant(id),
    target_id     TEXT NOT NULL REFERENCES participant(id),  -- 被問的人類
    prompt        TEXT NOT NULL,
    options       TEXT NOT NULL DEFAULT '[]',   -- JSON: [{"label","description"}]
    allow_free_text INTEGER NOT NULL DEFAULT 1,
    -- pending / answered / skipped / expired
    -- skipped = 人類明確選擇不在這裡回答（改回 session 內問），與逾時不同：
    -- 前者是決定，後者是沒看到，agent 的後續處置不一樣
    status        TEXT NOT NULL DEFAULT 'pending',
    answer        TEXT,
    answer_kind   TEXT,                          -- option / free_text
    created_at    TEXT NOT NULL,
    resolved_at   TEXT,
    -- 過了這個時間就不再是待答。發問的 agent 是**卡在那裡等**的，不是留言，
    -- 所以時限要短——等太久等於讓一條工作流癱瘓著
    expires_at    TEXT
);
-- 附件：內容存磁碟，這裡只留 metadata。sqlite 塞 BLOB 會讓資料庫迅速膨脹，
-- 而 long-poll 查詢與它共用同一個連線，大檔讀寫會拖累整個房間的即時性。
-- stored_name 用內容雜湊，同一份檔案重複上傳自動共用一份實體。
CREATE TABLE IF NOT EXISTS attachment (
    id          TEXT PRIMARY KEY,
    room_id     TEXT NOT NULL REFERENCES room(id),
    message_id  TEXT REFERENCES message(id),   -- NULL = 尚未附到任何訊息
    uploader_id TEXT REFERENCES participant(id),
    filename    TEXT NOT NULL,                 -- 原始檔名（僅顯示用，不當路徑）
    mime        TEXT NOT NULL DEFAULT 'application/octet-stream',
    size        INTEGER NOT NULL,
    sha256      TEXT NOT NULL,
    created_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_attachment_message ON attachment(message_id);
CREATE INDEX IF NOT EXISTS idx_attachment_room ON attachment(room_id, created_at);

-- 邀請進 Hub 用的存取 token。
-- .env 的 CHATROOM_TOKEN 是**主 token**，不在這張表裡、不可撤銷——它是主持人
-- 自己的鑰匙，弄丟了整台 Hub 就進不去。這裡放的是發給別人的那些：可以標註
-- 發給誰、可以單獨撤銷，而不必換掉所有人的 token。
--
-- 權限範圍與主 token 相同（token 是信任邊界，房間不是）。這張表買到的是
-- **可撤銷**與**可追溯**，不是隔離；要真隔離請開不同的 Hub 實例。
CREATE TABLE IF NOT EXISTS access_token (
    token        TEXT PRIMARY KEY,
    label        TEXT NOT NULL DEFAULT '',   -- 這張發給誰（給人看的）
    created_at   TEXT NOT NULL,
    last_used_at TEXT,
    revoked_at   TEXT                        -- 非 NULL 即失效；不刪列，保留紀錄
);

CREATE INDEX IF NOT EXISTS idx_question_room ON question(room_id, status);
CREATE INDEX IF NOT EXISTS idx_question_target ON question(target_id, status);
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
    ("assignment", "assigned_name", "assigned_name TEXT NOT NULL DEFAULT ''"),
    ("message", "system_event", "system_event TEXT NOT NULL DEFAULT ''"),
    # 邀請 UI 要能認出「這是誰」——共用一把 token 時 Hub 眼中所有人長得一樣，
    # 來源位址是唯一分得開的線索
    ("session", "last_ip", "last_ip TEXT"),
    # 踢出要連著撤銷對方的 access token，得先知道他是拿哪一張進來的
    ("participant", "join_token", "join_token TEXT NOT NULL DEFAULT ''"),
    # 問題逾時。舊資料的 expires_at 為 NULL＝永不過期，維持原本的語意
    ("question", "expires_at", "expires_at TEXT"),
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
