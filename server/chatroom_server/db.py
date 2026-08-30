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
    -- public / private。private＝對話鎖定：不在別人的房間列表裡出現，
    -- 也不能沒有邀請就加入。這是**可見性**，不是加密——拿得到 room_id
    -- 又已經是成員的人照樣讀得到，它擋的是「逛到」與「自己走進來」
    visibility  TEXT NOT NULL DEFAULT 'public',
    -- 房內的說話方式：verbose（詳細）/ concise（精確）/ casual（親和）/ custom。
    -- agent 預設的回話方式是「任務回報」——長篇 Markdown、程式碼全貼、
    -- 每個步驟都交代。那在工單系統裡是對的，在聊天室裡多半是噪音，
    -- 而房間的用途只有建立者知道，所以由他選
    style       TEXT NOT NULL DEFAULT 'verbose',
    -- style='custom' 時的指示原文；其餘風格用 server 端的定稿，這裡留空
    style_instructions TEXT NOT NULL DEFAULT '',
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
    join_token   TEXT NOT NULL DEFAULT '',
    -- 加入當下房內的最後一則 seq。@ 判定拿它當界線：加入之前的 mention 是
    -- 給前一個同名者的（名字在離開後會被釋出重用），不該把新來的人叫醒。
    -- NULL＝這個欄位存在之前就在房裡的舊成員，一律當 0（計入全部歷史，
    -- 維持現行為）
    joined_seq   INTEGER
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
    -- 被回覆訊息的房內序號。內容是可以事後被軟刪除的，seq 不會——回覆指向
    -- 哪一則，這是唯一不會被刪掉的答案，client 也不必為了顯示「#12」而
    -- 反查一次訊息
    reply_to_seq INTEGER,
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
    -- 自報的主機名。指派 UI 靠它把「我這台機器上的 agent」與「別人機器上
    -- 的」分開——指派是私人房的入場券，把別人的 agent 指派進來等於把房裡
    -- 的內容送出去。**僅供辨識與分組，不是授權依據**（自報的東西不可信，
    -- 信任邊界仍然是 token）
    host          TEXT NOT NULL DEFAULT '',
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
    -- 允許複選。單選是預設，因為「只能挑一個」才逼得出決定；要並存的
    -- 條件（勾選要開哪幾個功能）才需要複選
    multi_select  INTEGER NOT NULL DEFAULT 0,
    -- pending / answered / skipped / expired
    -- skipped = 人類明確選擇不在這裡回答（改回 session 內問），與逾時不同：
    -- 前者是決定，後者是沒看到，agent 的後續處置不一樣
    status        TEXT NOT NULL DEFAULT 'pending',
    answer        TEXT,
    answer_kind   TEXT,                          -- option / free_text
    -- 複選題實際選了哪些（JSON list of label）。answer 同時保留一份人類可讀
    -- 的彙整字串，agent 兩種都拿得到：要判斷邏輯用這個，要轉述用 answer
    answer_options TEXT,
    -- 回答時附上的附件 id（JSON list）。UI 問題用講的講不清楚，一張截圖
    -- 勝過三段文字——而回答本來就是最需要附圖的地方
    answer_attachments TEXT NOT NULL DEFAULT '[]',
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
    # 主機名。舊 bridge 不自報，留空——空值在 UI 上是「未知裝置」，
    # 不能當成「本機」（那會讓所有舊 session 混進本機清單）
    ("session", "host", "host TEXT NOT NULL DEFAULT ''"),
    # 踢出要連著撤銷對方的 access token，得先知道他是拿哪一張進來的
    ("participant", "join_token", "join_token TEXT NOT NULL DEFAULT ''"),
    # 問題逾時。舊資料的 expires_at 為 NULL＝永不過期，維持原本的語意
    ("question", "expires_at", "expires_at TEXT"),
    # 對話鎖定。舊房一律 public——把既有的房悄悄變成私人，等於在使用者
    # 毫不知情的情況下讓它們從所有人的列表上消失
    ("room", "visibility", "visibility TEXT NOT NULL DEFAULT 'public'"),
    # 回覆目標的 seq。舊訊息補不回來（NULL），client 要能容忍缺值
    ("message", "reply_to_seq", "reply_to_seq INTEGER"),
    # 說話方式。舊房一律 verbose——那是這個欄位存在之前的實際行為，
    # 升級一次資料庫就讓所有房間的對話語氣改變，沒有人會預期
    # 提問的複選與附件。舊題目一律單選、無附件——那是這些欄位存在之前的行為
    ("question", "multi_select", "multi_select INTEGER NOT NULL DEFAULT 0"),
    ("question", "answer_options", "answer_options TEXT"),
    ("question", "answer_attachments",
     "answer_attachments TEXT NOT NULL DEFAULT '[]'"),
    # 加入當下的房內 seq，@ 判定的界線。**刻意不 backfill**：舊成員的
    # NULL 一律當 0（計入全部歷史＝這個欄位存在之前的行為），語意只對新
    # join 生效才叫零破壞；猜一個值回填反而會讓舊成員漏掉真正該收的 @
    ("participant", "joined_seq", "joined_seq INTEGER"),
    ("room", "style", "style TEXT NOT NULL DEFAULT 'verbose'"),
    ("room", "style_instructions", "style_instructions TEXT NOT NULL DEFAULT ''"),
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
