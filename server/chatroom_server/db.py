"""SQLite schema 與連線管理（aiosqlite, WAL 模式）。"""

import logging
import sqlite3

import aiosqlite

logger = logging.getLogger("chatroom")

SCHEMA = """
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS room (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    topic       TEXT NOT NULL DEFAULT '',
    status      TEXT NOT NULL DEFAULT 'active',   -- active / archived
    -- 房間類型：chat（一般對話，預設）/ ops（遠端派工的工作房）。
    -- ops 房**不自動封存、不進 purge**：它的存在理由是「隨時可以派工」，
    -- 而自動封存的判準是「房內沒有 active agent」——那對 ops 房恆真
    -- （agent 是單次任務，做完就走），於是它每次都會在無人派工時被收掉。
    -- ⚠️ **這一欄同時列在 MIGRATIONS 裡，兩邊都要有**（board_task.moved_to
    -- 的教訓）：舊 db 靠 migration 補欄，而這份 CREATE TABLE 是新庫的來源
    kind        TEXT NOT NULL DEFAULT 'chat',
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
    archive_pending_since TEXT,                   -- 自動封存倒數的起點；NULL = 未在倒數
    -- 工作房綁定的工作區 key（ops 房專用）。NULL＝尚未綁定，不能派工。
    -- 一次性：綁定後不提供解綁——run 的歷史都掛在這間房下，中途換工作區
    -- 等於讓同一串稽核記錄橫跨兩份工作樹，而回頭看時分不出哪筆是哪邊的。
    -- ⚠️ **這一欄同時列在 MIGRATIONS 裡，兩邊都要有**
    workspace_key TEXT,
    -- 同一個工作區一次只允許一個寫入者（ops 房專用開關，預設開）。
    -- 關掉＝這間房的 run 容許併行動同一份工作樹，由房主自己負責。
    -- 預設 1（開）：安全的那一邊要是預設值，舊房升級後行為不變。
    -- ⚠️ **這一欄同時列在 MIGRATIONS 裡，兩邊都要有**
    single_writer INTEGER NOT NULL DEFAULT 1
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
    -- subagent 依附的父成員（同房的 participant.id）；NULL＝一般成員。
    -- agent 派出的子 agent 與父層共用同一個 MCP 進程與 session id，Hub 分辨
    -- 不出來，只能由對方自報——這欄位存的就是那個自報的隸屬關係
    parent_id    TEXT REFERENCES participant(id),
    -- 臨時成員：工作結束即移除，進出不進訊息流、不計入自動封存判定、
    -- 走專屬的短 TTL。與 parent_id 一起設定，不單獨存在
    ephemeral    INTEGER NOT NULL DEFAULT 0,
    -- 加入當下房內的最後一則 seq。@ 判定拿它當界線：加入之前的 mention 是
    -- 給前一個同名者的（名字在離開後會被釋出重用），不該把新來的人叫醒。
    -- NULL＝這個欄位存在之前就在房裡的舊成員，一律當 0（計入全部歷史，
    -- 維持現行為）
    joined_seq   INTEGER,
    -- hold 標記的到期時間；NULL＝沒有 hold。時限內 presence sweeper 不會
    -- 因閒置移除這個成員（跑長測試、長編譯時自行掛上，做完再解除）
    hold_until   TEXT,
    -- 這個成員是哪一筆派工（run）帶進來的。session_key 形如
    -- `claude-run-<run_id>` 且那筆 run 屬於這間房時填入；空字串＝一般成員。
    -- 工作房是**常駐**的，而每一筆 run 都是一個新身分——不記下來的話，run
    -- 結束時沒有人說得出該把誰請出去，成員列的「已離開」會隨派工次數無限
    -- 變長。⚠️ 這一欄在 MIGRATIONS 也有一份，兩邊都要改
    run_id       TEXT NOT NULL DEFAULT ''
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
    -- 發話當下 participant.kind 的快照（claude / codex / human / other）。
    -- run 成員結束後不進成員名冊，client 從名冊反查 kind 會查不到而退回
    -- other——一句 agent 說過的話，在他離開之後就長得跟系統雜訊一樣。
    -- 空字串＝這一欄存在之前的舊訊息或系統訊息。
    -- ⚠️ 這一欄在 MIGRATIONS 也有一份，兩邊都要改
    sender_kind TEXT NOT NULL DEFAULT '',
    kind       TEXT NOT NULL DEFAULT 'chat',      -- chat / system
    -- system 訊息的機器可讀型別（join / leave / kick / idle_removed /
    -- archive / archive_pending / unarchive）。內容是給人看的中文，client
    -- 要精確過濾就只能解析字串——那會在改一個字時無聲壞掉
    system_event TEXT NOT NULL DEFAULT '',
    content    TEXT NOT NULL,
    mentions   TEXT NOT NULL DEFAULT '[]',        -- JSON list of display_name
    -- 發話者原本打的群組標籤（all / agents / humans），JSON list。
    -- mentions 存的是展開後的實名，UI 要靠這個欄位還原成一顆 @all chip——
    -- 否則畫面上會攤出一整排全房名單
    mention_groups TEXT NOT NULL DEFAULT '[]',
    -- 訊息裡以 `#[卡片標題]` 指涉的板上卡片，JSON list of
    -- {board_id, task_id, title}。title 是**發文當下的標題快照**，理由同
    -- reply_to_seq：卡會被改名、被刪、被搬，而「這則訊息當時指的是哪一張」
    -- 不該被之後的變動改寫。現況由讀取時現查的 card_preview 回答
    card_refs  TEXT NOT NULL DEFAULT '[]',
    -- 最後一次編輯的時間；NULL = 沒被改過。只存時間戳不留歷史（見 MIGRATIONS）
    edited_at  TEXT,
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
    -- 指派者的群（見 session.party）。空字串＝這一欄存在之前建立的，
    -- 兌換時放行——升級一次資料庫就讓所有待處理的指派作廢，沒有人會預期
    party              TEXT NOT NULL DEFAULT '',
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
    -- 這個 session 是拿**哪一群**憑證進來的（見 app.py 的 `_party_of`）。
    -- `.env` 的兩把（agent／human）同屬 'host'——一台機器上的人與他的
    -- agent 本來就用不同 token，分開算的話主持人會指派不了自己的 agent。
    -- 每張邀請自成一群，加發的 agent 憑證沿用發它的那張的群。
    --
    -- ⚠️ **空字串是「還不知道」，不是「自成一群」**：這一欄是後來加的，
    -- 既有 session 要等下一次心跳（watcher 每 15~65 秒一次）才補得上。
    -- 把未知當成一群會讓升級的那一瞬間所有 agent 互相看不見。
    party         TEXT NOT NULL DEFAULT '',
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
    -- 'human' / 'agent'。這是唯一有權限差的一欄：`role=human` 與
    -- `X-Host-View` 只認 human。預設 agent——沒講清楚的一律不給人類的份量
    audience     TEXT NOT NULL DEFAULT 'agent',
    -- 這張屬於哪一群人（一個人 + 他的 agent）。空字串＝這張自己就是一群，
    -- 群 id 由 token 的 hash 即時推出（不存明碼，也不外流到 API 回應）。
    -- 加發 agent 憑證時寫入發它的那張的群，兩張從此是同一個人。
    party        TEXT NOT NULL DEFAULT '',
    created_at   TEXT NOT NULL,
    last_used_at TEXT,
    revoked_at   TEXT                        -- 非 NULL 即失效；不刪列，保留紀錄
);

-- 成員提出的封存請求。封存本身限建立者執行，但房裡的人最清楚事情做完了
-- 沒有——請求機制讓他們提得出來，而不必去戳房主或乾等自動封存。
--
-- 刻意**不進 message 流**（與 question 同一個理由）：提議是定向給建立者的
-- 待辦，灌進時間軸會變成噪音。但**會**連帶發一則系統訊息當通知——那則是
-- 「這件事發生了」的公告，與這裡的「這件事還沒被處理」是兩種東西。
CREATE TABLE IF NOT EXISTS archive_request (
    id           TEXT PRIMARY KEY,
    room_id      TEXT NOT NULL REFERENCES room(id),
    requester_id TEXT NOT NULL REFERENCES participant(id),
    reason       TEXT NOT NULL DEFAULT '',
    -- pending / approved / rejected / cancelled / superseded
    -- superseded = 房間在請求還沒被處理時就以別的方式封存了（自動封存、
    -- 或建立者直接按封存）。與 rejected 分開：被拒絕是一個決定，被蓋過
    -- 不是——提議者看到 rejected 會知道房主看過了並說不要
    status       TEXT NOT NULL DEFAULT 'pending',
    created_at   TEXT NOT NULL,
    resolved_at  TEXT,
    -- 誰拍的板。只會是建立者，但記下來才追得出是哪一次的建立者身分
    resolved_by  TEXT REFERENCES participant(id)
);
CREATE INDEX IF NOT EXISTS idx_archive_request_room
    ON archive_request(room_id, status);

-- ── Board（共同任務板）──────────────────────────────────────────────
-- 三層：Objective（週期）→ Checklist（階段）→ Task（最小單位）。
-- 掛在 room 底下，不另立 board 表——可見性／封存／權限／long-poll／讀取
-- 邊界全是 room-scoped 的，獨立就要把那六套機制各重造一份。
-- 增量讀取用房內獨立的 board_seq（見 room.board_seq），不共用 next_seq：
-- 共用會讓人看到的訊息編號跳號，而 reply_to_seq 是畫在 UI 上給人看的。
CREATE TABLE IF NOT EXISTS board_objective (
    id          TEXT PRIMARY KEY,
    room_id     TEXT NOT NULL REFERENCES room(id),
    title       TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    -- active / review / verified / done / cancelled
    -- review 與 verified 分開：前者是「該做的都做完了」（機器判得出來），
    -- 後者是「確認過沒問題」（只有人判得出來）。合成一個就沒有東西擋得住
    -- 「所有 task 打勾＝週期完成」
    status      TEXT NOT NULL DEFAULT 'active',
    order_index INTEGER NOT NULL DEFAULT 0,
    created_by  TEXT REFERENCES participant(id),
    -- 建立者的名字快照。id 在對方離場後查不回名字，而 board 上最先查不回的
    -- 正是建立者——它常常是一個已經被回收的 subagent
    created_by_name TEXT NOT NULL DEFAULT '',
    -- 送審／確認／完成分別是誰。三個時間點各留一份：追得出「誰確認的」
    -- 才有守門的意義，只留 completed_by 等於沒有守門紀錄
    reviewed_by  TEXT REFERENCES participant(id),
    reviewed_at  TEXT,
    verified_by  TEXT REFERENCES participant(id),
    verified_at  TEXT,
    completed_by TEXT REFERENCES participant(id),
    completed_at TEXT,
    deleted     INTEGER NOT NULL DEFAULT 0,   -- 軟刪除；增量讀取的 tombstone
    board_seq   INTEGER NOT NULL DEFAULT 0,
    created_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_bobjective_room
    ON board_objective(room_id, board_seq);

CREATE TABLE IF NOT EXISTS board_checklist (
    id           TEXT PRIMARY KEY,
    room_id      TEXT NOT NULL REFERENCES room(id),
    objective_id TEXT NOT NULL REFERENCES board_objective(id),
    title        TEXT NOT NULL,
    description  TEXT NOT NULL DEFAULT '',
    status       TEXT NOT NULL DEFAULT 'open',  -- open / done / cancelled
    order_index  INTEGER NOT NULL DEFAULT 0,
    created_by   TEXT REFERENCES participant(id),
    created_by_name TEXT NOT NULL DEFAULT '',
    completed_by TEXT REFERENCES participant(id),
    completed_at TEXT,
    deleted      INTEGER NOT NULL DEFAULT 0,
    board_seq    INTEGER NOT NULL DEFAULT 0,
    created_at   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_bchecklist_room
    ON board_checklist(room_id, board_seq);

-- 階段素材：附件掛在 **checklist（階段）** 上，該階段的所有卡與 run 共用
-- （艾斯維爾 2026-09-17 裁決）。
--
-- 掛在階段而不是卡：一輪 run 的「任務相關附件」要答得出來，而卡是會換的
-- ——上一輪產出的截圖掛在上一張卡上，下一輪就看不到了，於是 agent 只能
-- 回去掃整間房的歷史附件（而工作房是常駐的，那份歷史只會愈長愈久）。
--
-- ⚠️ 這張表**不軟刪除**：它沒有增量讀取的 tombstone 需求（素材清單跟著
-- checklist 一起讀），留一列已刪的只會讓「這個階段有幾份素材」說謊。
CREATE TABLE IF NOT EXISTS board_checklist_file (
    id            TEXT PRIMARY KEY,
    checklist_id  TEXT NOT NULL REFERENCES board_checklist(id),
    attachment_id TEXT NOT NULL REFERENCES attachment(id),
    added_by      TEXT NOT NULL DEFAULT '',   -- actor_key（人類或 agent）
    added_by_name TEXT NOT NULL DEFAULT '',
    note          TEXT NOT NULL DEFAULT '',   -- 一句話：這份素材是什麼
    created_at    TEXT NOT NULL,
    UNIQUE(checklist_id, attachment_id)
);
CREATE INDEX IF NOT EXISTS idx_bchecklist_file
    ON board_checklist_file(checklist_id, created_at);

CREATE TABLE IF NOT EXISTS board_task (
    id           TEXT PRIMARY KEY,
    room_id      TEXT NOT NULL REFERENCES room(id),
    checklist_id TEXT NOT NULL REFERENCES board_checklist(id),
    title        TEXT NOT NULL,
    description  TEXT NOT NULL DEFAULT '',
    -- todo / in_progress / blocked / done / cancelled
    -- ⚠️ 沒有 claimed：認領是另一個維度（見下方 claim_*）。塞進 status 的話，
    -- 孤兒卡打回 todo 會讓「做了一半」跟「沒人碰過」長得一模一樣
    status       TEXT NOT NULL DEFAULT 'todo',
    order_index  INTEGER NOT NULL DEFAULT 0,
    priority     TEXT NOT NULL DEFAULT 'normal',  -- low / normal / high

    -- 現任／前任持有者。participant_id 跨世代會變，session_key 才是 agent
    -- 的持久身分——re-claim 要靠後者才認得出「這是同一個人回來了」
    claim_participant_id TEXT REFERENCES participant(id),
    claim_session_key    TEXT NOT NULL DEFAULT '',
    claim_name           TEXT NOT NULL DEFAULT '',  -- 認領當下的 display_name
    -- 認領當下的 agent 種類（claude / codex / human / other）。與 claim_name
    -- 同一個理由：離場後 participant 查得到列但畫面要的是「當時是誰」，而
    -- 種類徽章在卡片上與名字並列
    claim_kind           TEXT NOT NULL DEFAULT '',
    -- ''（未認領）/ held（持有中）/ orphaned（持有者已不在房內）
    -- released 不存：主動放棄就清成 ''，那是「這張卡沒人做」的事實
    claim_state          TEXT NOT NULL DEFAULT '',
    claimed_at           TEXT,
    orphaned_at          TEXT,
    -- 為什麼變成孤兒。**只有在離場那一刻知道**——事後從 participant 反推
    -- 不出來（status 會被下一次 join 覆寫），所以當場記
    orphaned_reason      TEXT NOT NULL DEFAULT '',
    -- `status='moved'` 時這件事搬去哪張卡了。空字串＝搬走了但去向還沒說，
    -- 那是真實的中間狀態（新週期常常是先收舊卡、再建新卡）。
    -- ⚠️ **這一欄同時列在 MIGRATIONS 裡，兩邊都要有**：舊 db 靠 migration
    -- 補欄，而 `board_task__v2` 的重建路徑是照這份 CREATE TABLE 建的——
    -- 只加 migration 的話，重建之後 INSERT 會找不到這個欄位
    moved_to             TEXT NOT NULL DEFAULT '',

    -- 來源訊息的房內 seq。**存 seq 不存 message_id**，與 reply_to_seq 同一個
    -- 理由：訊息可以被軟刪除，seq 不會
    source_seq   INTEGER,
    -- 人類指定的執行者（建議，不是鎖）。認領仍要對方自己來——指派一個沒醒著
    -- 的 agent 然後把卡鎖起來，board 會停在那裡
    assignee_participant_id TEXT REFERENCES participant(id),
    -- 誰指定的（卡片上會寫「某某指定」）。同樣存名字快照
    assigned_by             TEXT REFERENCES participant(id),
    assigned_by_name        TEXT NOT NULL DEFAULT '',

    created_by   TEXT REFERENCES participant(id),
    created_by_name TEXT NOT NULL DEFAULT '',
    completed_by TEXT REFERENCES participant(id),
    completed_at TEXT,
    deleted      INTEGER NOT NULL DEFAULT 0,
    board_seq    INTEGER NOT NULL DEFAULT 0,
    created_at   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_btask_room ON board_task(room_id, board_seq);
CREATE INDEX IF NOT EXISTS idx_btask_checklist ON board_task(checklist_id, status);
-- 孤兒釋放要靠這條：成員離場時以 participant_id 一次撈出他領走的全部。
-- 這條 partial index 放在 SCHEMA 沒問題——board_task 是全新的表，同一份
-- executescript 裡就建好了，不像 idx_participant_parent 要等 ALTER 補欄位
CREATE INDEX IF NOT EXISTS idx_btask_claim
    ON board_task(claim_participant_id) WHERE claim_state = 'held';

-- 「未分類」的去重靠的是「固定名字找得回同一個」，而那條不變式原本只寫在
-- 註解與 Python 裡：`_uncategorised_checklist` 是 SELECT-then-INSERT，中間
-- 有 await 讓出點，並行建立無 parent 的 Task 會各自讀到空、各自 INSERT，
-- 於是一個房間長出好幾組「未分類」（審核用 Codex 實測 12 路建出 12 組）。
-- 每一組都是永久留在板上的空殼。約束寫進資料庫，那條路才真的走不通。
--
-- 🚨 這兩條與 idx_btask_claim **不同**：那個能直接放 schema 是因為
-- board_task 是同一份 executescript 裡建的全新表；這兩條加在**既有**表上，
-- 現存資料只要已經違反就會建立失敗、連帶 DB 開不起來。
-- 先跑 `scripts/dedupe-uncategorised.py`（預設 dry-run）。
CREATE UNIQUE INDEX IF NOT EXISTS idx_bobjective_uncategorised
    ON board_objective(room_id) WHERE deleted = 0 AND title = '未分類';
CREATE UNIQUE INDEX IF NOT EXISTS idx_bchecklist_uncategorised
    ON board_checklist(objective_id) WHERE deleted = 0 AND title = '未分類';

-- ── Board v2：Board 成為獨立實體 ────────────────────────────────────
-- v1 把 Board 掛在 room 底下（一房一板），代價是 Epic 級的工作面被綁在一次
-- 可被封存／刪除的臨時對話上。v2 反轉所有權：**房間掛接 Board**，一塊板可
-- 同時掛在多間房，房封存或刪除只解除關聯。
-- 以下四張表先加、舊欄位先不刪（Board 設計稿 §11 步驟 1），
-- 讓 v1 路由還能當 wrapper 跑，等所有 client 升級後才 rebuild 清乾淨。
CREATE TABLE IF NOT EXISTS board (
    id              TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    description     TEXT NOT NULL DEFAULT '',
    status          TEXT NOT NULL DEFAULT 'active',      -- active / archived
    -- **結局**，與 status 正交（艾斯維爾 2026-09-05 裁定 A）。
    -- status 回答「現在還能不能編輯」（可逆），這一欄回答「這份工作的結局
    -- 是什麼」。塞成同一欄的四個值就表達不出「完成**且**收起來」，而那是
    -- 最常見的收尾。同一個判斷在 Task 那裡做過：status 與 claim 正交。
    -- '' / completed / abandoned；可 reopen，不可逆的只有刪除
    outcome         TEXT NOT NULL DEFAULT '',
    -- ⚠️ 預設 **public**，與 room 那邊同一個判斷：把東西悄悄變成私人，等於
    -- 在使用者毫不知情的情況下讓它從別人的列表上消失。這個欄位在 2026-09-03
    -- 之前是死欄位（只有 schema、沒人讀），預設值原本寫的是 private——喚醒
    -- 它的那一刻若照著那個值走，所有既有的板會一次消失（見 `_migrate_data`）。
    -- 建板的兩條路徑都顯式帶值，這個預設只是最後一道保險
    visibility      TEXT NOT NULL DEFAULT 'public',
    -- 擁有者是 actor_key 不是 participant：participant 會隨著離房消失，
    -- 而 Board 的存在本來就不依賴任何一間房還開著
    owner_actor_key TEXT NOT NULL,
    -- 每塊板獨立的單調水位。**不與 room.next_seq 共用**，理由與 v1 相同：
    -- 共用會讓人看到的訊息編號跳號
    board_seq       INTEGER NOT NULL DEFAULT 0,
    -- 換軸當下的水位：建板時寫一次，**之後永遠不動**。
    -- `board_seq` 會跟著每一次變更長，所以事後看不出當初是從哪一格接上的
    -- ——而稽核串的完整性判準需要那個下界：換軸之前的號屬於 v1 的房內序列，
    -- 那段本來就不會有 board_event，把它算成「洞」是誤判
    -- （@測試Novia 2026-09-03 T19）。顯式建的板是 0（它從頭就是 v2）
    migrated_from_seq INTEGER NOT NULL DEFAULT 0,
    -- 這塊板自訂的額外標籤（艾斯維爾 #403：「每個板子可以有自訂的其他
    -- 標籤」）。**預設集合不存在這裡**——那是程式常數，跨板一致；這一欄
    -- 只放附加的部分。
    --
    -- ⚠️ 與「自由輸入」是兩件事：加標籤是**一次明確的動作**，之後仍然從
    -- 選單挑。所以固定集合要防的（`bug`／`Bug`／`BUG`／`錯誤` 四種寫法，
    -- 而且不會報錯、只會讓分堆慢慢失效）一個都沒放掉
    custom_tags  TEXT NOT NULL DEFAULT '[]',
    -- Supervisor 從 room 搬到 board：他看的是這塊板，不是某一間房，
    -- 所以離開任何一間房都不該讓他退場
    supervisor_actor_key TEXT NOT NULL DEFAULT '',
    supervisor_name TEXT NOT NULL DEFAULT '',
    supervisor_kind TEXT NOT NULL DEFAULT '',
    supervisor_set_by_actor_key TEXT NOT NULL DEFAULT '',
    supervisor_set_at TEXT,
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_board_status ON board(status, updated_at);

CREATE TABLE IF NOT EXISTS board_room (
    id          TEXT PRIMARY KEY,
    board_id    TEXT NOT NULL REFERENCES board(id),
    -- ⚠️ 刻意不對 room 做強外鍵：room 可以被永久刪除，但「這塊板曾經掛在
    -- 那間房」這件事要留著，否則 provenance 會跟著房一起消失
    room_id     TEXT NOT NULL,
    room_name   TEXT NOT NULL DEFAULT '',   -- 房名快照，房刪掉後畫面還講得出來
    attached_by_actor_key TEXT NOT NULL,
    attached_at TEXT NOT NULL,
    -- 解除掛接不刪列，改標時間：每次掛接／解除都是一筆歷史
    detached_at TEXT
);
-- Phase 1 的「一房最多一塊 active Board」寫進資料庫，不靠呼叫端自律
CREATE UNIQUE INDEX IF NOT EXISTS idx_board_room_one_active_per_room
    ON board_room(room_id) WHERE detached_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_board_room_board_active
    ON board_room(board_id) WHERE detached_at IS NULL;

CREATE TABLE IF NOT EXISTS board_member (
    board_id     TEXT NOT NULL REFERENCES board(id),
    -- Hub 內持久的協作者身分（由 canonical session_key 規範化而得）。
    -- 權限、認領與稽核一律用它；participant_id 只證明「現在從哪間房操作」
    actor_key    TEXT NOT NULL,
    role         TEXT NOT NULL,                    -- owner / editor / viewer
    -- 定案顯示名：**以最早進入這塊板的那個名字為準**（艾斯維爾 2026-09-02）。
    -- 同一個 actor 在不同房可能叫不同名字，板上只能有一個稱呼，否則同一個人
    -- 在同一張卡的歷史裡會以兩個名字出現
    display_name TEXT NOT NULL DEFAULT '',
    -- 其餘看過的名字，供 UI hover 顯示「他在別的房叫什麼」。
    -- JSON 陣列 [{"name","room_id","first_seen_at"}]；只有名字的話講不出
    -- 這個別名是哪一間房來的
    aliases      TEXT NOT NULL DEFAULT '[]',
    actor_kind   TEXT NOT NULL DEFAULT '',   -- human / claude / codex / other
    added_by_actor_key TEXT NOT NULL DEFAULT '',
    added_at     TEXT NOT NULL,
    removed_at   TEXT,
    PRIMARY KEY (board_id, actor_key)
);
CREATE INDEX IF NOT EXISTS idx_board_member_actor ON board_member(actor_key);

-- 孤兒卡的「請求指派」（N-4，載體定案 C：獨立表，艾斯維爾 2026-09-03）。
-- **刻意不復用 assignment 表**：那張是「邀請某個 session 進房」，這張是
-- 「請某個人接手這張卡」，兩者的目標、生命週期與結束條件都不同。合併發生在
-- **清單層**（UI 拿兩份自己併，@開發Novia (UI) 2026-09-04 定的契約），不在
-- 資料層——併在資料層的話，兩種東西的欄位會互相污染成一堆可空欄。
CREATE TABLE IF NOT EXISTS board_task_request (
    id            TEXT PRIMARY KEY,
    task_id       TEXT NOT NULL REFERENCES board_task(id),
    -- 板與房都存：板是這張卡真正的歸屬，房是「請求從哪裡發出的」。
    -- 只存房的話，板解除掛接之後這筆請求就失去脈絡
    board_id      TEXT NOT NULL DEFAULT '',
    room_id       TEXT NOT NULL DEFAULT '',
    requester_actor_key TEXT NOT NULL,
    requester_name      TEXT NOT NULL DEFAULT '',
    -- 🔑 **session_key 與 participant_id 雙存**（Hub #267 提案，艾斯維爾未
    -- 表異議即定案）。participant_id 會隨著離房消失，而請求要活得比一次在場
    -- 更久；session_key 則是通知找得到人的依據。少了任何一邊都有一種情境
    -- 對不上人：只有 participant 的話對方重開就找不到，只有 session_key 的話
    -- 畫面上指不出是房裡的哪一位
    target_participant_id TEXT,
    target_session_key    TEXT NOT NULL DEFAULT '',
    target_name           TEXT NOT NULL DEFAULT '',
    note          TEXT NOT NULL DEFAULT '',
    -- pending / accepted / declined / cancelled / expired
    status        TEXT NOT NULL DEFAULT 'pending',
    created_at    TEXT NOT NULL,
    resolved_at   TEXT,
    -- 發起者被告知結果的時刻。**存時間不存布林**：布林只說得出「通知過了」，
    -- 而排查「他到底有沒有收到」時要問的是「什麼時候」。
    -- 回過就標記，否則 watcher 重啟後會把三天前的答覆再通知一次——那種
    -- 「舊事重播」比沒有通知更難信任
    requester_notified_at TEXT
);
-- 同一張卡對同一個人**只能有一筆待回應的請求**。三個人各自請求同一個對象
-- 是合理的（他們不知道彼此），但同一個人連按三次不該生出三筆——那會讓對方
-- 的收件匣出現三則一模一樣的東西，而拒絕一則之後另外兩則還在
CREATE UNIQUE INDEX IF NOT EXISTS idx_btask_req_one_pending
    ON board_task_request(task_id, target_session_key)
    WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_btask_req_target
    ON board_task_request(target_session_key, status);
CREATE INDEX IF NOT EXISTS idx_btask_req_room
    ON board_task_request(room_id, status);

CREATE TABLE IF NOT EXISTS board_event (
    board_id       TEXT NOT NULL REFERENCES board(id),
    board_seq      INTEGER NOT NULL,
    event_type     TEXT NOT NULL,
    actor_key      TEXT NOT NULL DEFAULT '',     -- 做這件事的人
    actor_name     TEXT NOT NULL DEFAULT '',
    -- directive 專用：這則是「送給誰」的。event 本身已有 actor_key（送出者），
    -- 目標得另存一欄，否則 Supervisor 的判斷投遞不出去
    target_actor_key TEXT NOT NULL DEFAULT '',
    origin_room_id TEXT NOT NULL DEFAULT '',
    item_kind      TEXT NOT NULL DEFAULT '',
    item_id        TEXT NOT NULL DEFAULT '',
    payload_json   TEXT NOT NULL DEFAULT '{}',
    created_at     TEXT NOT NULL,
    PRIMARY KEY (board_id, board_seq)
);
-- 一次 Board 變更只留一筆 canonical event，掛三房不會變三筆（驗收條件 8）。
-- directive 的收件匣查詢走這條
CREATE INDEX IF NOT EXISTS idx_board_event_target
    ON board_event(target_actor_key, board_seq) WHERE target_actor_key != '';

-- ── 想法板（ScratchPad）─────────────────────────────────────────────
-- 「有時候我並沒有辦法馬上都把任務給組織好，我會先把想到的想法給放進去」
-- （艾斯維爾 2026-09-02）。所以它刻意**不是**卡：卡要求你先決定標題、
-- 層級與歸屬，而那正是想法還沒成形時給不出來的東西。
--
-- 🚨 **本文是一串有 id 的段落，不是一個 Markdown 字串。** 這不是實作偏好，
-- 是艾斯維爾那條裁決逼出來的形狀：「agent 也不能改人類的段落，只能註解」。
-- 整份一個 content 欄位的話，「人類的段落」在資料上根本不存在 ⇒ 守門實作
-- 不出來，只能靠 agent 自律——**而自律不是守門，是期望**。
-- 更糟的是自由文字的編輯（併段、拆段、上下調換）會讓段落與 id 的對應消失，
-- 任何重新推斷都是猜的，猜錯的結果是某段的作者從人類變成 agent ⇒
-- **保護自己被靜默地解除**（@開發Novia (UI) 2026-09-02）。
CREATE TABLE IF NOT EXISTS board_scratchpad (
    id          TEXT PRIMARY KEY,
    board_id    TEXT NOT NULL REFERENCES board(id),
    title       TEXT NOT NULL,
    -- 整份**結構**的版本（段落的增刪與排序）。段落內容各自有自己的 rev，
    -- 所以兩個人改不同段落不會互相衝突——那正是分段的另一個好處
    rev         INTEGER NOT NULL DEFAULT 1,
    -- 🚨 段落順序的號碼來源。**不能用 SELECT MAX(order_index)+1**：那中間
    -- 有 await 讓出點，兩路同時加段落會各自算到同一個號，於是雙 200 而順序
    -- 重複（審核用Codex-2 2026-09-02）。與 board_seq 完全同一個模式——
    -- 單一 UPDATE…RETURNING 領號，永遠遞增、永遠不重複
    next_order  INTEGER NOT NULL DEFAULT 0,
    board_seq   INTEGER NOT NULL DEFAULT 0,
    created_by_actor_key TEXT NOT NULL DEFAULT '',
    created_by_name TEXT NOT NULL DEFAULT '',
    updated_by_actor_key TEXT NOT NULL DEFAULT '',
    updated_by_name TEXT NOT NULL DEFAULT '',
    deleted     INTEGER NOT NULL DEFAULT 0,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_scratchpad_board
    ON board_scratchpad(board_id, board_seq);

CREATE TABLE IF NOT EXISTS board_scratchpad_block (
    id           TEXT PRIMARY KEY,
    scratchpad_id TEXT NOT NULL REFERENCES board_scratchpad(id),
    board_id     TEXT NOT NULL,
    content      TEXT NOT NULL DEFAULT '',
    order_index  INTEGER NOT NULL DEFAULT 0,
    author_actor_key TEXT NOT NULL DEFAULT '',
    author_name  TEXT NOT NULL DEFAULT '',
    -- 🚨 守門看的就是這一欄。**只有明確的 human 才算人類**，空值一律當
    -- agent：兩種誤判裡只有一種是安靜的——把 agent 誤認為人類會解除保護而
    -- 沒有人發現；把人類誤認為 agent 會讓他改不動別人的段落，他會馬上抱怨。
    -- 所以往吵的那一邊倒。
    author_kind  TEXT NOT NULL DEFAULT '',
    -- 分類標籤（艾斯維爾想法板觀察 ④）。**JSON 陣列而不是單一欄位**：
    -- 定案是單選，但 schema 選寬、行為選窄——之後改成多選時不必動資料，
    -- 反過來（存單一 TEXT）有一半機率要遷移。UI 只給選一個。
    --
    -- 標在**段落**不標在板：同一份想法板裡的段落性質常常各不相同（艾斯維爾
    -- 那六則就是兩則 bug、三則新功能、一則權限設計），標在板上等於標不出
    -- 任何東西
    tags         TEXT NOT NULL DEFAULT '[]',
    -- 這一段後來怎麼了：'' / implemented / abandoned（09/06，艾斯維爾）。
    --
    -- 與 tags **正交**：標籤是分類（bug/feature/design），狀態是結局。
    -- 一段可以同時是 design 又是 abandoned，那是兩件事。
    --
    -- ⚠️ '' 不等於 abandoned。「還沒標」與「決定不做」畫成同一種，等於
    -- 替所有沒人管的段落做了決定
    state        TEXT NOT NULL DEFAULT '',
    -- 每段自己的樂觀鎖。分段之後衝突面小很多：兩個人編不同段互不影響
    rev          INTEGER NOT NULL DEFAULT 1,
    deleted      INTEGER NOT NULL DEFAULT 0,
    board_seq    INTEGER NOT NULL DEFAULT 0,
    created_at   TEXT NOT NULL,
    updated_at   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_scratchpad_block_pad
    ON board_scratchpad_block(scratchpad_id, order_index);
-- 順序不重複寫進資料庫，不靠呼叫端自律。⚠️ 重排時要先把所有 order_index
-- 移到負區間再寫回正值，否則交換兩段的中途會撞上這條
CREATE UNIQUE INDEX IF NOT EXISTS idx_scratchpad_block_order
    ON board_scratchpad_block(scratchpad_id, order_index) WHERE deleted = 0;

-- 「只能註解」的落點。**掛 block_id 不掛偏移量**——偏移量在段落被編輯後
-- 會漂到別的地方，而漂掉不會報錯，只會變成一句對不上的話。
CREATE TABLE IF NOT EXISTS board_scratchpad_note (
    id           TEXT PRIMARY KEY,
    block_id     TEXT NOT NULL REFERENCES board_scratchpad_block(id),
    scratchpad_id TEXT NOT NULL,
    board_id     TEXT NOT NULL,
    content      TEXT NOT NULL,
    author_actor_key TEXT NOT NULL DEFAULT '',
    author_name  TEXT NOT NULL DEFAULT '',
    author_kind  TEXT NOT NULL DEFAULT '',
    resolved_at  TEXT,
    deleted      INTEGER NOT NULL DEFAULT 0,
    board_seq    INTEGER NOT NULL DEFAULT 0,
    created_at   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_scratchpad_note_block
    ON board_scratchpad_note(block_id, created_at);

-- ① 留歷史：每次段落被改寫，把**改之前**那份原文留下來。
-- ⚠️ CAS 防的是「同時寫」，防不了「後來的人把你的話改掉了」——後者是合法
-- 的循序寫入，rev 對得上、回 200、沒有任何一端報錯，而那段原話就沒了。
-- **這是所有靜默失效裡最安靜的一種：它連衝突都沒有**（@測試Novia）。
CREATE TABLE IF NOT EXISTS board_scratchpad_revision (
    id           TEXT PRIMARY KEY,
    block_id     TEXT NOT NULL,
    scratchpad_id TEXT NOT NULL,
    board_id     TEXT NOT NULL,
    content      TEXT NOT NULL,          -- 改之前的內容
    rev          INTEGER NOT NULL,       -- 改之前的 rev
    author_actor_key TEXT NOT NULL DEFAULT '',   -- 原文的作者
    author_name  TEXT NOT NULL DEFAULT '',
    replaced_by_actor_key TEXT NOT NULL DEFAULT '',  -- 改掉它的人
    replaced_by_name TEXT NOT NULL DEFAULT '',
    created_at   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_scratchpad_revision_block
    ON board_scratchpad_revision(block_id, created_at);

-- ── 卡片追蹤 ───────────────────────────────────────────────────────
-- 「當追蹤的卡完成就會通知以追蹤的人，就不需要通知所有人」（艾斯維爾）。
-- ⚠️ 追蹤綁 **actor_key 不綁 participant**：participant 隨離房消失，而
-- 「我在等這張卡」不會因為我離開一間房就不成立。綁 participant 的話，
-- agent 重啟一次追蹤就靜靜地斷了——而斷掉的當下沒有任何地方會報錯。
CREATE TABLE IF NOT EXISTS board_watch (
    board_id    TEXT NOT NULL REFERENCES board(id),
    item_kind   TEXT NOT NULL,             -- task / checklist / objective
    item_id     TEXT NOT NULL,
    actor_key   TEXT NOT NULL,
    actor_name  TEXT NOT NULL DEFAULT '',
    created_at  TEXT NOT NULL,
    PRIMARY KEY (board_id, item_kind, item_id, actor_key)
);
-- 🚨 追蹤通知**不能**塞進 board_event：那張表的主鍵是 (board_id, board_seq)，
-- 一個號只放得下一筆 canonical event，而「一張卡完成」可能要通知五個人。
-- directive 走 board_event.target_actor_key 是因為它一次只有一個收件人；
-- 追蹤是一對多，形狀不同，硬塞會逼著每個收件人各領一個 board_seq——那會
-- 把水位灌成「通知數」而不是「變更數」，增量 client 讀到的東西就變了。
CREATE TABLE IF NOT EXISTS board_watch_notice (
    id          TEXT PRIMARY KEY,
    board_id    TEXT NOT NULL REFERENCES board(id),
    -- 收件人。與追蹤一樣綁 actor_key，所以重啟換 participant 也收得到
    actor_key   TEXT NOT NULL,
    item_kind   TEXT NOT NULL,
    item_id     TEXT NOT NULL,
    item_title  TEXT NOT NULL DEFAULT '',   -- 快照：卡之後被改名也講得出當時在等什麼
    event_type  TEXT NOT NULL,              -- task_done / task_cancelled / task_reopened（item_deleted 尚未實作，沒有任何地方產生它）
    -- 觸發它的那次變更的號。**不是自己領的**——它指回 board_event 的那一筆，
    -- 所以「我收到的通知」與「板上發生的事」對得起來
    board_seq   INTEGER NOT NULL DEFAULT 0,
    actor_name  TEXT NOT NULL DEFAULT '',   -- 做出那個變更的人
    created_at  TEXT NOT NULL,
    read_at     TEXT
);
CREATE INDEX IF NOT EXISTS idx_watch_notice_inbox
    ON board_watch_notice(actor_key, created_at) WHERE read_at IS NULL;

-- 「這張卡有誰在等」與「我在等哪些卡」是兩個方向，都要快
CREATE INDEX IF NOT EXISTS idx_board_watch_actor
    ON board_watch(actor_key, board_id);

CREATE INDEX IF NOT EXISTS idx_question_room ON question(room_id, status);
CREATE INDEX IF NOT EXISTS idx_question_target ON question(target_id, status);

-- ── 遠端派工（Remote Ops，REMOTE-OPS-PLAN §4）────────────────────────────
--
-- Hub 是佇列與狀態的**唯一真相**，執行器只是笨執行者：領一筆、起進程、
-- 回報、領下一筆。執行器重啟不丟佇列，Hub 看得到誰在跑、誰在排、限額狀態。

CREATE TABLE IF NOT EXISTS agent_run (
    id            TEXT PRIMARY KEY,
    room_id       TEXT NOT NULL REFERENCES room(id),
    board_id      TEXT NOT NULL DEFAULT '',
    -- investigate | ticket | stage | push（scheduled 留給 P2 的排程）
    kind          TEXT NOT NULL,
    project       TEXT NOT NULL DEFAULT '',
    -- checklist_id / task_id，push 時是 repo key
    ref           TEXT NOT NULL DEFAULT '',
    brief         TEXT NOT NULL DEFAULT '',
    -- 派工者。participant 會隨離房消失，所以**三個都存**：id 給當下的畫面、
    -- actor_key 給「這是同一個人回來了」、名字快照給事後顯示
    requested_by           TEXT NOT NULL DEFAULT '',
    requested_by_actor_key TEXT NOT NULL DEFAULT '',
    requested_by_name      TEXT NOT NULL DEFAULT '',
    -- **誰動的手**，與上面三欄分開。上面那組是「配額算誰的」：Supervisor
    -- 代派時記的是**指定它的那個人類**（艾斯維爾 2026-09-19 裁定），所以
    -- 它說不出這一筆其實是 agent 按的。human | agent，名字是房內顯示名。
    -- ⚠️ 這兩欄在 MIGRATIONS 也有一份，兩邊都要改
    requester_kind         TEXT NOT NULL DEFAULT 'human',
    requester_name         TEXT NOT NULL DEFAULT '',
    -- queued | claimed | running | limited | handoff | done | failed | cancelled
    status        TEXT NOT NULL DEFAULT 'queued',
    priority      INTEGER NOT NULL DEFAULT 0,
    position      INTEGER NOT NULL DEFAULT 0,
    runner_id     TEXT NOT NULL DEFAULT '',
    claude_session_id TEXT NOT NULL DEFAULT '',
    attempt       INTEGER NOT NULL DEFAULT 0,
    parent_run_id TEXT NOT NULL DEFAULT '',
    handoff_depth INTEGER NOT NULL DEFAULT 0,
    -- 取消請求。running 的 run 不能在 Hub 這一端直接殺，只能立旗標讓執行器
    -- 在下一次 heartbeat 收走——**狀態不先改**，否則畫面會說它停了而進程還在
    cancel_requested INTEGER NOT NULL DEFAULT 0,
    -- 收尾請求（軟停止）。與 `cancel_requested` 的分別是**誰來收場**：取消
    -- 是殺進程，收尾是讓 agent 自己把目前這一步做完、寫完摘要再結束。
    -- NULL＝沒有人請它收尾。⚠️ 這一欄在 MIGRATIONS 也有一份，兩邊都要改
    soft_stop_requested_at TEXT,
    -- 已經轉達給執行器的 @ 訊息游標（房內遞增 seq）。0＝還沒有游標，此時
    -- 只把它補到房內現況、不送任何訊息——把歷史上所有 @ 一次灌進去，等於
    -- 讓一筆剛起跑的 run 先收到一疊跟它無關的話
    mention_cursor_seq INTEGER NOT NULL DEFAULT 0,
    usage_json    TEXT NOT NULL DEFAULT '{}',
    result        TEXT NOT NULL DEFAULT '',
    reason        TEXT NOT NULL DEFAULT '',
    created_at    TEXT NOT NULL,
    claimed_at    TEXT,
    started_at    TEXT,
    ended_at      TEXT,
    updated_at    TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_agent_run_room ON agent_run(room_id, status);
-- 領單的排序鍵：priority 高的先、同 priority 先進先出
CREATE INDEX IF NOT EXISTS idx_agent_run_queue
    ON agent_run(status, priority DESC, position);
-- 同一個 ref 只能有一筆還沒結束的 run，靠 `idx_agent_run_ref_active`
-- 這條 partial unique index 擋。**它不在這份 SCHEMA 裡**：executescript
-- 是開 DB 的必經路徑，既有資料若已經違反唯一性，建在這裡等於 Hub 直接
-- 起不來。建立與退場都在 `_ensure_run_ref_unique()`。

-- 稽核串：狀態的**每一次**變化都留一筆。缺一筆就是一條看起來完整、
-- 實際上有洞的稽核串（board_event 的教訓）
CREATE TABLE IF NOT EXISTS agent_run_event (
    id          TEXT PRIMARY KEY,
    run_id      TEXT NOT NULL REFERENCES agent_run(id),
    room_id     TEXT NOT NULL,
    from_status TEXT NOT NULL DEFAULT '',
    to_status   TEXT NOT NULL,
    actor       TEXT NOT NULL DEFAULT '',
    actor_name  TEXT NOT NULL DEFAULT '',
    reason      TEXT NOT NULL DEFAULT '',
    detail_json TEXT NOT NULL DEFAULT '{}',
    created_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_agent_run_event_run
    ON agent_run_event(run_id, created_at);

CREATE TABLE IF NOT EXISTS runner (
    id            TEXT PRIMARY KEY,
    host          TEXT NOT NULL,
    label         TEXT NOT NULL DEFAULT '',
    -- online | paused | limited | offline
    status        TEXT NOT NULL DEFAULT 'online',
    max_parallel  INTEGER NOT NULL DEFAULT 3,
    running_count INTEGER NOT NULL DEFAULT 0,
    -- 允許的 project key（JSON 陣列）。領單時據此過濾。
    -- 這一欄是**公開**工作區：哪間房都綁得上、任何看得到那間房的人都
    -- 看得到這個 key
    projects      TEXT NOT NULL DEFAULT '[]',
    -- 私人工作區（JSON 陣列）。**只能綁到私人房**：公開房的成員
    -- 名單不受控制，把它當成普通工作區的話，工作區的名字跟那裡的
    -- 派工會在一間逆法人都進得來的房裡走光。
    -- 與 `projects` 分開兩欄而不是加一個旗標：同一台執行器常常兩種都有。
    -- 舊執行器不報這一欄 ⇒ '[]'，行為跟這個欄位存在之前一模一樣
    private_projects TEXT NOT NULL DEFAULT '[]',
    limited_until TEXT,
    limit_reason  TEXT NOT NULL DEFAULT '',
    usage_window_json TEXT NOT NULL DEFAULT '{}',
    -- 儀表板狀態（§4.4）：執行器每次 heartbeat 帶上，Hub **原樣存**不解讀
    dashboard_json TEXT NOT NULL DEFAULT '{}',
    -- 註冊時發的執行器憑證，**只存 sha256**（§4.3）。明文只在建立那一次
    -- 回給執行器；Hub 這邊存明文的話，一次 DB 外洩等於所有執行器被接管。
    -- 空字串＝這一欄存在之前註冊的執行器，驗證放行（見 app.py 的
    -- `_runner_authed`）——升級一次 Hub 就讓所有在跑的執行器全部 403，
    -- 而它們在遠端沒有人重跑註冊
    token_sha256  TEXT NOT NULL DEFAULT '',
    version       TEXT NOT NULL DEFAULT '',
    registered_at TEXT NOT NULL,
    last_seen_at  TEXT NOT NULL
);
-- 同 host+label 冪等：執行器重啟不該在名錄上多長一列
CREATE UNIQUE INDEX IF NOT EXISTS idx_runner_host_label
    ON runner(host, label);

-- 執行器上下線：監控面板要的「掉線／恢復」在此之前只是一則房內 system
-- 訊息，而訊息的內容是給人看的中文，機器要精準過濾就只能解析字串。
-- 為什麼不塞進 `agent_run_event`：那張表的 `run_id` 有外鍵指著 `agent_run`，
-- 而掉線這件事**沒有對應的 run**（它掉的時候手上那幾筆還在跑，但事件不屬
-- 於其中任何一筆）。
-- `room_id` 是「掉線當下還有它的 run 在跑的 ops 房」——監控面板用它決定
-- 這筆事件給不給某個人看，所以沒有房的掉線不記（沒有人在等它的機器）。
CREATE TABLE IF NOT EXISTS runner_event (
    id          TEXT PRIMARY KEY,
    runner_id   TEXT NOT NULL,
    room_id     TEXT NOT NULL,
    -- runner_offline | runner_online
    kind        TEXT NOT NULL,
    detail_json TEXT NOT NULL DEFAULT '{}',
    created_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_runner_event_created
    ON runner_event(created_at);

CREATE TABLE IF NOT EXISTS runner_command (
    id          TEXT PRIMARY KEY,
    runner_id   TEXT NOT NULL REFERENCES runner(id),
    -- pause | resume | restart | drain
    command     TEXT NOT NULL,
    issued_by   TEXT NOT NULL DEFAULT '',
    issued_by_name TEXT NOT NULL DEFAULT '',
    -- 從哪間房下的命令。**只是 provenance，沒有外鍵**：命令屬於執行器，
    -- 房刪掉不代表這筆命令的歷史要跟著消失（board_task.source_room_id 同理）
    room_id     TEXT NOT NULL DEFAULT '',
    created_at  TEXT NOT NULL,
    -- 取走的時間（Hub 在 heartbeat 把命令交給執行器時寫）
    acked_at    TEXT,
    -- 真正生效的時間（執行器在下一次 heartbeat 用 `command_acks` 回報）。
    -- 少了它，畫面上只能說「已送達」，而人要的是「已經照做了」
    applied_at  TEXT,
    -- 執行器對這筆命令講的一句話（「已暫停」「等 2 筆 run 結束後重啟」）。
    -- 沒生效也要寫：等待中的 restart 不寫理由的話，面板會停在空白
    note        TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_runner_command_pending
    ON runner_command(runner_id, acked_at);
"""

# 既有 DB 的欄位補齊：CREATE TABLE IF NOT EXISTS 對已存在的表不會加新欄，
# 這裡列出各版本新增的欄位，open_db 時缺哪補哪（可重入）。
# 注意：ALTER TABLE ADD COLUMN 的 NOT NULL 欄位必須帶 DEFAULT。
MIGRATIONS: list[tuple[str, str, str]] = [
    # (table, column, 完整欄位定義)
    ("board_scratchpad", "next_order", "next_order INTEGER NOT NULL DEFAULT 0"),
    ("board", "migrated_from_seq",
     "migrated_from_seq INTEGER NOT NULL DEFAULT 0"),
    ("room", "activated_at", "activated_at TEXT"),
    ("message", "update_seq", "update_seq INTEGER NOT NULL DEFAULT 0"),
    # 這次 update_seq 是**為什麼**被推進的（edit/delete/pin/unpin）。
    # watcher 據此判斷該不該喚醒——只看訊息現在長什麼樣的話，
    # `edited_at`/`deleted` 這種黏著狀態會讓一次無關的釘選被報成
    # 「剛被編輯」。舊資料留空字串＝不知道，client 退回舊的推斷法
    ("message", "update_kind", "update_kind TEXT NOT NULL DEFAULT ''"),
    ("message", "card_refs", "card_refs TEXT NOT NULL DEFAULT '[]'"),
    ("participant", "join_ip", "join_ip TEXT"),
    ("room", "creator_session_key", "creator_session_key TEXT"),
    ("room", "archive_pending_since", "archive_pending_since TEXT"),
    # 工作房綁定的工作區。舊 ops 房一律 NULL＝未綁定：派工前要先綁，
    # 而猜一個 key 填進去的話，派出去的工作會落在別人的工作樹上
    ("room", "workspace_key", "workspace_key TEXT"),
    # 同一個工作區一次只跑一筆。舊房一律補 1（開）：預設值要落在安全的
    # 那一邊，補成 0 的話升級一次就讓所有既有工作房開始併行動同一份工作樹
    ("room", "single_writer", "single_writer INTEGER NOT NULL DEFAULT 1"),
    # 私人工作區。舊執行器一律空陣列——把舊的 `projects` 往這一欄搬
    # 的話，升級一次就讓所有公開工作房的工作區消失（綁不了也派不了）
    ("runner", "private_projects",
     "private_projects TEXT NOT NULL DEFAULT '[]'"),
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
    # 身分群。**兩欄都是空字串起步，而空＝未知不是一群**——session 那半
    # 要等下一次心跳才補得上，把未知當成一群會讓升級當下所有 agent 互相
    # 看不見（見 db 的欄位註解與 app.py 的 `_party_of`）
    ("access_token", "party", "party TEXT NOT NULL DEFAULT ''"),
    ("session", "party", "party TEXT NOT NULL DEFAULT ''"),
    # 這個 label 是 agent 自己報的，還是別人探索到的？
    # App 只是在 lock 目錄看到一個檔案，它不知道那個 agent 叫什麼——
    # 探索到的名字只能在還沒有人自報時當佔位，不可以蓋掉自報的
    #
    # ⚠️ 預設 **0**（還沒看過自報）。一開始設 1 是怕升級的瞬間所有既有
    # session 都被收進摺疊區，結果是：舊資料全被當成已自報，而 fallback
    # 名字又不准動已自報的列——整個機制對既有資料**永遠不會生效**
    # （2026-09-14 對正式 Hub 實測，16 筆全是 True）。
    #
    # 設 0 之所以安全，是因為這一欄**每一次自報都會被翻回 1**：活著的
    # agent 下一次心跳（最長 65 秒）就自己修好了，留在摺疊區的正好是
    # 已經不在的那些。升級後短暫收起，好過一個永遠不作用的欄位。
    ("session", "label_self_reported",
     "label_self_reported INTEGER NOT NULL DEFAULT 0"),
    # 指派者的群。指派給一個**還沒上線**的 key 時建立當下判不了群，所以
    # 記下來，等兌換（join 帶 assignment_id）那一刻再比一次——兩端都關，
    # 否則「先指派、對方稍後用別群的憑證上線」就是一條繞道
    ("assignment", "party", "party TEXT NOT NULL DEFAULT ''"),
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
    # 選了選項**又補了一句**時的那一句。與 answer_options 分開存：後者是
    # 「他從我給的清單裡選的」，agent 據此判斷；自訂文字混進去那個保證就沒了。
    # 舊資料一律空字串＝沒有補充，那正是這個欄位存在之前的事實
    ("question", "answer_extra", "answer_extra TEXT NOT NULL DEFAULT ''"),
    ("question", "answer_attachments",
     "answer_attachments TEXT NOT NULL DEFAULT '[]'"),
    # 加入當下的房內 seq，@ 判定的界線。**刻意不 backfill**：舊成員的
    # NULL 一律當 0（計入全部歷史＝這個欄位存在之前的行為），語意只對新
    # join 生效才叫零破壞；猜一個值回填反而會讓舊成員漏掉真正該收的 @
    ("participant", "joined_seq", "joined_seq INTEGER"),
    ("room", "style", "style TEXT NOT NULL DEFAULT 'verbose'"),
    ("room", "style_instructions", "style_instructions TEXT NOT NULL DEFAULT ''"),
    # subagent 身分。舊資料一律 parent_id=NULL / ephemeral=0——那是這兩個欄位
    # 存在之前的實際語意（每個成員都是獨立的一般成員）。
    # 註：帶 REFERENCES 的欄位只能以 NULL 為預設值，SQLite 的 ADD COLUMN 限制
    ("participant", "parent_id", "parent_id TEXT REFERENCES participant(id)"),
    ("participant", "ephemeral", "ephemeral INTEGER NOT NULL DEFAULT 0"),
    # 群組標籤原字面。舊訊息一律空清單——那是這個欄位存在之前的事實
    # （當時沒有群組標籤），不需要也無法回推
    ("message", "mention_groups", "mention_groups TEXT NOT NULL DEFAULT '[]'"),
    # 最後一次編輯的時間。NULL＝沒被改過，那正是這個欄位存在之前的事實。
    # **刻意只存一個時間戳，不留編輯歷史**——留全歷史是稽核需求不是聊天
    # 需求，會讓 message 表隨著每次改字膨脹
    ("message", "edited_at", "edited_at TEXT"),
    # 這個成員是不是拿 .env 的主 token 進來的（＝Hub 主持人本人）。
    # 舊資料一律 0＝不知道，那正是這個欄位存在之前的事實；猜著回填會在
    # 別人的名字旁邊掛上一個他沒有的身分，比留白糟得多
    ("participant", "joined_as_host", "joined_as_host INTEGER NOT NULL DEFAULT 0"),
    # Board 的房內水位。舊房一律 0＝「板子上什麼都還沒發生」，那正是這個
    # 欄位存在之前的事實；增量 client 從 0 撈得到全量
    ("room", "board_seq", "board_seq INTEGER NOT NULL DEFAULT 0"),
    # 收所有 board 變動摘要的 session。空字串＝沒有指定，舊房一律如此
    ("room", "board_supervisor_session_key",
     "board_supervisor_session_key TEXT NOT NULL DEFAULT ''"),
    # 名字／種類／原因的快照。**參照 id 在對方離場後查不回名字**，而 board 上
    # 到處都要顯示「上一個是誰、什麼種類、為什麼不在了」。claim_name 當初存
    # 快照的理由，對這幾欄一字不差地成立。舊資料一律空字串＝不知道，那正是
    # 這些欄位存在之前的事實——猜著回填會在卡片上寫出一個沒發生過的歷史
    ("board_objective", "created_by_name", "created_by_name TEXT NOT NULL DEFAULT ''"),
    ("board_checklist", "created_by_name", "created_by_name TEXT NOT NULL DEFAULT ''"),
    ("board_task", "created_by_name", "created_by_name TEXT NOT NULL DEFAULT ''"),
    ("board_task", "claim_kind", "claim_kind TEXT NOT NULL DEFAULT ''"),
    ("board_task", "orphaned_reason", "orphaned_reason TEXT NOT NULL DEFAULT ''"),
    ("board_task", "assigned_by", "assigned_by TEXT REFERENCES participant(id)"),
    ("board_task", "assigned_by_name", "assigned_by_name TEXT NOT NULL DEFAULT ''"),
    # hold 標記的到期時間。舊資料一律 NULL＝沒有 hold，正是這個欄位存在
    # 之前的事實
    ("participant", "hold_until", "hold_until TEXT"),
    # Supervisor 的身分快照與指定紀錄。存 session_key 而不是 participant_id
    # ——supervisor 是一個**角色**，agent 重啟換了 participant 之後角色應該
    # 還在。名字／種類同樣是快照（離場之後要顯示「本來是誰在看」）
    ("room", "board_supervisor_name", "board_supervisor_name TEXT NOT NULL DEFAULT ''"),
    ("room", "board_supervisor_kind", "board_supervisor_kind TEXT NOT NULL DEFAULT ''"),
    ("room", "board_supervisor_set_by", "board_supervisor_set_by TEXT"),
    ("room", "board_supervisor_set_by_name",
     "board_supervisor_set_by_name TEXT NOT NULL DEFAULT ''"),
    ("room", "board_supervisor_set_at", "board_supervisor_set_at TEXT"),
    # 已經不在房內的時間。**標記而不是清空**（艾斯維爾 2026-09-01 拍板）：
    # 清空連名字都不留，畫面上與「從來沒有指定過」一模一樣——連「本來有人
    # 在看」這件事都消失了
    ("room", "board_supervisor_left_at", "board_supervisor_left_at TEXT"),
    # 摘要的水位與上次發送時間。摘要在 flush 時**從 board 反查**（board_seq
    # 大於這個值的列），不在每個變動點各自累積——那樣要在十幾處插樁，漏一處
    # 就是靜靜地少報一件事
    ("room", "board_digest_seq", "board_digest_seq INTEGER NOT NULL DEFAULT 0"),
    ("room", "board_digest_at", "board_digest_at TEXT"),
    # ── Board v2：items 換軸 ────────────────────────────────────────
    # 卡片從「屬於某間房」變成「屬於某塊板」。**新舊欄位並存**（§11 步驟 1）：
    # 舊 room_id 留著讓 v1 路由還讀得到，等所有 client 升級後才 rebuild 清掉。
    # 空字串＝還沒換軸的舊卡，由遷移腳本補；猜著回填會把卡掛到不存在的板上
    ("board_objective", "board_id", "board_id TEXT NOT NULL DEFAULT ''"),
    ("board_checklist", "board_id", "board_id TEXT NOT NULL DEFAULT ''"),
    ("board_task", "board_id", "board_id TEXT NOT NULL DEFAULT ''"),
    # participant 參照換成持久的 actor_key。**participant 會隨著離房消失**，
    # 而板上「誰建的、誰確認的、誰在做」要在那之後還講得出來——v1 靠的是
    # 名字快照，但快照認不出「這是同一個人回來了」，re-claim 與權限都需要
    # 一個查得回去的身分。舊列一律空字串＝不知道，那正是這些欄位存在之前
    # 的事實（當時只有 participant id 與名字快照）
    ("board_objective", "created_by_actor_key",
     "created_by_actor_key TEXT NOT NULL DEFAULT ''"),
    ("board_objective", "reviewed_by_actor_key",
     "reviewed_by_actor_key TEXT NOT NULL DEFAULT ''"),
    ("board_objective", "verified_by_actor_key",
     "verified_by_actor_key TEXT NOT NULL DEFAULT ''"),
    ("board_objective", "completed_by_actor_key",
     "completed_by_actor_key TEXT NOT NULL DEFAULT ''"),
    ("board_checklist", "created_by_actor_key",
     "created_by_actor_key TEXT NOT NULL DEFAULT ''"),
    ("board_checklist", "completed_by_actor_key",
     "completed_by_actor_key TEXT NOT NULL DEFAULT ''"),
    ("board_task", "created_by_actor_key",
     "created_by_actor_key TEXT NOT NULL DEFAULT ''"),
    ("board_task", "completed_by_actor_key",
     "completed_by_actor_key TEXT NOT NULL DEFAULT ''"),
    ("board_task", "claim_actor_key", "claim_actor_key TEXT NOT NULL DEFAULT ''"),
    ("board_task", "assignee_actor_key",
     "assignee_actor_key TEXT NOT NULL DEFAULT ''"),
    # 表是今天才建的，但已經有 Hub 跑在含表、不含這欄的版本上（8787 與 8788
    # 都重啟過）——不補這條，那些庫升上來會缺欄位而查詢直接炸
    ("board_task_request", "requester_notified_at",
     "requester_notified_at TEXT"),
    ("board_scratchpad_block", "tags", "tags TEXT NOT NULL DEFAULT '[]'"),
    ("board", "custom_tags", "custom_tags TEXT NOT NULL DEFAULT '[]'"),
    ("board_task", "assigned_by_actor_key",
     "assigned_by_actor_key TEXT NOT NULL DEFAULT ''"),
    # 來源訊息的完整座標。v1 只存 source_seq——那在一房一板時夠用，但一塊板
    # 掛多間房之後，光有 seq 講不出「是哪一間房的第幾則」。room_id 不做強
    # 外鍵、名字存快照，理由與 board_room 相同：房可以被永久刪除
    ("board_task", "source_room_id", "source_room_id TEXT NOT NULL DEFAULT ''"),
    ("board_task", "source_room_name",
     "source_room_name TEXT NOT NULL DEFAULT ''"),
    ("board_task", "source_message_id",
     "source_message_id TEXT NOT NULL DEFAULT ''"),
    # 板的結局。既有的板一律是 ''（還在做）——把存量悄悄標成「已完成」會讓
    # 它們一次從 BOARDS 分頁消失，與 visibility 當初的遷移是同一個判斷
    ("board", "outcome", "outcome TEXT NOT NULL DEFAULT ''"),
    # 段落的結局。存量一律 ''（還沒標）——與 board.outcome 同一個判斷：
    # 把既有的東西悄悄標成某個結局，等於替沒人管的段落做了決定
    ("board_scratchpad_block", "state", "state TEXT NOT NULL DEFAULT ''"),
    # 這張 token 是發給人還是發給 agent（'human' / 'agent'）。
    # **存量一律 agent**——那正是這一欄存在之前的事實：舊 token 都是在「所有
    # 憑證權限相同」的年代發出去的，沒有任何一張被審視過「該不該當人類用」。
    # 反過來預設成 human 會把整個機制的方向弄反：一次升級就讓外面每一張 token
    # 都當得了主持人，而且不會有任何地方報錯。
    ("access_token", "audience", "audience TEXT NOT NULL DEFAULT 'agent'"),
    # 這張卡的工作搬去哪了（`status='moved'` 時指向新卡）。空字串＝搬走了但
    # 還沒說去向，那是真實的中間狀態：跨週期搬遷常常是先把舊卡收掉、新週期
    # 開起來才建新卡。存量一律空——這一欄存在之前沒有 moved 這個狀態
    ("board_task", "moved_to", "moved_to TEXT NOT NULL DEFAULT ''"),
    # 這間房原先掛的板被**刪掉**了（09/07 卡 029e24f6）。刪板是硬刪，
    # `board_room` 的列跟著消失 ⇒ 進行中的房自然變回「沒綁板」（那正是要的），
    # 但**封存房從此說不出自己曾經有過板**——那間房不會再綁新的，「沒綁板」
    # 對它是錯的說法。名字存快照：沒有名字的訃聞等於沒有訃聞，而板已經不在
    # 了，事後查不回來。空字串／NULL＝沒發生過這件事
    ("room", "deleted_board_name", "deleted_board_name TEXT NOT NULL DEFAULT ''"),
    ("room", "deleted_board_at", "deleted_board_at TEXT"),
    # 房間類型（REMOTE-OPS-PLAN §4.1）。**既有房一律 chat**——那正是這一欄
    # 存在之前的實際行為（所有房都走「無 active agent 即自動封存」）。
    # 反過來預設成 ops 會讓整個 Hub 上的房間全部停止自動封存，而沒有任何
    # 地方會報錯。⚠️ 這一欄在 SCHEMA 的 CREATE TABLE 也有一份，兩邊都要改
    ("room", "kind", "kind TEXT NOT NULL DEFAULT 'chat'"),
    # 執行器憑證的 hash（REMOTE-OPS-PLAN §4.3）。既有列一律空字串＝沒有
    # 憑證，驗證照舊放行；下一次 register 會補發一把（`register_runner`）
    ("runner", "token_sha256", "token_sha256 TEXT NOT NULL DEFAULT ''"),
    # 這個成員是哪一筆 run 帶進來的（REMOTE-OPS-PLAN §5.4）。既有成員一律
    # 空字串＝不是 run 帶進來的，那正是這一欄存在之前的事實。猜著回填會在
    # 下一次 run 結束時把一般成員一起請出房間，而他本人什麼都沒做
    ("participant", "run_id", "run_id TEXT NOT NULL DEFAULT ''"),
    # 命令回饋鏈（REMOTE-OPS-PLAN §5.7）。既有命令的 applied_at 是 NULL＝
    # 這一欄存在之前下的，沒有人回報過生效；回填成 acked_at 會讓那些命令
    # 看起來「已生效」，而那是 Hub 自己編的
    ("runner_command", "applied_at", "applied_at TEXT"),
    ("runner_command", "note", "note TEXT NOT NULL DEFAULT ''"),
    # 發話者 kind 的快照（REMOTE-OPS-PLAN §12 待辦 3）。既有訊息一律空字串，
    # 由 `_migrate_data` 版次 4 從 participant 回填一次；回填不到的（成員列
    # 已經被刪掉的）留空＝說不出來，由 client 自行退回舊的反查法
    ("message", "sender_kind", "sender_kind TEXT NOT NULL DEFAULT ''"),
    # 收尾請求（軟停止）。既有 run 一律 NULL＝沒有人請它收尾，那正是這一欄
    # 存在之前的事實。回填成任何時間戳都會讓一筆正在跑的 run 在下一次心跳
    # 被要求收尾，而沒有人按過那顆鈕
    ("agent_run", "soft_stop_requested_at", "soft_stop_requested_at TEXT"),
    # @ 轉達的游標。既有 run 一律 0＝還沒有游標；0 的處理是「補到房內現況、
    # 不送」（見 app.py 的 `_collect_run_mentions`），不是「從第一則開始送」
    ("agent_run", "mention_cursor_seq",
     "mention_cursor_seq INTEGER NOT NULL DEFAULT 0"),
    # 派工者身分（Supervisor 自派工，2026-09-19）。既有 run 一律 human＝
    # 這兩欄存在之前，建單就只有人類做得到，那正是事實。預設成 agent 會讓
    # 所有歷史 run 的房內訊息開始說「由 Supervisor 派工」，而沒有人派過
    ("agent_run", "requester_kind",
     "requester_kind TEXT NOT NULL DEFAULT 'human'"),
    # 名字留空＝說不出來；回填成 requested_by_name 會把「配額算誰的」那個
    # 人寫成動手的人，而這兩件事正是這一欄要分開的
    ("agent_run", "requester_name",
     "requester_name TEXT NOT NULL DEFAULT ''"),
]

# 依賴「欄位補齊之後」才能建立的索引。
# 不能放進 SCHEMA：executescript 在 _migrate **之前**跑，對舊 DB 而言那時
# participant 還沒有 parent_id 欄位，整份 SCHEMA 會在這一行炸掉——而它是
# 開 DB 的必經路徑，等於舊資料庫一律開不起來
POST_MIGRATION_INDEXES: list[str] = [
    "CREATE INDEX IF NOT EXISTS idx_participant_parent"
    " ON participant(parent_id, status)",
    # Board v2 的增量讀取以 board_id 為軸。這三條與 v1 的 idx_b*_room 並存，
    # 換軸期間兩邊都要走得動
    "CREATE INDEX IF NOT EXISTS idx_bobjective_board"
    " ON board_objective(board_id, board_seq)",
    "CREATE INDEX IF NOT EXISTS idx_bchecklist_board"
    " ON board_checklist(board_id, board_seq)",
    "CREATE INDEX IF NOT EXISTS idx_btask_board"
    " ON board_task(board_id, board_seq)",
    # 孤兒判定 v2 改看 actor 在**所有掛接房**的 presence，撈的是 actor_key
    "CREATE INDEX IF NOT EXISTS idx_btask_claim_actor"
    " ON board_task(claim_actor_key) WHERE claim_state = 'held'",
    # 「未分類」的去重換軸：**一塊板一組**，不是一間房一組。
    #
    # 舊的 idx_bobjective_uncategorised 以 room_id 為軸，而 H9 之後板可以
    # 沒有房 ⇒ 所有無房的板共用 `room_id=''` ⇒ 第二塊板會查到第一塊的未分類。
    # 兩條並存：舊的還在保護未換軸的卡（它們的 room_id 一定有值），
    # 新的用 `board_id != ''` 排除掉那些，兩者不會互相擋到。
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_bobjective_uncat_board"
    " ON board_objective(board_id)"
    " WHERE deleted = 0 AND title = '未分類' AND board_id != ''",
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_bchecklist_uncat_board"
    " ON board_checklist(board_id)"
    " WHERE deleted = 0 AND title = '未分類' AND board_id != ''",
]


# ── Board v2 步驟 8：把 item 三表重建成「不綁房間生命週期」的形狀 ──────
#
# v1 一房一板時，`room_id TEXT NOT NULL REFERENCES room(id)` 是對的：卡本來
# 就屬於那間房。v2 之後板是獨立實體，那條外鍵變成一個**會刪掉資料的約束**
# ——`PRAGMA foreign_keys=ON` 之下，刪掉最後一間掛接房就等於刪掉板上的卡。
#
# participant 的那幾條外鍵同理：成員隨房消失，而卡上要留下「誰建的、誰在
# 做」。名字快照與 `actor_key` 已經接手這件事，而且 actor_key 還認得出
# 「這是同一個人回來了」——participant id 從來就做不到。
#
# 留下的只有板內部的樹狀外鍵（objective_id / checklist_id）：那是同一塊板
# 裡的結構，沒有跨生命週期的問題。
#
# ⚠️ 欄位清單是手寫的。漏一欄不會報錯——它會在複製時被靜靜丟掉，而表看起來
# 一切正常。底下 `_REBUILT_COLUMNS` 與 tests/test_board_v2_rebuild.py 的
# 對帳就是為了讓「漏了」變成一個會紅的事實。
REBUILT_TABLES: dict[str, str] = {
    "board_objective": """
        CREATE TABLE board_objective__v2 (
            id          TEXT PRIMARY KEY,
            -- 房間只是 provenance，不再是所有者：**沒有外鍵、可以是空字串**
            room_id     TEXT NOT NULL DEFAULT '',
            board_id    TEXT NOT NULL DEFAULT '',
            title       TEXT NOT NULL,
            description TEXT NOT NULL DEFAULT '',
            status      TEXT NOT NULL DEFAULT 'active',
            order_index INTEGER NOT NULL DEFAULT 0,
            created_by  TEXT,
            created_by_name TEXT NOT NULL DEFAULT '',
            created_by_actor_key TEXT NOT NULL DEFAULT '',
            reviewed_by  TEXT,
            reviewed_by_actor_key TEXT NOT NULL DEFAULT '',
            reviewed_at  TEXT,
            verified_by  TEXT,
            verified_by_actor_key TEXT NOT NULL DEFAULT '',
            verified_at  TEXT,
            completed_by TEXT,
            completed_by_actor_key TEXT NOT NULL DEFAULT '',
            completed_at TEXT,
            deleted     INTEGER NOT NULL DEFAULT 0,
            board_seq   INTEGER NOT NULL DEFAULT 0,
            created_at  TEXT NOT NULL
        )
    """,
    "board_checklist": """
        CREATE TABLE board_checklist__v2 (
            id           TEXT PRIMARY KEY,
            room_id      TEXT NOT NULL DEFAULT '',
            board_id     TEXT NOT NULL DEFAULT '',
            -- 板內部的樹狀關係保留外鍵：同一塊板裡的結構，沒有跨生命週期問題
            objective_id TEXT NOT NULL REFERENCES board_objective(id),
            title        TEXT NOT NULL,
            description  TEXT NOT NULL DEFAULT '',
            status       TEXT NOT NULL DEFAULT 'open',
            order_index  INTEGER NOT NULL DEFAULT 0,
            created_by   TEXT,
            created_by_name TEXT NOT NULL DEFAULT '',
            created_by_actor_key TEXT NOT NULL DEFAULT '',
            completed_by TEXT,
            completed_by_actor_key TEXT NOT NULL DEFAULT '',
            completed_at TEXT,
            deleted      INTEGER NOT NULL DEFAULT 0,
            board_seq    INTEGER NOT NULL DEFAULT 0,
            created_at   TEXT NOT NULL
        )
    """,
    "board_task": """
        CREATE TABLE board_task__v2 (
            id           TEXT PRIMARY KEY,
            room_id      TEXT NOT NULL DEFAULT '',
            board_id     TEXT NOT NULL DEFAULT '',
            checklist_id TEXT NOT NULL REFERENCES board_checklist(id),
            title        TEXT NOT NULL,
            description  TEXT NOT NULL DEFAULT '',
            status       TEXT NOT NULL DEFAULT 'todo',
            order_index  INTEGER NOT NULL DEFAULT 0,
            priority     TEXT NOT NULL DEFAULT 'normal',
            claim_participant_id TEXT,
            claim_session_key    TEXT NOT NULL DEFAULT '',
            claim_actor_key      TEXT NOT NULL DEFAULT '',
            claim_name           TEXT NOT NULL DEFAULT '',
            claim_kind           TEXT NOT NULL DEFAULT '',
            claim_state          TEXT NOT NULL DEFAULT '',
            claimed_at           TEXT,
            orphaned_at          TEXT,
            orphaned_reason      TEXT NOT NULL DEFAULT '',
            moved_to             TEXT NOT NULL DEFAULT '',
            source_seq        INTEGER,
            source_room_id    TEXT NOT NULL DEFAULT '',
            source_room_name  TEXT NOT NULL DEFAULT '',
            source_message_id TEXT NOT NULL DEFAULT '',
            assignee_participant_id TEXT,
            assignee_actor_key      TEXT NOT NULL DEFAULT '',
            assigned_by             TEXT,
            assigned_by_name        TEXT NOT NULL DEFAULT '',
            assigned_by_actor_key   TEXT NOT NULL DEFAULT '',
            created_by   TEXT,
            created_by_name TEXT NOT NULL DEFAULT '',
            created_by_actor_key TEXT NOT NULL DEFAULT '',
            completed_by TEXT,
            completed_by_actor_key TEXT NOT NULL DEFAULT '',
            completed_at TEXT,
            deleted      INTEGER NOT NULL DEFAULT 0,
            board_seq    INTEGER NOT NULL DEFAULT 0,
            created_at   TEXT NOT NULL
        )
    """,
}

# 重建之後要補回來的索引。**不重建就是安靜地變慢**，而慢到被發現時
# 沒有人會想到是半年前那次 rebuild
REBUILT_INDEXES: list[str] = [
    "CREATE INDEX IF NOT EXISTS idx_bobjective_room"
    " ON board_objective(room_id, board_seq)",
    "CREATE INDEX IF NOT EXISTS idx_bchecklist_room"
    " ON board_checklist(room_id, board_seq)",
    "CREATE INDEX IF NOT EXISTS idx_btask_room ON board_task(room_id, board_seq)",
    "CREATE INDEX IF NOT EXISTS idx_btask_checklist"
    " ON board_task(checklist_id, status)",
    "CREATE INDEX IF NOT EXISTS idx_btask_claim"
    " ON board_task(claim_participant_id) WHERE claim_state = 'held'",
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_bobjective_uncategorised"
    " ON board_objective(room_id) WHERE deleted = 0 AND title = '未分類'",
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_bchecklist_uncategorised"
    " ON board_checklist(objective_id) WHERE deleted = 0 AND title = '未分類'",
]


async def _needs_room_fk_rebuild(db: aiosqlite.Connection) -> bool:
    """還綁著 room 外鍵的話就要重建。做完之後這個查詢自然回 False。"""
    rows = await (
        await db.execute("PRAGMA foreign_key_list(board_task)")
    ).fetchall()
    return any(r["table"] == "room" for r in rows)


async def _rebuild_board_tables(db: aiosqlite.Connection) -> None:
    """SQLite 的 12 步驟換表法（建新→複製→刪舊→改名→補索引）。

    `legacy_alter_table=ON` 是必要的：關掉的話 RENAME 會順手改寫**其他表**
    對它的外鍵定義，於是剛重建好的乾淨表又被指回舊名字。
    """
    await db.execute("PRAGMA foreign_keys=OFF")
    await db.execute("PRAGMA legacy_alter_table=ON")
    try:
        for table, ddl in REBUILT_TABLES.items():
            cols = [
                r["name"]
                for r in await (
                    await db.execute(f"PRAGMA table_info({table})")
                ).fetchall()
            ]
            await db.execute(ddl)
            names = ", ".join(cols)
            await db.execute(
                f"INSERT INTO {table}__v2 ({names}) SELECT {names} FROM {table}"
            )
            await db.execute(f"DROP TABLE {table}")
            await db.execute(f"ALTER TABLE {table}__v2 RENAME TO {table}")
        for stmt in REBUILT_INDEXES:
            await db.execute(stmt)
        # POST_MIGRATION_INDEXES 也建在這三張表上，而 DROP TABLE 把它們一起
        # 帶走了。**少了這一圈，索引要等下一次啟動才補回來**——中間那段時間
        # 查詢照樣正確，只是慢，而慢不會有任何地方報錯
        # （@開發Novia (除錯) 2026-09-02 在三份 db 上一致重現）
        for stmt in POST_MIGRATION_INDEXES:
            await db.execute(stmt)
        await db.commit()
    finally:
        await db.execute("PRAGMA legacy_alter_table=OFF")
        await db.execute("PRAGMA foreign_keys=ON")


# 同一個 ref 的「還沒結束」定義。**不含 handoff**：交接的父 run 永遠停在
# handoff（它同時在 app.py 的 _RUN_TERMINAL 裡），把它算成還沒結束的話，
# 一張卡只要交接過一次就再也派不了工。與 app.py `create_run` 的
# `_RUN_ACTIVE` 減去 handoff 是同一組，改一邊就要改另一邊。
RUN_REF_ACTIVE_STATUSES = ("queued", "claimed", "running", "limited")

_RUN_REF_UNIQUE_INDEX = (
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_run_ref_active"
    " ON agent_run(room_id, ref)"
    " WHERE status IN ('queued','claimed','running','limited')")


async def _ensure_run_ref_unique(db: aiosqlite.Connection) -> None:
    """同房同 ref 只能有一筆進行中的 run——交給資料庫保證。

    `create_run` 的 SELECT 檢查擋不住併發：兩個請求可以同時查到「沒有」
    再各自 INSERT。那條 SELECT 留著當快速路徑，真正的唯一性在這條索引。

    **既有資料違反唯一性時不擋開機**：那是已經發生過的事，建不起來就
    記一筆 warning 退回沒有索引的狀態（行為等同今天），讓 Hub 起得來，
    由人去收拾那幾筆重複的 run。舊列一律不動——這裡沒有任何依據可以
    決定該取消哪一筆。
    """
    marks = ",".join("?" for _ in RUN_REF_ACTIVE_STATUSES)
    try:
        dups = await (await db.execute(
            "SELECT room_id, ref, COUNT(*) AS n FROM agent_run"
            f" WHERE status IN ({marks})"
            " GROUP BY room_id, ref HAVING n > 1",
            RUN_REF_ACTIVE_STATUSES)).fetchall()
    except sqlite3.Error:  # 表還不存在（更舊的 DB）：讓索引自己去試
        dups = []
    for row in dups:
        logger.warning(
            "agent_run 有重複的進行中派工：room=%s ref=%s 共 %s 筆，"
            "唯一性索引會建不起來，請先收掉多出來的那幾筆",
            row["room_id"], row["ref"], row["n"])
    try:
        await db.execute(_RUN_REF_UNIQUE_INDEX)
    except sqlite3.Error as exc:
        logger.warning(
            "idx_agent_run_ref_active 建不起來（%s）：重複派工這一關"
            "暫時只剩 create_run 的檢查擋著", exc)


async def _migrate(db: aiosqlite.Connection) -> None:
    """為舊版 DB 補上後續版本新增的欄位（冪等）。"""
    for table, column, ddl in MIGRATIONS:
        rows = await (await db.execute(f"PRAGMA table_info({table})")).fetchall()
        existing = {r["name"] for r in rows}
        if column not in existing:
            await db.execute(f"ALTER TABLE {table} ADD COLUMN {ddl}")
    for stmt in POST_MIGRATION_INDEXES:
        await db.execute(stmt)
    await _ensure_run_ref_unique(db)
    await _migrate_data(db)


# 資料遷移的版次。**與欄位遷移分開**：補欄位靠「這個欄位在不在」判斷，
# 天生冪等；改資料沒有那種自然的判準，跑第二次會把使用者後來的修改蓋回去，
# 所以要一個只前進的版次擋著。用 SQLite 內建的 `user_version`，不另立表。
DATA_VERSION = 6


async def _migrate_data(db: aiosqlite.Connection) -> None:
    """一次性的資料修正。**只前進，不重跑。**"""
    cur = await db.execute("PRAGMA user_version")
    version = (await cur.fetchone())[0]
    if version >= DATA_VERSION:
        return
    if version < 1:
        # 🚨 **存量板一律遷成 public**（艾斯維爾 2026-09-03：「現有的板都是
        # 以公開為主」）。`board.visibility` 的欄位預設是 `private`，而它到
        # 今天為止**從來沒有被讀過**——所以既有的板在資料庫裡真的存著
        # `private`（活庫實查確認）。可見性一旦開始生效，那個值立刻讓所有
        # 既有的板從所有人的 BOARDS 分頁消失，只剩建立者看得到，而且沒有
        # 任何一端會報錯。
        #
        # 這與 `room.visibility` 當初的遷移是同一個判斷：「把既有的東西悄悄
        # 變成私人，等於在使用者毫不知情的情況下讓它們從別人的列表上消失」。
        await db.execute("UPDATE board SET visibility='public'")
    if version < 2:
        # `label_self_reported` 第一版用 `DEFAULT 1` 加欄，於是既有的列全被
        # 當成「agent 自己報的」——而探索到的名字不准動已自報的列，整個
        # 機制對既有資料**永遠不會生效**（2026-09-14 對正式 Hub 實查，
        # 16 筆全是 True，其中大半是 App 掃 writer lock 編出來的尾碼）。
        #
        # 改 DDL 的預設值救不了已經加過欄的 DB，所以在這裡歸零一次。
        # 安全的理由與欄位本身相同：**每一次自報都會把它翻回 1**，活著的
        # agent 下一次心跳（最長 65 秒）就自己修好，留在「尚未接入聊天室」
        # 的正好是已經不在的那些。
        await db.execute("UPDATE session SET label_self_reported=0")
    if version < 3:
        # supervisor 的「已離開」原本只設不清（解除那一半不存在），所以
        # 已經回來的人身上仍掛著那個標記，而新版的 join 路徑只管**之後**
        # 的加入——它救不了已經加入完的那些。
        #
        # 只清「現在真的有 active 身分」的那些：那是正面證據，不是猜測。
        # 真的還沒回來的維持標記——那個標記本來就是要說出「本來是誰在看，
        # 但他走了」。
        # ⚠️ 清成 **NULL** 不是空字串（版次 6 一併把當初寫成空字串的那些
        # 收乾淨）：資格判準問的是 `board_supervisor_left_at IS NULL`。
        await db.execute(
            "UPDATE room SET board_supervisor_left_at=NULL"
            " WHERE board_supervisor_left_at IS NOT NULL"
            "   AND board_supervisor_left_at != ''"
            "   AND EXISTS (SELECT 1 FROM participant p"
            "               WHERE p.room_id = room.id"
            "                 AND p.session_key = room.board_supervisor_session_key"
            "                 AND p.status = 'active')"
        )
    if version < 4:
        # `message.sender_kind` 是後來才加的欄位，既有訊息全是空字串。
        # 回填一次：JOIN 得到 participant 就拿它的 kind，拿不到就留空。
        #
        # 只填 sender_id 有值的那些：系統訊息沒有發話者，硬塞一個 kind
        # 會讓 client 把 Hub 的話當成某個人說的。
        await db.execute(
            "UPDATE message SET sender_kind = COALESCE("
            "  (SELECT p.kind FROM participant p WHERE p.id = message.sender_id), '')"
            " WHERE sender_id IS NOT NULL AND sender_kind = ''"
        )
    if version < 5:
        # 遠端派工的命令有「已送出 → 已收到 → 已生效」三段，而 App 把
        # `applied_at IS NULL` 當成「還在進行中」→ 重啟鈕與恢復鈕一起停用。
        # 功能上線前、以及舊版執行器（領走命令就退出、從來不回 ack）留下的
        # 命令永遠停在第二段，正式 Hub 上有四筆從 09-17 卡到 09-18。
        #
        # 回填成 `applied_at = acked_at`，不是「現在」：那筆命令真正發生的
        # 時刻就是被取走的那一刻，寫成今天等於在面板上編一個新的事件。
        await db.execute(
            "UPDATE runner_command SET applied_at=acked_at,"
            " note='舊版執行器未回報生效，這筆命令視為已結束。'"
            " WHERE acked_at IS NOT NULL AND applied_at IS NULL")
    if version < 6:
        # supervisor 的「已離開」解除，兩邊用的寫法本來對不上：解除那一半
        # 寫的是**空字串**，而資格判準（`_board_supervisor_room`）問的是
        # `IS NULL`。於是離開過一次再回來的 supervisor，畫面上寫著他在、
        # 房裡也公告過「回來了」，確認週期與派工卻照樣 403——沒有任何地方
        # 說得出為什麼，因為兩邊各自看都完全正確。
        #
        # 以 NULL 為正，把存量的空字串一次收乾淨。空字串與 NULL 在這一欄
        # 的語意本來就是同一件事（沒有離開），只是形狀不同。
        await db.execute(
            "UPDATE room SET board_supervisor_left_at=NULL"
            " WHERE board_supervisor_left_at=''")
    await db.execute(f"PRAGMA user_version={DATA_VERSION}")


async def open_db(path: str) -> aiosqlite.Connection:
    """開啟資料庫並確保 schema 存在（含舊版 DB 的欄位升級）。"""
    db = await aiosqlite.connect(path)
    db.row_factory = aiosqlite.Row
    await db.executescript(SCHEMA)
    await _migrate(db)
    await db.commit()
    # 換表放在補欄位**之後**：新表的欄位清單含了所有 migration 加過的欄位，
    # 先換的話那些欄位還不存在，複製時會整批漏掉
    if await _needs_room_fk_rebuild(db):
        await _rebuild_board_tables(db)
    return db
