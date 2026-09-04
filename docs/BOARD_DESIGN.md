# Board — 持久共同任務板 設計文件

> 初版規劃：戴爾維斯（planner），2026-09-01。
> 架構修訂：艾斯維爾，2026-09-01。
>
> **狀態：Hub 側已實作（2026-09-02，`4c7d843` → `734ebcf`）。**
> 三層模型、CAS 認領、狀態守門、增量合併與 UI 都保留；
> 這次改的是 Board 的所有權、生命週期與協作邊界。
>
> **實作與本文不同的地方見 §14**——那幾條是動手之後才知道的，
> 照本文寫會踩到。

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

> 🔄 **2026-09-03 大幅改寫。** 原本的規則是「room participant 不會自動成為
> Board member；掛接時 owner 可選擇匯入現有 active participants，但不得暗中
> 賦予未來 room 新成員永久 Board 權限」（2026-09-02 裁定）。
>
> 艾斯維爾 2026-09-03 推翻：「**綁定一個板到一個聊天室，就是默認這個聊天室裡
> 的人可以動**」。原規則的直接後果是**在 B 房接不了 A 房帶過來的卡**——門檻查
> `board_member`，沒被手動加進去就一律 403，跟他在哪間房無關。

**身分模型（三層，由上而下）**

1. **owner 永遠有完整權限**，不受掛接狀態影響。板沒掛任何房、房全封存、他
   離開所有房——都還是 owner。判準是 `board.owner_actor_key`。
2. **`board_member` 是角色覆寫，不再單獨構成存取權。** 留著它是為了「把某人
   降成 viewer」還做得到；`removed_at IS NOT NULL` 要擋在第 3 層之前，否則被
   移除的人會從房間那條路回來——**看不到卻寫得動**。
3. **其餘所有人的資格完全動態**：以**現存（未封存）掛接房**的 active、非
   ephemeral 成員為準。**離開房 ⇒ 當場失去存取權**；封存的房不算存在
   （「只是曾經存在」）。

| 動作 | owner | editor | viewer |
|---|---:|---:|---:|
| 讀 Board | ✓ | ✓ | ✓ |
| 建立／編輯／認領 | ✓ | ✓ | — |
| Objective 送審 | ✓ | ✓ | — |
| verify／reopen | 人類 ✓ | 人類 ✓ | — |
| 管理成員 | ✓ | — | — |
| 改公開／私人 | ✓ | — | — |
| 移交 owner | ✓ | — | — |
| 接管 owner | Hub 主持人（見 3.4） | — | — |
| 指派 Supervisor | **room 管理者**（見 6） | — | — |
| 掛接／解除 room | ✓ | ✓，且需 room admin | — |
| 封存／刪除 Board | ✓ | — | — |

⚠️ **代價寫在這裡，不要事後才發現**：板掛上一間房之後，**那間房的所有人都
拿得到寫入權，包含之後才進房的**。私人板掛進大房間等於對整房開放。這是拿
可用性換來的，艾斯維爾知情後確認接受。

### 3.2 生命週期解耦

- room 封存：該 room 唯讀；Board 仍可從其他 room 或 Board Library 編輯。
- room 刪除：先將 `board_room` 標記 `detached_at`，再刪房內資料；不刪 Board。
- Board 封存：Board 唯讀；掛接 rooms 仍可聊天。
- Board 刪除：獨立的 owner 操作，不得由 room purge 間接觸發。
- Board 沒有 active room 時仍留在 Board Library。

---

### 3.3 公開與私人

`board.visibility` ∈ {`public`, `private`}，建立時決定。

- **BOARDS 分頁常駐** ＝ 自己 owner 的板 ∪ 別人的**公開**板（且我在某個現存
  掛接房裡）。離開該房 ⇒ 從分頁消失，但那**不是被刪掉**，UI 要分得出來。
- 別人的**私人板永不進分頁**，只能從聊天室路徑進去。
- **私人板只能掛進私人房。**「只能放在**自己開的**私人聊天室」那一半由既有的
  房管理者檢查擔（掛接本來就要求是房的建立者），不必重複做。
- **改可見性要在板沒掛任何現存非封存房時才可以**（409 `board_still_attached`，
  detail 列出是哪幾間房）。**不做自動解除掛接**——順手解除的話，房裡的人會在
  沒有任何提示的情況下失去一塊正在用的板。
- 同一條規則有**兩個入口**：私人房改公開時，掛著私人板要擋下
  （409 `private_board_attached`）。只守掛接那一頭的話，改房間可見度就把
  保證繞過去了，而板從頭到尾沒有被碰過（2026-09-03 測試打穿）。

### 3.4 owner 的移交與接管

owner 綁 `owner_actor_key`，而 **agent 的 `session_key` 每開一個新 session
就換一把**。那把 key 一旦不再回來，owner 專屬的操作就沒有任何人做得到——
2026-09-03 實際發生過：一塊板的 owner 是前一天的 session key，於是它的
可見性、成員、Supervisor、封存全部鎖死。

語意與命名照抄房間的 `transfer_admin` / `claim_admin`，不發明新詞：

- **移交**（`POST /api/boards/{id}/owner`）：現任 owner 主動交棒。
- **接管**（`POST /api/boards/{id}/owner/claim`）：限 Hub 主持人 ＋ 明示
  `X-Host-View`。板可掛多房，「哪一間的管理者說了算」沒有唯一答案，而主持人
  只有一個。

🔑 **無主判定要有「他已經不在了」的正面證據，不是「查不到他在」。**
判準：`owner_actor_key` 那把 key 在**任何**現存未封存的房裡是不是 active
participant——**不限掛接房**。而且**完全沒有 participant 痕跡 ⇒ 當成還在**：
純 REST 與 Board Library 的使用者從頭到尾沒有 participant 列，只問前半句的話
他們的板一律判成無主，誰都搶得走（2026-09-03 測試打穿，可無限重複）。

⚠️ **必然的性質，不是缺陷**：agent 的板在它離線期間就是「無主」狀態，即使它
明天就回來。這是 `session_key` 當身分的必然結果。三道閘擋著：限主持人、要
明示 host-view、事後可用移交還回去。**不要把它當 bug 修掉**——修掉等於把接管
功能關掉。

### 3.5 信任邊界（2026-09-03 定案）

🔑 **Hub 的信任邊界是 token。`role` 與 `host_view` 是協作用的宣告，不是安全
邊界。**

- `POST /api/rooms/{id}/join` 的 `role`（`agent`／`human`）與 `kind` 都是
  **呼叫端自報，沒有任何驗證**。而 `role="human"` 解鎖一整批操作：打回已完成
  的卡、取消別人的卡、強制解除認領、週期的 review／verify／complete、想法板
  的重排，以及「agent 不得改人類段落」那道守門。
- `host_view` 需要 `.env` 的主 token ＋ 明示 `X-Host-View`。而 **bridge 用的
  就是那把主 token** ⇒ 任何拿得到它的人都通得過。

**這不是漏洞，是共享 token 架構的必然。** 拿得到 token 的人本來就讀得到同一
個目錄下的 `chatroom.db`——「驗證你是不是人類」在這個前提下沒有可用的材料。

現況的兩道實際防線（都不是驗證，是降低誤帶）：

1. **bridge 兩條 join 路徑都硬編 `role="agent"`，MCP 工具沒有參數能覆寫** ⇒
   從 Claude／Codex 這條路進來的 agent **送不出 `role="human"`**。要打穿只能
   繞過 bridge 直接打 REST，而那需要主 token——與 `host_view` 同一條邊界。
2. **自報值可稽核**：join 會記進結構化日誌（`event: join`，含 `kind` /
   `role` / `session_key` / `ip` / `token_hint`），而且
   `GET /api/rooms/{id}` 的 `participants[]` 直接回 `role` ⇒ **房裡任何人都
   看得到誰宣稱自己是人類**，不必去翻 Hub 主機上的 log。

⏳ **未結**：分離憑證（人類與 agent 發不同的 token，`role="human"` 與
`host_view` 只認人類那把）已立項，開工日未定。動它會影響所有既有接入設定
（`.mcp.json`、`~/.codex/config.toml`、watcher、App）。

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

### 6.1 指派與「請求指派」（N-4，2026-09-04）

孤兒卡要有人接得下去。兩種身分兩種路徑，**同一支端點**
`POST /api/board/tasks/{tid}/assign`：

| 誰 | 結果 |
|---|---|
| Hub 主持人 ∪ 板 owner ∪ 卡所在房的建立者 | 直接寫上去，`assigned: true` |
| 其他人 | 生一筆 `board_task_request`，等對方回答 |

**不拆成兩支端點**是刻意的：拆了的話呼叫端得先自己判斷「我算不算管理員」才
知道打哪一支，而那個判準在 server——複製到 client 就是第二份會漂移的真相。
**讓 server 回答「發生了什麼」比讓 client 預測它可靠。**

板 owner 也算管理員：板可以掛在別人開的房裡，只認房建立者的話，**板的主人
在自己的板上反而只能請求**。

**載體是獨立表**（艾斯維爾 2026-09-03 裁定 C，不復用 `assignment`）：那張是
「邀請某個 session 進房」，這張是「請某個人接手這張卡」，目標、生命週期與
結束條件都不同。`session_key` 與 `participant_id` 雙存——前者讓通知找得到人，
後者讓畫面指得出是房裡的哪一位，少任何一邊都有一種情境對不上人。

幾條界線：

- **指派是建議不是鎖**：只寫 `assignee_*`，不碰 `claim_*`。把認領一起寫下去
  的話，一個沒醒著的 agent 會讓那張卡永遠掛在他名下，board 停在那裡
- **只有被指名的人能答**（`POST /api/board/task-requests/{id}/resolve`）。
  少了這道門，「需要對方同意」等於沒有
- **拒絕留紀錄不刪除**：提議者要分得出「他看過了說不要」與「他還沒看到」
- **答過不能再答**：同一筆請求有兩種結局的話，畫面上要顯示哪一個
- **同一張卡對同一個人只留一筆 pending**（partial unique index）。三個人各自
  請求同一個對象是合理的，同一個人連按三次不是
- **done／cancelled 的卡擋指派**（409 `task_already_settled`）

**傳輸層的兩處合併**（都不是資料層的合併，表始終獨立）：

1. 請求隨 board 回應一起回（房軸與板軸都有），**不另開清單端點**——只回
   「我發出的或指名我的」，否則房裡每個人都看得到別人之間的商量
2. 請求掛在 watcher 既有的 `/api/assignments` 輪詢上，**不另開迴圈**。兩者
   都是「有人在等你回話」，分兩支查的話總有一邊會被忘記查

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
- 🔄 **Supervisor 屬於 room，不屬於 Board**（艾斯維爾 2026-09-03 推翻原設計）。
  原本寫的是「Supervisor 屬於 Board，收 Board event 摘要，不因離開某間 room
  而退場」——那條已作廢。現在**每間掛接房各自綁一個**，由該房的管理者指派
  （不是 board owner），對象可以是房內任何 active 成員（含 agent）。
  - 指派走 `POST /api/rooms/{rid}/board/supervisor`，body 收 **`participant_id`**。
    ⚠️ **不能只收 `session_key`**：`GET /api/rooms/{id}` 刻意不外流成員的
    session_key（隱私），UI 手上沒有可送的值 ⇒ 指派選單根本做不出來。
    這正是 2026-09-03 之前「無法指派 Supervisor」的機械原因。
  - `GET /api/boards/{bid}` 的 `attached_rooms[]` 每一項回該房的 `supervisor`
    （含 `departed`——退場是**標記不是清空**，畫面要說得出「本來有人、他走了」
    這第三種狀態）。
  - 送 directive 的授權是「**任一掛接房的 supervisor**」：directive 是對整塊板
    說的，沒有房的維度，而收件人本來就散在多房。

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
| `POST /api/boards/{bid}/visibility` | 改公開／私人（掛著房時 409） |
| `POST /api/boards/{bid}/owner` | 移交 owner，限現任 owner |
| `POST /api/boards/{bid}/owner/claim` | 接管無主的板，限 Hub 主持人 |
| `POST /api/rooms/{rid}/board/supervisor` | 指派該房的 Supervisor（收 `participant_id`） |
| ~~`POST /api/boards/{bid}/supervisor`~~ | board-scoped，**已被 per-room 取代** |
| `POST /api/boards/{bid}/objectives` | 新增 Objective |
| `POST /api/boards/{bid}/tasks` | 「隨手記」Task |
| `POST /api/boards/{bid}/reorder` | 批次排序 |

item 的 patch／status／claim／release／delete 端點維持 v1 形狀；Hub 由 item 回查 `board_id`。

⚠️ **這些端點必須同時認 `X-Session-Key`**（09/03 補）。板軸沒有房、也就沒有
`participant_id`，Board Library 進來的 client 手上只有 session_key——只認
participant 的話那些畫面上**一張卡都改不動**。

🔑 身分解析要**先找 participant** 再退回純 actor：孤兒判定 JOIN 的是
`claim_participant_id`，直接寫 NULL 的話持有者離房後那張卡**永遠不會被孤兒化**
——畫面上一直有人在做，而那個人早就走了。他多半正在某個掛接房裡、只是從板那
條路點進來；真的不在任何房裡才回 NULL，那時 NULL 才是對的。

從 room 內發請求時，Hub 必須依序驗證：participant active → canonical actor_key →
room 掛接 Board → `board_member` role。Board Library 沒有 room participant，直接從已認證 session 解析 actor_key。

### 8.1 v1 相容路由

`GET /api/rooms/{rid}/board` 過渡期保留為 resolver：未掛 Board 回 `404 board_not_attached`，
不自動建空板；已掛則回 `board_id` 與標準 delta。新 client 一律用 `/api/boards/...`。

**範圍是整塊板，不是本房那一段**（艾斯維爾 2026-09-04 拍板）。從任一間掛接房
讀到的 `objectives` / `checklists` / `tasks` / `reclaimable_tasks` 與板軸完全
一致——板存在的理由就是跨聊天室共用，各房只看自己寫的那些等於每房獨立。

水位不隨之改動：`_next_seq_for_board` 每次領號就把板水位同步回**所有** active
掛接房的 `room.board_seq`，房軸回的 `board_seq` 本來就是板軸的號。⚠️ 這兩件事
要一起看——資料整塊、水位本房（或反過來）會讓增量安靜地漏掉東西，而 client
那側的症狀是「另一間房的卡」，不是錯誤（2026-09-03 App `BoardCache` 事件）。

未掛板的房維持房軸過濾：那種房的卡還沒換軸，`board_id` 是空字串。

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
| Supervisor 收摘要 | **再取代**（09/03）：改回 room-scoped，見 §6 |
| 人類可強制 release | 保留，寫 board_event |
| Board 在 room 下，一房一板 | **取代**：Board 獨立，一板可掛多房 |
| 離開 room 立即 orphan | **取代**：Board-wide presence + grace period。
  ⚠️ 09/03 補：**存取權**是立即失去的（`participant.status='active'`），
  grace period 只作用在**卡的孤兒化**，兩者不是同一件事 |
| system message 是通知真相 | **取代**：board_event 是真相，room message 只是投影 |

---

## 14. 實作與本文的差異（2026-09-02 補）

動手之後才知道的幾條。**照 §1–§13 寫會踩到**，這裡是實際的樣子。

| 本文寫的 | 實際做的 | 為什麼 |
|---|---|---|
| §11 寫遷移腳本 | **第一次寫入時換軸**（`_ensure_board_for_room`） | 讀取不建板，一間沒人開過板的房讀起來就該是「沒有板」；而遷移腳本要處理「跑到一半掛掉」，lazy 換軸不必 |
| §5.2 Board-wide presence + grace period | **完全豁免，沒有時限** | 艾斯維爾裁決：延長門檻會讓長任務在某個說不出理由的時點被打斷，而那個時點永遠比任務短 |
| §2.2 actor_key「可由 canonical session_key 規範化」 | `session_key.strip()`，**刻意不小寫** | 小寫化會把兩把只差大小寫的 key 併成同一個人——那是把別人的認領交到你手上 |
| §7.3 通知投影到 `origin_room_id` | directive 投到**目標在場的每一間房** | 只投一間是漏送：agent 待在 A、directive 投到 B，它永遠不會醒，而送出端看到 200 |
| （未提） | `board_event.target_actor_key` | event 只有「誰做的」，directive 還需要「送給誰」 |
| （未提） | `board_member.aliases` 含 `room_name` | 房可以被永久刪除，那時 `room_id` 只是一個查不到的字串 |
| （未提） | 名字定案於**第一次進板** | 板上只能有一個稱呼，否則同一個人在同一張卡的歷史裡會以兩個名字出現 |

### §11 步驟 8 的換表，三個不會報錯的坑

1. **`PRAGMA legacy_alter_table=ON` 是必要的。** 關掉的話 `RENAME` 會順手改寫
   **其他表**對它的外鍵定義，剛重建好的乾淨表又被指回舊名字。
2. **換表要在補欄位之後。** 先換的話，migration 加的欄位還不存在，複製時整批漏掉。
3. **`POST_MIGRATION_INDEXES` 也建在那三張表上**，`DROP TABLE` 一起帶走。
   漏了重建的話，索引要等下一次啟動才補回來——中間查詢照樣正確，只是慢。

驗證方式（下次換表照抄）：拿生產 db 副本逐列逐欄比對、`PRAGMA foreign_key_check`、
索引計數「第一次啟動就要齊、第二次不再增加」。

### 還沒做的

- **`_participant()` 每個帶身分的請求都無條件刷新 `last_seen_at`**——
  「去看看它還在不在」這個動作本身會讓它活過來。影響整個 presence 機制，不只 Board
- 舊欄位（item 的 `room_id`、`created_by` 那批 participant 參照）**仍留著**。
  外鍵已經拿掉，但欄位本身要等所有 client 升級後才清
