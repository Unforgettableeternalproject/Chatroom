# Board — 持久共同任務板 設計文件

> 初版規劃：戴爾維斯（planner），2026-09-01。
> 架構修訂：艾斯維爾，2026-09-01。
>
> **狀態：v2 架構已定案，尚未實作。**
> 目前程式仍是 v1 的「一房一板」；本文件描述下一步的目標模型。
> v1 已完成的三層模型、CAS 認領、狀態守門、增量合併與 UI 都保留；
> 這次改的是 Board 的所有權、生命週期與協作邊界。

---

## 0. 一頁摘要

| 項目 | v2 決定 |
|---|---|
| Board | **可持續的專案／Epic 工作狀態**，不屬於任一聊天室 |
| Chatroom | **臨時的討論與執行場域**，可以不掛 Board |
| 關係 | **Board 1 ← N Chatroom**；Phase 1 每間 room 最多掛一塊 Board |
| 生命週期 | 封存／刪除 room 只解除關聯，不封存或刪除 Board |
| 權限 | Board 有 owner／editor／viewer，不以 room participant 代替 |
| 身分 | 權限、認領與稽核用持久 `actor_key`；`participant_id` 只是房內 presence |
| 三層 | Objective 1—N Checklist 1—N Task（儲存維持嚴格樹） |
| 輕量使用 | Board 可選；「隨手記」隱藏預設層，不強迫每次聊天先規劃 Epic |
| 認領 | 條件式 UPDATE（CAS）；認領與進度是獨立維度 |
| 孤兒 Task | actor 在該 Board 所有掛接 room 都失去 presence 後才判定 |
| 增量 cursor | `board.board_seq`，不再存在 `room.board_seq` |
| 通知 | `board_event` 是真相來源；room message 只是投影 |
| Assignment／釘選 | 與 Board 並存，不合併 |
| Verify | 只有 Board 的人類 owner／editor；agent 只能送審 |

```text
Board（持久）
├─ Objective / Checklist / Task
├─ 成員、權限、Supervisor、board_seq
├─ Chatroom A（需求討論，可封存）
├─ Chatroom B（實作協作，可封存）
└─ Chatroom C（驗收除錯，可封存）
```

Board 保存「工作現在到哪裡」；Chatroom 保存「這次如何討論與執行」。

---

## 1. 範圍與關聯

### 1.1 獨立實體，不是獨立產品

Board 仍是 Chatroom App 的一部分，共用 Hub、認證與視覺語彙。
「獨立」指 domain entity 與 lifecycle，不是拆成另一個應用。

v1 直接重用 room 的權限、封存、long-poll 與成員，但也把 Epic 級工作面綁在
一次可被封存／刪除的臨時對話上。v2 將所有權方向反轉：房間掛接 Board。

### 1.2 掛接規則

- 一塊 Board 可同時掛在多間 active room。
- Phase 1 一間 room 最多一塊 active Board，避免對話中的目標歧義。
- room 可以沒有 Board；建房不自動建空板。
- 從 room 建 Board 時，建立者成為 owner，該 room 自動掛接。
- 掛既有 Board 需同時具備 room admin 與 Board owner／editor 權限。
- 解除掛接不刪除 Board item 或歷史。

### 1.3 三層語意

| 層 | 語意 | 例 |
|---|---|---|
| Objective | 一次可交付成果／週期，可多條並行 | Board v2 上線 |
| Checklist | Objective 底下的階段分組 | Hub 資料遷移 |
| Task | 一個 actor 可完成的葉節點 | 新增 board_room schema |

「隨手記一件事」可直接建 Task，系統放入隱藏的「未分類」 Objective／Checklist。

---

## 2. 目標 Schema

### 2.1 Board 與 room

```sql
CREATE TABLE board (
    id              TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    description     TEXT NOT NULL DEFAULT '',
    status          TEXT NOT NULL DEFAULT 'active', -- active / archived
    visibility      TEXT NOT NULL DEFAULT 'private',
    owner_actor_key TEXT NOT NULL,
    board_seq       INTEGER NOT NULL DEFAULT 0,
    supervisor_actor_key TEXT NOT NULL DEFAULT '',
    supervisor_name TEXT NOT NULL DEFAULT '',
    supervisor_kind TEXT NOT NULL DEFAULT '',
    supervisor_set_by_actor_key TEXT NOT NULL DEFAULT '',
    supervisor_set_at TEXT,
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL
);

CREATE TABLE board_room (
    id          TEXT PRIMARY KEY,
    board_id    TEXT NOT NULL REFERENCES board(id),
    -- 刻意不對 room 做強外鍵：room 刪除後仍要留下掛接歷史
    room_id     TEXT NOT NULL,
    room_name   TEXT NOT NULL DEFAULT '',
    attached_by_actor_key TEXT NOT NULL,
    attached_at TEXT NOT NULL,
    detached_at TEXT
);

CREATE UNIQUE INDEX idx_board_room_one_active_per_room
    ON board_room(room_id) WHERE detached_at IS NULL;
CREATE INDEX idx_board_room_board_active
    ON board_room(board_id) WHERE detached_at IS NULL;
```

`board_room` 每次掛接都建新列，才能保留多次掛接／解除的歷史。
`room_id` 與名字快照不做強外鍵，否則 room purge 仍會被歷史關聯擋住。
partial unique index 明確限制 Phase 1 的「一房一 active Board」。

### 2.2 Board 成員與持久身分

```sql
CREATE TABLE board_member (
    board_id     TEXT NOT NULL REFERENCES board(id),
    actor_key    TEXT NOT NULL,
    role         TEXT NOT NULL, -- owner / editor / viewer
    display_name TEXT NOT NULL DEFAULT '',
    actor_kind   TEXT NOT NULL DEFAULT '', -- human / claude / codex / other
    added_by_actor_key TEXT NOT NULL DEFAULT '',
    added_at     TEXT NOT NULL,
    removed_at   TEXT,
    PRIMARY KEY (board_id, actor_key)
);
```

`actor_key` 是 Hub 內持久的協作者身分；現階段可由 canonical `session_key` 規範化而得。
`participant_id` 只證明 actor 現在從哪間 room 操作，不是 Board ACL、認領或稽核主鍵。

### 2.3 Board items 轉換

Objective／Checklist／Task 沿用 v1 欄位與狀態，但做以下置換：

| v1 | v2 |
|---|---|
| `room_id` | `board_id REFERENCES board(id)` |
| `*_by participant(id)` | `*_by_actor_key` + 名字／kind 快照 |
| `claim_participant_id` | `claim_actor_key` |
| `assignee_participant_id` | `assignee_actor_key` |
| 單獨 `source_seq` | `source_room_id` + `source_message_id` + `source_seq` + `source_room_name` 快照 |

`source_room_id` 刻意不做強外鍵：room 可永久刪除，Board 仍要保留 provenance。
原訊息不在時，UI 顯示不可跳轉的來源快照。

### 2.4 Board event

```sql
CREATE TABLE board_event (
    board_id       TEXT NOT NULL REFERENCES board(id),
    board_seq      INTEGER NOT NULL,
    event_type     TEXT NOT NULL,
    actor_key      TEXT NOT NULL DEFAULT '',
    actor_name     TEXT NOT NULL DEFAULT '',
    origin_room_id TEXT NOT NULL DEFAULT '',
    item_kind      TEXT NOT NULL DEFAULT '',
    item_id        TEXT NOT NULL DEFAULT '',
    payload_json   TEXT NOT NULL DEFAULT '{}',
    created_at     TEXT NOT NULL,
    PRIMARY KEY (board_id, board_seq)
);
```

item 的 `board_seq` 負責狀態增量；`board_event` 負責稽核、摘要與跨 room 通知。

---

## 3. 權限與生命週期

### 3.1 權限

| 動作 | owner | editor | viewer |
|---|---:|---:|---:|
| 讀 Board | ✓ | ✓ | ✓ |
| 建立／編輯／認領 | ✓ | ✓ | — |
| Objective 送審 | ✓ | ✓ | — |
| verify／reopen | 人類 ✓ | 人類 ✓ | — |
| 管理成員／Supervisor | ✓ | — | — |
| 掛接／解除 room | ✓ | ✓，且需 room admin | — |
| 封存／刪除 Board | ✓ | — | — |

room participant 不會自動成為 Board member。掛接時 owner 可選擇匯入現有 active participants，
但不得暗中賦予未來 room 新成員永久 Board 權限。

### 3.2 生命週期解耦

- room 封存：該 room 唯讀；Board 仍可從其他 room 或 Board Library 編輯。
- room 刪除：先將 `board_room` 標記 `detached_at`，再刪房內資料；不刪 Board。
- Board 封存：Board 唯讀；掛接 rooms 仍可聊天。
- Board 刪除：獨立的 owner 操作，不得由 room purge 間接觸發。
- Board 沒有 active room 時仍留在 Board Library。

---

## 4. 狀態與守門

- Objective：`active → review → verified → done`，另可 `cancelled`／reopen。
- Checklist：`open → done`，或 `cancelled`。
- Task：`todo / in_progress / blocked / done / cancelled`。
- Task status 與 claim 狀態正交，不把 `claimed` 放進 status。

Objective 完成前：

1. Objective 必須在 `verified`。
2. 所有未刪 Checklist 必須 `done` 或 `cancelled`。
3. 所有未刪 Task 必須 `done` 或 `cancelled`。
4. verify 只能由人類 owner／editor 執行。

人類自己送審後可自己 verify，避免單一人類的 Board 永久卡在 review。
agent 不暴露 verify 工具，Hub 仍強制 `human_only`。

---

## 5. 認領、presence 與孤兒

### 5.1 CAS

```sql
UPDATE board_task
   SET claim_actor_key = ?, claim_name = ?, claim_kind = ?,
       claim_state = 'held', claimed_at = ?, orphaned_at = NULL,
       orphaned_reason = '', board_seq = ?
 WHERE id = ? AND board_id = ? AND deleted = 0
   AND status NOT IN ('done', 'cancelled')
   AND (claim_state = '' OR claim_state = 'orphaned')
RETURNING id, claim_actor_key;
```

判定成敗用 `await cur.fetchone()`，不用 `rowcount`。人類 owner／editor 可強制 release，
並寫入 `board_event`。

### 5.2 Board-wide presence

v1 以 participant 離房直接標孤兒，v2 改為：

1. 查 actor 是否在該 Board 任一 active attached room 仍有 active participant。
2. 全部沒有才記 `board_presence_lost_at`，不立即 orphan。
3. 超過 grace period 仍無 presence，才將 held Tasks 標 `orphaned`。
4. Board member 被 owner 移除時可立即 orphan，理由為 `member_removed`。

離開其中一房不等於放棄 Board Task。默認不做 claim TTL，長任務不應因對話沉默被搖走。

### 5.3 Re-claim

同一 `actor_key` 回來後不自動收回 orphaned Task。讀 Board 時列出 `reclaimable_tasks`，
actor 必須明確 claim；成功時回 `reclaimed: true`。

---

## 6. 來源訊息與 Assignment

Task 來源存 `source_room_id`、`source_message_id`、`source_seq`、`source_room_name`。
跳轉用 room id + seq，message id 用於驗證，名字用於 room 刪除後的快照。

Assignment 是邀請／喚醒 agent 進入某間 room；Board claim 是持久工作責任。
建 Task 時可選擇開 assignment，但必須指定一間 attached room；接受邀請不自動 claim。

---

## 7. 增量同步、事件與通知

### 7.1 Cursor

- `board.board_seq` 是每塊 Board 獨立的單調遞增整數。
- 任何 item 變更（含軟刪除）都要領新號。
- 同一操作的多列變更共用一號。
- `after_board_seq=0` 回全量；增量回 tombstone，全量不回。

```http
GET /api/boards/{board_id}?after_board_seq=N
```

### 7.2 Room long-poll 與 WebSocket

`GET /api/rooms/{id}/updates` 可帶已知 `board_id` + `after_board_seq`。Hub 解析 room 目前掛接的 Board，
回 `board_id`、`board_seq`、`board_changed`。Board 變更後：

1. `BoardEvents.notify(board_id)` 喚醒 Board 直接訂閱者。
2. 喚醒所有 active attached rooms 的既有 `RoomEvents`，讓舊 long-poll 及時回新水位。
3. WebSocket 送 `{"type":"board", "board_id", "board_seq", "origin_room_id"}`。

喚醒只表示 client 應拉 Board delta，不等於對 agent 發 mention。

### 7.3 通知投影

`board_event` 是唯一事實紀錄，不把每件事複製成每間 attached room 的 system message。

- 重要變更可在 `origin_room_id` 投影一則 system message。
- 其他 rooms 只顯示 Board badge／摘要。
- 指定 actor 的通知以 actor_key 找 active attached-room presence，去重後傳達。
- Task 完成、Objective 送審／verify／完成保留通知；一般編輯只推水位。
- Supervisor 屬於 Board，收 Board event 摘要，不因離開某間 room 而退場。

---

## 8. Hub REST API

| Method + Path | 用途 |
|---|---|
| `POST /api/boards` | 建 Board，可帶 `origin_room_id` 掛接 |
| `GET /api/boards` | Board Library |
| `GET /api/boards/{bid}` | 讀 Board delta |
| `PATCH /api/boards/{bid}` | 改 Board 屬性 |
| `POST /api/boards/{bid}/archive` | 封存 Board，不封存 rooms |
| `DELETE /api/boards/{bid}` | 永久刪除，限 owner |
| `POST/DELETE /api/boards/{bid}/rooms/{rid}` | 掛接／解除 room |
| `POST/DELETE /api/boards/{bid}/members/...` | 管理 Board member |
| `POST /api/boards/{bid}/supervisor` | 設定／取消 Supervisor |
| `POST /api/boards/{bid}/objectives` | 新增 Objective |
| `POST /api/boards/{bid}/tasks` | 「隨手記」Task |
| `POST /api/boards/{bid}/reorder` | 批次排序 |

item 的 patch／status／claim／release／delete 端點維持 v1 形狀；Hub 由 item 回查 `board_id`。

從 room 內發請求時，Hub 必須依序驗證：participant active → canonical actor_key →
room 掛接 Board → `board_member` role。Board Library 沒有 room participant，直接從已認證 session 解析 actor_key。

### 8.1 v1 相容路由

`GET /api/rooms/{rid}/board` 過渡期保留為 resolver：未掛 Board 回 `404 board_not_attached`，
不自動建空板；已掛則回 `board_id` 與標準 delta。新 client 一律用 `/api/boards/...`。

---

## 9. MCP 工具

| 工具 | v2 契約 |
|---|---|
| `chatroom_boards()` | 列出當前 actor 可用 Boards |
| `chatroom_board(board_id, after_board_seq=None, full=False)` | 讀 Board，cursor 以 board_id 分開 |
| `chatroom_board_add(board_id, kind, ..., room_id="", source_seq=None)` | 新增 item；room_id 只是 provenance |
| `chatroom_board_update(board_id, item_id, ...)` | 更新 item |
| `chatroom_board_claim(board_id, task_id, release=False)` | 認領／放棄 |
| `chatroom_board_attach(board_id, room_id)` | 掛接 room |

v1 以 room_id 呼叫的工具可先解析 attached Board，但結果必須顯示 `resolved_board_id`。
`verify` 仍不暴露給 agent。

---

## 10. Flutter 端

- 權威路由：`/boards/:boardId`。
- 相容路由：`/rooms/:roomId/board` 解析後 redirect。
- 新增 Board Library，不以 room list 代替。
- room app bar：未掛時顯示「掛接／建立」；已掛時顯示 Board 名與 badge。
- Board 頁顯示 attached rooms，可切回來源對話。
- `BoardCache` 改以 `boardId` 為 key；room provider 只維護 `roomId -> boardId?`。
- 離開 room 不丟 Board cache；權限移除／Board 刪除才清。

視覺繼續現有左側 Objective、右側 Checklist 區段、Task 抽屜，並保留
「**色軸講誰，徽章講到哪**」。Board 封存與 room 封存必須分開呈現。

---

## 11. v1 → v2 遷移

1. 新增 `board`、`board_room`、`board_member`、`board_event`，先不刪舊欄位。
2. 只為有 items、`board_seq > 0` 或 Supervisor 的 room 建 Board；空房不生空 Board。
3. 每間 v1 room 的 Board 轉為獨立 Board，建 active `board_room`。
4. item `room_id` 轉 `board_id`；participant 參照透過 session_key 轉 actor_key，並保留快照。
5. `source_seq` 補原 room id／name／message id；room Board 欄位搬到 `board`。
6. Hub 先寫 v2，v1 routes 當 wrapper；App／Bridge 升級後才停雙讀。
7. 改完 Board-wide orphan、通知與 room purge 後，才移除 v1 保護邏輯。
8. 所有 client 升級後，再 SQLite table rebuild 清舊欄位與 wrapper 寫入路由。

---

## 12. 驗收條件

1. 同一 Board 掛 A／B 兩房，A 建 Task 後 B 與 Board Library 都及時看到同一 seq。
2. A 封存後 B 仍可寫 Board；A 只能讀房內歷史。
3. A 永久刪除後，Board、items、B 關聯與 provenance 快照仍在。
4. actor 離開 A 但仍在 B 時，claim 不得 orphan。
5. actor 離開所有 attached rooms 且超過 grace period 後才 orphan。
6. room member 但非 Board member 的 actor 不能讀寫 Board。
7. 解除 room 不刪 Board data；重新掛接可看原狀態。
8. 一次 Board 變更只有一筆 canonical event，不因掛三房變三筆。
9. 舊 room Board route 可解析同一 Board；未掛接房不自動生板。
10. 現有狀態守門、CAS、tombstone 合併與 UI 狀態測試全數保留。

---

## 13. 舊決定對照

| 舊決定 | v2 |
|---|---|
| Board 與釘選並存 | 保留 |
| Objective ＝週期，Checklist ＝階段 | 保留 |
| 三層儲存強制 | 保留，UI 隱藏預設層 |
| 只有人類能 verify | 保留，改看 Board member role |
| Checklist 完成不通知 | 保留 |
| Supervisor 收摘要 | 保留，改為 Board-scoped |
| 人類可強制 release | 保留，寫 board_event |
| Board 在 room 下，一房一板 | **取代**：Board 獨立，一板可掛多房 |
| 離開 room 立即 orphan | **取代**：Board-wide presence + grace period |
| system message 是通知真相 | **取代**：board_event 是真相，room message 只是投影 |
