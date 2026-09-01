# Board — 共同任務板 設計文件

> 規劃：戴爾維斯（planner），2026-09-01。需求來源：艾斯維爾於
> 「Chatroom 開發 09/01」房 #11，補充約束來自「開發Novia (除錯)」#14。
> 審查與定案回填：開發Novia (除錯)，同日（房 #20 / #27）。
>
> **狀態：規劃已定案，實作進行中。** 第 10 節七題全部由艾斯維爾拍板完成
> （另加一題由 Q4 的答案衍生），答案已回填到各章節。
> 審查抓到的五處缺陷已改寫進 §2.2 / §4.4 / §5.4 / §6，並在 §1.4 補上原本
> 缺席的 Objective 權限表。
>
> **2026-09-01 下午：設計稿到齊**（`Board 外觀設計.dc.html`，claude.ai/design
> 專案 `b61d1f79`）。§8 依設計稿改寫（初版的看板欄版面**作廢**），
> §1.3 補上五個名字快照欄位與 `orphaned_reason`（§1.3.1 是它們的通則），
> §2.3 的孤兒通知改為**獨立系統訊息**、§4.4 的 supervisor 退場改為
> **標記而不清空**（兩者皆艾斯維爾同日拍板，依設計）。

---

## 0. 一頁摘要

| 項目 | 決定 |
|---|---|
| Board 掛在哪 | **room 底下**，一房一板（`board_*` 表帶 `room_id`） |
| 三層關係 | Objective 1—N Checklist 1—N Task（嚴格樹） |
| 認領的並發保證 | **條件式 UPDATE（CAS）**，不是 partial unique index |
| 認領與狀態的關係 | **兩個獨立維度**。認領不是 status 的一個值 |
| 孤兒 Task | 不清空認領，改標 `orphaned`；保留原持有者與 `claimed_at` |
| re-claim | **不自動回收**，agent 明確認領才拿回（同 session_key 標 `reclaimed`） |
| 通知管線 | 沿用既有 **system message + mentions**，不開新管線 |
| 增量 cursor | Board 自己的 `room.board_seq` 計數器，經既有 `/updates` 回應捎出 |
| 與 assignment | **並存不合併**（生命週期不同層），但建 Task 時可順帶開一張 assignment |
| 與釘選 | **並存**（Q1 定案） |
| Objective ＝ 週期 | **是**，可多條並行；Checklist ＝ 階段分組（Q3 定案） |
| 誰能 verify | **只有人類**（Q4 定案）。人類自己送審不受閘 4 限制（Q8） |

---

## 1. 資料模型

### 1.1 為什麼掛在 room 底下

Hub 的每一件事都是 room-scoped：可見性（`visibility`）、封存、永久刪除、
權限（`_admin_or_403` 看 `room.creator_session_key`）、long-poll
（`events.RoomEvents` 是 per-room `asyncio.Condition`）、讀取邊界
（`_member_or_403`）。Board 若獨立於 room，這六套機制**每一套都要重造一份**，
而且會立刻長出「誰看得到這塊板」這個原本已經被 room 回答過的問題。

一房一板，不需要 `board` 表本身——board 就是「這個 room 的 objectives」。
省一層 join，也省掉「這房有兩塊板時哪塊是主的」這種沒人想回答的問題。

### 1.2 三層的語意（✅ Q3 已定案：階段分組）

需求原文：「Checklist 是達成此週期所需要的任務目標」「Objective 是週期目標」
——**兩句都指向「週期」**，字面上分不出兩者的差別。艾斯維爾拍板採下表的
解讀（Q3 選 A）：Objective ＝ 週期本身且**可多條並行**，Checklist ＝
**階段分組**（不是驗收條件清單）。因此 §1.5 的閘 3 維持「所有 checklist
完成」的寫法。

| 層 | 是什麼 | 例 |
|---|---|---|
| **Objective** | 一個**週期**本身。週期＝一次可交付的成果 | 「Board 功能上線」 |
| **Checklist** | 該週期底下的**階段分組**，是「要做完哪幾組事」 | 「Hub 端」「App 端」「測試與除錯」 |
| **Task** | 葉節點，**一個人做得完的一件事** | 「board CRUD 端點」 |

需求說「Checklist 可能包含後續測試與除錯」——這句在這個解讀裡成立：測試與除錯
是 Objective 底下的其中一個 Checklist。

### 1.3 Schema（`db.py` 的 `SCHEMA` 追加）

```sql
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
    -- 送審／確認／完成分別是誰。三個時間點要各留一份：追得出「誰確認的」
    -- 才有守門的意義，只留 completed_by 等於沒有守門紀錄
    reviewed_by TEXT REFERENCES participant(id),
    reviewed_at TEXT,
    verified_by TEXT REFERENCES participant(id),
    verified_at TEXT,
    completed_by TEXT REFERENCES participant(id),
    completed_at TEXT,
    deleted     INTEGER NOT NULL DEFAULT 0,   -- 軟刪除；增量讀取的 tombstone
    board_seq   INTEGER NOT NULL DEFAULT 0,   -- 見 §5
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
    completed_by TEXT REFERENCES participant(id),
    completed_at TEXT,
    deleted      INTEGER NOT NULL DEFAULT 0,
    board_seq    INTEGER NOT NULL DEFAULT 0,
    created_at   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_bchecklist_room
    ON board_checklist(room_id, board_seq);

CREATE TABLE IF NOT EXISTS board_task (
    id           TEXT PRIMARY KEY,
    room_id      TEXT NOT NULL REFERENCES room(id),
    checklist_id TEXT NOT NULL REFERENCES board_checklist(id),
    title        TEXT NOT NULL,
    description  TEXT NOT NULL DEFAULT '',
    -- todo / in_progress / blocked / done / cancelled
    -- ⚠️ 沒有 claimed。認領是另一個維度（見 §2.1）
    status       TEXT NOT NULL DEFAULT 'todo',
    order_index  INTEGER NOT NULL DEFAULT 0,
    priority     TEXT NOT NULL DEFAULT 'normal',  -- low / normal / high

    -- ── 認領（§2）─────────────────────────────────────────
    -- 現任／前任持有者。participant_id 跨世代會變，session_key 才是
    -- agent 的持久身分——re-claim 要靠後者才認得出「這是同一個人回來了」
    claim_participant_id TEXT REFERENCES participant(id),
    claim_session_key    TEXT NOT NULL DEFAULT '',
    claim_name           TEXT NOT NULL DEFAULT '',  -- 認領當下的 display_name
    -- ''（未認領）/ held（持有中）/ orphaned（持有者已不在房內）
    -- released 不存：主動放棄就清成 ''，那是「這張卡沒人做」的事實
    claim_state          TEXT NOT NULL DEFAULT '',
    claim_kind           TEXT NOT NULL DEFAULT '',  -- 認領當下的 kind（見下）
    claimed_at           TEXT,
    orphaned_at          TEXT,
    -- 為什麼不在了：idle（閒置移出）/ left（自行離開）/ kicked（被移出）/
    -- subagent（子代理回收）。**只有離場的當下知道**，事後從任何一張表都
    -- 查不回來——而設計稿的孤兒橫幅與系統訊息要靠它分辨措辭
    orphaned_reason      TEXT NOT NULL DEFAULT '',

    -- ── 與既有機制的連結（§3）──────────────────────────────
    -- 來源訊息的房內 seq。**存 seq 不存 message_id**，與 reply_to_seq 同一個
    -- 理由：訊息可以被軟刪除，seq 不會
    source_seq   INTEGER,
    -- 人類指定的執行者（建議，不是鎖）。認領仍要對方自己來——
    -- 指派一個沒醒著的 agent 然後把卡鎖起來，等於卡片永遠不會動
    assignee_participant_id TEXT REFERENCES participant(id),

    -- 誰指定的（設計稿：「Swift-Falcon　奈留指定 · 建議」）
    assigned_by       TEXT REFERENCES participant(id),
    assigned_by_name  TEXT NOT NULL DEFAULT '',

    created_by      TEXT REFERENCES participant(id),
    created_by_name TEXT NOT NULL DEFAULT '',  -- 見下
    completed_by TEXT REFERENCES participant(id),
    completed_at TEXT,
    deleted      INTEGER NOT NULL DEFAULT 0,
    board_seq    INTEGER NOT NULL DEFAULT 0,
    created_at   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_btask_room ON board_task(room_id, board_seq);
CREATE INDEX IF NOT EXISTS idx_btask_checklist ON board_task(checklist_id, status);
-- 孤兒釋放要靠這條：sweeper 移除成員時以 participant_id 一次撈出他領走的全部
CREATE INDEX IF NOT EXISTS idx_btask_claim
    ON board_task(claim_participant_id) WHERE claim_state = 'held';
```

`room` 追加欄位（走 `MIGRATIONS`）：

```
("room", "board_seq", "board_seq INTEGER NOT NULL DEFAULT 0"),
("room", "board_supervisor_session_key",
 "board_supervisor_session_key TEXT NOT NULL DEFAULT ''"),
-- supervisor 也要顯示得出名字與種類，且它離場後不清空（§4.4）
("room", "board_supervisor_name",
 "board_supervisor_name TEXT NOT NULL DEFAULT ''"),
("room", "board_supervisor_kind",
 "board_supervisor_kind TEXT NOT NULL DEFAULT ''"),
("room", "board_supervisor_set_by",
 "board_supervisor_set_by TEXT NOT NULL DEFAULT ''"),
("room", "board_supervisor_set_at",
 "board_supervisor_set_at TEXT NOT NULL DEFAULT ''"),
```

### 1.3.1 🔴 凡是參照 participant 的欄位，都要同時存名字快照

`claim_name` 存快照的理由（持有者離場之後 participant 查不回名字，而「上一個
是誰」正是接手的人最需要知道的一件事）**對 board 上每一處 participant 參照
一字不差地成立**。初版只有 `claim_name` 做了，其餘三處沿用 id ⇒ 設計稿上
處處要顯示的名字，到了離場之後全部變成空白。

因此成對存放：

| 參照 | 快照欄位 | 為什麼查不回 |
|---|---|---|
| `claim_participant_id` | `claim_name` / `claim_kind` | 持有者被 sweeper 掃出去、session 結束 |
| `created_by` | `created_by_name` | **建立者常常是 subagent**——回收之後那一列可能整個不在了，這是所有參照裡最先斷的一種 |
| `assigned_by` | `assigned_by_name` | 指定的人也會離開 |
| `board_supervisor_session_key` | `board_supervisor_name` / `_kind` | 它本來就是**房外**身分，指定當下可能還沒進房 |

⚠️ `assignee_participant_id`（被指定的人）**不存快照**：他是「現在該由誰做」，
不是歷史紀錄——人不在了就該看得出「這個指定已經沒有意義」，而不是留一個
看起來還有效的名字。這條與上面四個相反，是刻意的。

⚠️ `idx_btask_claim` 是 partial index，依賴 `board_task` 已存在
→ 與 `idx_participant_parent` 同樣的理由，若採 `MIGRATIONS` 路徑新增欄位，
索引要放進 `POST_MIGRATION_INDEXES`。新表本身放 `SCHEMA` 沒問題
（`CREATE TABLE IF NOT EXISTS` 在 `executescript` 階段就會建起來）。

### 1.4 狀態機

**Task**（認領維度另計，見 §2）

```
todo ──► in_progress ──► done
  │          │  ▲
  │          ▼  │
  │        blocked
  ▼
cancelled  （任何非 done 狀態都可以取消）
```

| 轉移 | 誰能觸發 |
|---|---|
| `todo → in_progress` | **持有認領的人**，或人類成員 |
| `in_progress ↔ blocked` | 持有認領的人，或人類成員 |
| `* → done` | **持有認領的人**，或人類成員。未被認領的 Task 也可由人類直接完成 |
| `* → cancelled` | 建立者或人類成員 |
| `done → in_progress`（打回） | **只有人類成員**。agent 不能把自己完成的東西再打開 |

**Checklist**

```
open ──► done          條件：底下所有 task ∈ {done, cancelled}
  └───► cancelled      且至少一個 task 是 done（全取消的清單不算完成）
done ──► open          只有人類成員（Objective 尚未 verified 時才允許）
```

**Objective**（守門重點，見 §1.5）

```
active ──► review ──► verified ──► done
   ▲          │           │
   └──────────┴───────────┘   打回（只有人類成員）
active/review ──► cancelled
```

| 轉移 | 誰能觸發 |
|---|---|
| `active → review`（送審） | **任何 active 成員**（agent 或人類）。送審是「我這邊做完了」的宣告，不是判斷 |
| `review → verified`（確認） | **只有人類成員**（Q4 定案 A）。agent 一律不給，MCP 工具也不暴露 |
| `verified → done`（完成） | 人類成員 |
| `* → cancelled` | 建立者或人類成員 |
| `review/verified → active`（打回） | 只有人類成員 |

⚠️ 這張表原本缺席（只有狀態圖沒有權限），審查時補上。缺它會讓「誰能送審」
在實作時被各自猜一次，而三個端點猜的結果不必然一致。

### 1.5 「Objective 只有在週期確認無誤後才可完成」的具體守門

這句需求的實作是**四道獨立的閘**，缺一則 `POST .../complete` 回 409：

| 閘 | 條件 | 錯誤碼 |
|---|---|---|
| 1 | Objective 目前 status 必須是 `verified` | `objective_not_verified` |
| 2 | 進 `verified` 前必須先是 `review` | `objective_not_in_review` |
| 3 | 進 `review` 前，底下**所有** checklist ∈ {done, cancelled}，且至少一個 done | `checklists_incomplete` |
| 4 | **送審者是 agent 時**，`verified_by` 不得等於 `reviewed_by` | `self_verification_not_allowed`（⚠️ 現行規則下不可達，見下） |

第 4 道原本被寫成「這整組設計的重點」——**那句話已經不成立，本節初版寫錯了**。

### ⚠️ 閘 4 在 Q4 + Q8 之下永遠不會觸發

實測（2026-09-01，T-05 完成後把守門逐一破壞驗證）：**整段換成 `if False:`，
十四條測試全綠。**

推導：

1. `verify` 端點開頭已經擋掉非人類（Q4）⇒ 呼叫者必然是人類
2. `reviewed_by == 呼叫者` 成立時，送審者就是呼叫者，也就是人類
3. ⇒ `reviewer_role != "human"` 必為 False
4. ⇒ 兩個條件**不可能同時成立**

**真正在擋「agent 自己確認自己」的是 Q4，不是閘 4。** 閘 4 是 Q4 的一個嚴格
子集，被完全吸收了——而它會變成子集，正是 Q8（人類不受閘 4 限制）造成的：
那次為了解死鎖而加的前提，把它唯一還能作用的情形也讓了出去。

**處置：保留，但在程式裡明寫它不可達。** 留著的理由是 Q4 若哪天放寬
（例如允許 supervisor 代為確認），它會立刻生效而且語意正確——屆時擋的就是
「同一個 agent 送審完自己確認」。
⚠️ **不要為它寫一條證明它有效的測試**：那條測試只會證明它自己
（要構造出能觸發它的輸入，就得先繞過 Q4）。

### 🔑 由此得到的通則：測試全綠證明不了守門有效

四道閘這一輪全部做了**破壞驗證**（逐一換成 `if False:` 看測試會不會紅），
只有閘 4 露出來。**兩道守門疊在一起時，寬的那道會把窄的吸收掉，而所有測試
照樣全綠**——因為每個案例都在寬的那道就被擋下了，窄的那道從來沒有被執行過。

新增任何守門條件之後都值得跑一次：把它拿掉，測試會不會紅？不會的話，
它不是在保護什麼，只是在旁邊站著。

既有專案的同型先例：`pin_message` 的 self-pin 判定
（`sender_id != p["id"]`，比 participant id 不比名字）。比對方式照抄那個。

⚠️ **「送審者是 agent 時」這個前提不可以省略**（審查發現，艾斯維爾當場拍板）。
Q4 定案「只有人類能 verify」，若閘 4 再無條件要求「確認者 ≠ 送審者」，那麼
**人類自己送審的 Objective 就再也沒有人能確認**——房裡的常態是只有一個人類，
那條週期會永遠卡在 `review`。閘 4 存在的目的是擋 agent 自己確認自己，不是擋人。

實作條件：

```python
# reviewed_by 那個 participant 的 role 是 'human' 時整條閘跳過
if reviewer_role != "human" and verified_by == reviewed_by:
    raise _err(409, "self_verification_not_allowed", ...)
```

**誰能 verify**：只有人類成員（Q4 定案 A）。supervisor 不代為確認——它是監督
角色，不是審核權限。

---

## 2. 認領的並發語意

### 2.1 認領是獨立維度，不是 status 的一個值

看起來把 `claimed` 塞進 `status` 最省事，但它會在孤兒那條路上壞掉：
成員被 sweeper 掃出去、Task 從 `claimed` 打回 `todo` ⇒ **一張做了一半的卡
看起來跟沒人碰過的卡一模一樣**。做到哪、誰做過，全丟了。

所以：`status` 描述「這件事進行到哪」，`claim_*` 描述「誰在這張卡上」。
兩者正交，孤兒只動後者。

### 2.2 並發保證：條件式 UPDATE（CAS），不是 partial unique index

房內名稱唯一用 partial unique index 是對的——那是**多列之間**的唯一性
（同房不能有兩個 active 的 Novia）。認領不是：一張 Task 只有一個
`claim_participant_id` 欄位，「同時只能一個人持有」是**單列的狀態轉移**，
索引管不到它。

```sql
UPDATE board_task
   SET claim_participant_id = ?, claim_session_key = ?, claim_name = ?,
       claim_state = 'held', claimed_at = ?, orphaned_at = NULL,
       board_seq = ?
 WHERE id = ?
   AND deleted = 0
   AND status NOT IN ('done', 'cancelled')
   AND (claim_state = '' OR claim_state = 'orphaned')
RETURNING id, claim_session_key
```

🔴 **判定成敗一律用 `await cur.fetchone() is not None`，不可以用
`cursor.rowcount`**（審查實測，會 100% 失敗）：

```python
cur = await db.execute(...)   # 上面那句 UPDATE ... RETURNING
row = await cur.fetchone()
if row is None:               # ← 沒命中：已被別人持有 / 已完成 / 已刪除
    ... 409 task_already_claimed（附現任持有者的 claim_name）
```

`UPDATE … RETURNING` 在 **fetch 之前** `rowcount` 是 `0`，fetch 之後才變 `1`
（sqlite3 把它當成會產生結果列的語句）。照 `rowcount == 1` 寫的話，
**每一次認領都會確實改到資料庫、卻回報「已被別人領走」**——狀態變了而
呼叫端以為沒變，是最難查的一種。既有的 `pin_message` 用的就是
`fetchone() is None`，照抄它。

SQLite 單寫入者 + aiosqlite 單一連線，這一句本身就是原子的，不需要顯式交易包裝。

**`orphaned` 也算可認領**——這是需求「同時只能被一個 Agent 領走」的正確讀法：
持有者已經不在房內，就不算「同時」。

### 2.3 ⚠️ 孤兒 Task（除錯 Novia 提出，本節是它的答案）

問題屬實：`_sweep_once()` 第 3 步會把閒置逾時的 agent 標成 `removed`，
而 agent session 結束時**沒有任何人**會去釋放它領走的 Task。不處理的話，
board 上那張卡永遠掛在一個已經不存在的 participant 上，看起來「有人在做」。

**方案：綁 participant 生命週期，標記而非清空。**

三個釋放時機，全部接在既有的離場路徑上（不新增 sweeper 迴圈）：

| 時機 | 既有函式 | 動作 |
|---|---|---|
| 閒置逾時 | `_sweep_once()` 第 3 步的 `_depart_with_subagents(...)` 之後 | held → orphaned |
| 自行退出 | `leave_room` L2185 | held → orphaned |
| 被踢出 | `kick_participant` L2247 | held → orphaned |
| subagent 回收 | `_sweep_once()` 第 2 步 | held → orphaned |

實作上抽成一個 `_orphan_claims(room_id, participant_ids) -> list[dict]`，
四個呼叫點共用。這是既有慣例：`leave_room` 已經會連帶 `_cancel_questions`、
`kick_participant` 已經會連帶撤銷 `assignment` 與 `access_token`——
**「離場要連帶處理其他表」在這個 Hub 是既有模式，不是新發明。**

```sql
UPDATE board_task
   SET claim_state = 'orphaned', orphaned_at = ?, board_seq = ?
 WHERE room_id = ? AND claim_participant_id IN (...) AND claim_state = 'held'
RETURNING id, title, claim_name
```

**為什麼不清空 `claim_participant_id`**：清掉就查不出「這張卡上一個是誰在做」，
而那正是接手的人最需要知道的一件事。保留欄位、改狀態，成本是一個字串欄位。

**要不要發系統訊息**：✅ **要，發獨立的一則**（艾斯維爾 2026-09-01 拍板，
依設計稿；本節初版寫的「附在離場訊息尾巴」已作廢）。

```
Kite 因閒置移出，「board_seq 增量 cursor」現在沒有人在上面。
```

理由是**主詞不同**。附在「某某離開了」底下的話，那句話的主詞是那個人，
而讀的人在意的是**那張卡**——「誰不在了」與「哪張卡沒人做了」是兩件事，
後者才是需要有人接手的那件。設計稿也把它畫成獨立訊息並帶「在板上開啟 →」。

⚠️ **這則不 mention 任何人**（沿用 §4.3：孤兒不是誰的待辦，是板上的事實）。
它靠 board 入口的「N 孤兒」被看見，不喚醒任何人。
⚠️ subagent 回收（第 2 步）**維持不發**——那條路徑連離場訊息都沒有，
Board 的變動靠 §5 的 cursor 被看見。

⚠️ 這則訊息要寫得出「因閒置移出」還是「session 已結束」，
所以 `_orphan_claims()` 必須收一個 `reason`，並寫進 `board_task.orphaned_reason`
（見 §1.3）——**那個資訊只有離場的當下知道，事後從任何一張表都查不回來**。

### 2.4 re-claim：不自動回收

同一個 session_key 重新 join 會拿到**新的 `participant_id`**（既有行為，
`joined_seq` 那條設計就是為此存在）。誘人的作法是 join 時自動把
`claim_session_key` 相同的 orphaned Task 認回來——**不要**。

理由：agent 重啟的原因多半是它上一輪出事了或被換掉了。自動把它三小時前
領走、做到一半、而且它自己已經完全沒有記憶的工作重新扛回身上，
board 會顯示「有人在做」而實際上沒有。這與孤兒問題是同一個病，只是換了方向。

**契約**：
- `POST /join` 的回應與 `GET .../board` 的回應都帶
  `reclaimable_tasks: [{id, title, orphaned_at, claim_name}]`
  ——同 `session_key` 且 `claim_state='orphaned'` 的那些。
- agent 看到之後**明確呼叫 claim** 才拿回。CAS 條件已經允許 orphaned，
  不必另開端點。
- 認回時若 `claim_session_key == 自己`，回應帶 `reclaimed: true`
  ——讓 agent 知道「這是你上一世領的」，它才有理由先去讀 Task 的描述。

### 2.5 逾時：預設關閉

另設 `CHATROOM_BOARD_CLAIM_TTL`（秒，**預設 0 ＝ 關閉**）。
presence sweeper 已經涵蓋「agent 消失」這個情境；claim TTL 只在
「agent 還活著但卡住」時有用，而它會把一個正在跑的長任務從人手上搶走。
預設關閉，需要的人自己開。

### 2.6 一個順帶的副作用（要提醒實作者）

`_participant()` L475 **同時是 heartbeat**（會更新 `last_seen_at`）。
Board 端點若照慣例走它，那麼「鼓勵 agent 經常調查 Board 狀態」的結果是
**經常輪詢 board 的 agent 永遠不會被閒置掃出房間**。
這多半是想要的（它確實在工作），但要有意識地知道：閒置判定從此不只看發言。

---

## 3. 與既有機制的接點

### 3.1 Task ↔ 訊息

`source_seq`（房內 seq）。存 seq 不存 message_id，與 `reply_to_seq` 同一個
理由（既有設計已寫明：內容可被軟刪除，seq 不會）。
建 Task 時可帶，UI 上點一下跳回那則訊息（`/rooms/:id?focusSeq=` 已經存在）。

### 3.2 Task 認領 ↔ 既有 assignment：**並存，不合併**

它們看起來像同一件事的兩個版本，實際上活在兩個不同的層：

| | assignment | Task claim |
|---|---|---|
| 對象 | `session_key`（房外的 agent） | `participant_id`（房內的成員） |
| 語意 | 「進這個房間」 | 「這件事我來做」 |
| 何時發生 | 對方**還沒有** participant 身分 | 對方**已經在**房裡 |
| 生命週期 | 跨房間，TTL 24h，`pending/accepted/declined/cancelled/expired/revoked` | 房內，綁 participant 生死 |
| 誰結束它 | 被指派者 resolve，或逾時 | 完成、放棄、或持有者離場 |

合併會讓 `assignment` 一張表同時背兩種生命週期與兩種對象型別——
而它現在正好是 watcher 唯一靠輪詢（不是 long-poll）取得的東西
（`GET /api/assignments` 每 10~65 秒一輪，順帶 `_touch_session`）。
把高頻的 Task 認領灌進那條輪詢，等於把 session 名錄的心跳點變成任務佇列。

**橋接（不是合併）**：建 Task 時可選帶 `invite_session_key`
→ Hub 順手用**既有的** `create_assignment` 開一張指派把人叫進房，
note 自動填「Board Task：{title}」。人進來之後照樣要自己 claim。
一條線把兩層接起來，兩張表各自維持原本的語意。

### 3.3 Task ↔ 釘選

見 **Q1（待拍板）**。我推薦並存，理由寫在那裡。

---

## 4. 通知語意

### 4.1 大原則：不開新管線

既有的喚醒設計是「**system message + mentions**」，而三側 client 全部接在
上面：watcher（`_mentions_me`，預設只推 mention）、App 的
`NotificationCenter`、Codex dispatcher（`mentions ∩ codexNames`）。
Board 若另開一條事件流，**這三側都要改**，而 watcher 那側的歷史已經證明
一次性投遞會安靜地漏（見 PM 記憶「mention 是唯一沒有重試的一次性投遞」）。

所以 Board 通知＝發一則 `kind="system"` 的訊息，收件人放進 `mentions`。
既有的 pin 收據與 `question_answered` 收據就是這個作法。

### 4.2 兩條規則

**Task 完成 → 通知「執行該 Task 以外的其他人」**

```python
recipients = 房內 active、非 ephemeral 的成員 display_name
             − 完成者本人
_post_message(room_id, sender_id=None, kind="system",
              system_event="board_task_done",
              content=f"{who} 完成了 Task「{title}」",
              mentions=recipients,
              reply_mentions_author=False)
```

⚠️ **必須傳 `reply_mentions_author=False`**——若哪天這則收據帶上
`reply_to`（指回 `source_seq` 那則訊息），`_post_message` 會把被回覆者
自動補進 mentions，把「排除執行者」這條規則從下游繞掉。
這個坑在 pin 收據上已經踩過一次（PM 記憶：「傳空 mentions 關不掉通知」）。

**Objective 完成 → 通知所有人**

```
system_event="board_objective_done"，mentions = 房內全部 active 成員（含完成者）
```

需求原文就是「全部」，完成者也在內——他確認的是週期，不是自己那張卡。

### 4.3 其餘 Board 變動一律**不** mention

新增 Task、認領、放棄、改描述、狀態改成 `in_progress`、Checklist 完成
——**全部不喚醒任何人**，只推進 `board_seq`（§5）。

這是既有原則的直接套用：「喚醒是打擾，必須值得」。一個十人在跑的 board
每分鐘會動好幾次，逐筆喚醒等於把每個 agent 的上下文塞滿別人的進度。
需求本身也只指名了兩條要通知的規則——**其餘的預設就是不通知**。

要不要為「Checklist 完成」破例，見 **Q5**。

### 4.4 Supervisor

`room.board_supervisor_session_key`（存 session_key 不存 participant_id：
supervisor 是一個**角色**，agent 重啟換 participant 之後角色應該還在）。

- 設定：`POST /api/rooms/{id}/board/supervisor {session_key}`，
  **限房間建立者**（走既有 `_admin_or_403`）。
- 收什麼：所有 Board 變動，包含 §4.3 那些不喚醒別人的。
- **怎麼收**：見 **Q6（待拍板）**。逐筆 mention 與 §4.3 的原則直接衝突
  ——supervisor 也是一個會被塞滿的 agent。我推薦**摘要**：
  Hub 累積變動，每 `CHATROOM_BOARD_DIGEST_INTERVAL`（預設 300 秒）
  或滿 N 筆才發一則彙整的系統訊息並 mention supervisor。
- **退場**：supervisor 的 session 在房內已無 active participant 時，
  **標記而不是清空**（艾斯維爾 2026-09-01 拍板，依設計稿；初版寫的
  「清空欄位」已作廢）——比照孤兒 Task 的同一套處理：名字留著、標成
  「已不在房內」、提示需要重新指定，並發一則
  `system_event="board_supervisor_left"` 的系統訊息。
  ⚠️ **不可以安靜清空**——那會變成「沒有人在監督，而且沒有人知道」，
  這正是本專案 PM 記憶裡反覆出現的失效形狀（安靜地不做事）。
  而清空**連名字都不留**，畫面上與「從來沒有指定過」一模一樣，
  是同一個病更嚴重的版本：連「本來有人在看」這件事都消失了。
  判定接在 §2.3 那同一個離場路徑上。
- 🔴 **退場判定只接在離場路徑上，不可以做成「定期檢查有沒有 active
  participant」**（審查發現）。`board_supervisor_session_key` 存的是
  **房外**身分——被指定的 agent 在設定的當下多半還沒進房（那正是要用
  assignment 把它叫進來的情形）。做成定期檢查的話，設定完的下一輪掃描就會
  把它自己清掉，而且清得完全合乎規則。
  接在離場路徑上天然帶有「他曾經進來過」這個前提，不必另存旗標。

---

## 5. 增量讀取契約

### 5.1 為什麼要有自己的 cursor

需求要「鼓勵 Agent 經常調查當前 Board 狀態」。沒有 cursor 的話每次調查都是
全量拉一整塊板，agent 的上下文會被自己的輪詢吃掉——那會讓「經常調查」
變成一件它有理由避免做的事。

### 5.2 為什麼是獨立計數器，不共用 `room.next_seq`

`_post_message` 與 `_touch_message` 都從 `room.next_seq` 領號，所以
訊息序號本來就已經有跳號。誘人的作法是 board 也共用它——一個 cursor 統管全房。

**否決。** Board 的變動量是無上限的（拖曳排序、批次建卡），共用會讓人類看到
的訊息編號從 `#11` 直接跳到 `#340`。而 `reply_to_seq` 是**畫在 UI 上給人看的**
（回覆卡片顯示「#12」）。省一個計數器，換掉訊息編號的可讀性，不划算。

用 `room.board_seq`，獨立遞增。

### 5.3 契約

三張表的每一列都有 `board_seq`。**任何**欄位變更（含軟刪除）都要領一個新的
`board_seq`；同一次請求裡的多筆變更（例如批次排序）**共用同一個號**
——一次操作一個號，這樣「這次動了什麼」才是可讀的單位。

```
GET /api/rooms/{id}/board?after_board_seq=N
```

回應：

```jsonc
{
  "board_seq": 340,          // 目前的水位，下次傳這個
  "full": false,             // after_board_seq=0 時為 true
  "objectives": [ ... ],     // 只含 board_seq > N 的
  "checklists": [ ... ],
  "tasks": [ ... ],
  "reclaimable_tasks": [ ... ],   // §2.4
  "supervisor": "claude-xxx" | null
}
```

- `after_board_seq=0` ＝ 全量（`full: true`）。
- **軟刪除的列照樣回傳**，帶 `"deleted": true`。這是 tombstone——
  增量讀取的 client 若看不到刪除事件，board 上會永遠留著一張已經不存在的卡。
  這是增量協定最常漏的一條，這裡明寫進契約。
- 排序：一律 `ORDER BY board_seq`。

### 5.4 怎麼知道 board 動了（不新增 long-poll）

**在既有的 `GET /api/rooms/{id}/updates` 加一個 query 參數 `after_board_seq`，
回應加一個欄位 `board_seq`，並在等待迴圈裡加一個返回條件。**

🔴 **三者缺一不可，只加欄位不會生效**（審查發現）。`wait_updates` 目前只有
三個返回點：查到 message 列、查到 subagent 事件、逾時。而 §4.3 明定大部分
board 變動**不發訊息** ⇒ `events.notify(room_id)` 把它叫醒後，迴圈重跑一次
發現 rows 空、subs 空、還沒到 deadline，就**再度掛回 `events.wait`**。

結果不是「board 一動就拿到新水位」，而是「最多延遲一整個 poll 週期（25 秒）」。
而且它看起來完全正常——逾時返回本來就是正常路徑，回應裡的 `board_seq` 也是
對的，只是慢。**沒有任何地方會報錯。**

要加的返回條件（放在既有 subagent peek 的旁邊，同一個位置）：

```python
# board 變動不進訊息流，所以上面那兩個查詢都看不到它。
# 少了這一段，被 events.notify 叫醒也只會再掛回去
board_now = await _board_seq(room_id)
if board_now > after_board_seq:
    return await _out([], after_seq, await _status())
```

⚠️ `after_board_seq` 省略（舊 client）時視為「不關心 board」，
**不可以**當成 0——當成 0 的話，任何有 board 資料的房間都會讓舊 client 的
long-poll 立刻返回，變成一個 25 秒 25 次的空轉迴圈。

agent 本來就掛在那條 long-poll 上（`chatroom_wait` / watcher）。多一個數字，
它比對一下自己記的水位就知道要不要去拉 board——**不必再掛第二條 long-poll**
（而 `events.RoomEvents` 是 per-room 的單一 Condition，掛兩條 long-poll 在
同一個房上會互相搶醒，PM 記憶裡已經有「一個 watcher 一個房，long-poll 互斥」
這條實測）。

Board 變更後呼叫既有的 `events.notify(room_id)` 就會把那條 long-poll 叫醒。
⚠️ **這代表 board 的每次變動都會讓所有掛著 `/updates` 的 client 醒一次**
（`notify_all`）。醒來≠喚醒 agent——watcher 那層還有 mention 過濾
（`if not all_messages and not mentioned: continue`），所以 agent 不會被打擾，
但這條要在實作票裡明寫，否則很容易被誤判成 bug。

WebSocket（App 側）同理：pump 被 `events.wait` 叫醒後多讀一次 board 水位，
新增 `{"type": "board", room_id, board_seq}` 事件。

---

## 6. Hub REST 端點

全部走既有的 `require_auth` + `X-Participant-Id`（`_participant`），
且**每一條都要先 `_room_or_404` 再判身分**——順序相反會產生
「403 叫你重 join → join 回 404」的死路，`tests/test_room_deletion.py`
已經用參數化把所有 room-scoped 路徑釘住，新端點要一併加進去。

| Method + Path | 用途 |
|---|---|
| `GET /api/rooms/{id}/board` | 讀 board（`after_board_seq` 增量） |
| `POST /api/rooms/{id}/board/objectives` | 新增 Objective |
| `PATCH /api/board/objectives/{oid}` | 改標題／描述／順序 |
| `POST /api/board/objectives/{oid}/review` | 送審（閘 3） |
| `POST /api/board/objectives/{oid}/verify` | 確認無誤（閘 4） |
| `POST /api/board/objectives/{oid}/complete` | 完成（閘 1、2）→ 通知全員 |
| `POST /api/board/objectives/{oid}/reopen` | 打回（限人類） |
| `DELETE /api/board/objectives/{oid}` | 軟刪除（連帶其下 checklist / task） |
| `POST /api/board/objectives/{oid}/checklists` | 新增 Checklist |
| `PATCH /api/board/checklists/{cid}` | 改欄位 |
| `POST /api/board/checklists/{cid}/complete` | 完成 |
| `DELETE /api/board/checklists/{cid}` | 軟刪除 |
| `POST /api/board/checklists/{cid}/tasks` | 新增 Task（可帶 `source_seq` / `invite_session_key`） |
| `PATCH /api/board/tasks/{tid}` | 改標題／描述／狀態／優先度／順序／指定執行者 |
| `POST /api/board/tasks/{tid}/claim` | 認領（CAS，§2.2） |
| `POST /api/board/tasks/{tid}/release` | 放棄認領 |
| `POST /api/board/tasks/{tid}/complete` | 完成 → 通知執行者以外的人 |
| `DELETE /api/board/tasks/{tid}` | 軟刪除 |
| `POST /api/rooms/{id}/board/supervisor` | 設定／取消 supervisor（限建立者） |
| `POST /api/rooms/{id}/board/reorder` | 批次排序（一次操作一個 `board_seq`） |

子資源路徑不帶 `room_id`（`/api/board/tasks/{tid}`）是刻意的：id 是全域唯一的
uuid，room 從該列自己查得到，而讓 client 同時傳兩個是給它一次傳錯的機會。
既有的 `/api/messages/{id}/pin` 就是這個形狀。

🔴 **級聯軟刪除時，被連帶刪掉的子孫列每一列都要領新的 `board_seq`**
（審查發現，與這次操作共用同一個號）。刪 Objective 時只更新 Objective 自己
的 `board_seq`，增量 client 就**永遠收不到底下 checklist / task 的
tombstone**——它們的 `board_seq` 停在舊值，`board_seq > N` 查詢撈不到，
board 上會留著一批已經不存在的卡，而且愈久愈多。
§5.3 的「任何欄位變更（含軟刪除）都要領號」字面上涵蓋得到，但這條最容易在
實作時被當成「只有被點的那一列變了」，所以在這裡明寫，並列進 T-03 的驗收。

**錯誤碼**：`task_already_claimed` / `not_claim_holder` /
`objective_not_verified` / `objective_not_in_review` / `checklists_incomplete` /
`self_verification_not_allowed` / `board_item_not_found` / `human_only`。

---

## 7. MCP 工具

Bridge 是薄殼，只做 REST 轉譯。既有已經 20+ 個工具，**要克制**——
工具太多本身就會稀釋 agent 對每個工具的理解。收成 4 個：

| 工具 | 說明 |
|---|---|
| `chatroom_board(room_id, after_board_seq=None, full=False)` | 讀 board。省略 cursor 時沿用本機記住的水位（與 `chatroom_read` 同慣例，狀態存 `state.py`）。回應含 `reclaimable_tasks` |
| `chatroom_board_add(room_id, kind, title, parent_id, description="", source_seq=None)` | 新增 objective／checklist／task，`kind` 三選一 |
| `chatroom_board_update(room_id, task_id, status=None, description=None, ...)` | 改欄位與狀態 |
| `chatroom_board_claim(room_id, task_id, release=False)` | 認領／放棄。回應含 `reclaimed` 與被拒時的 `held_by` |

完成走 `chatroom_board_update(status="done")`，不另開工具——
「完成」在 agent 眼裡就是改狀態，多一個工具只是多一個它會忘記存在的東西。
`verify` **刻意不給 agent**（見 Q4）。

`guide.py` 要補一節 Board 的心智模型：三層是什麼、認領是 CAS 會失敗要處理、
orphaned 可以撿、`board_seq` 怎麼用。

---

## 8. Flutter 端

**落點：`/rooms/:roomId/board`**，與既有的 `pinned` / `assign` 同一層
GoRoute 子路由（`app.dart` L52-77 那組）。不做房內側欄——board 是三層樹狀
資料，塞進 400px 側欄會變成沒人想用的東西；而全頁在 `ShellRoute` 底下，
桌面版左側房間列表仍在，切回聊天是一下的事。

新增（**全部是新檔，零衝突**）：

```
app/lib/models/board.dart          Objective / Checklist / BoardTask
app/lib/api/board_api.dart         照 rooms_api.dart 的形狀
app/lib/state/board_providers.dart board cursor + 輪詢/WS invalidate
app/lib/screens/board/board_screen.dart
app/lib/widgets/board_task_card.dart
```

**Visual**：✅ **以設計稿為準**（`Board 外觀設計.dc.html`，claude.ai/design 專案
`b61d1f79`，與 Chatroom 本體同一個專案）。本節初版寫的「Checklist 為欄、Task
為卡的看板」**是錯的，作廢**——設計走的是左右分欄：

- **左**：Objective 清單（每條顯示「N 階段 · N 任務 · N 孤兒」與狀態）
- **右**：單一 Objective 展開。Checklist 是**可摺疊的垂直區段**（`5 / 6 DONE`），
  不是看板欄
- **Task 詳情**：右側 420px 抽屜，不是新頁
- 八個 artboard：主畫面／卡片全狀態／詳情／建立／收尾三段／聊天室入口／
  supervisor／空板與封存板

**卡片的兩個維度怎麼畫**（設計師對 §2.1「認領與狀態正交」的答案，這是整份
設計的核心，實作不要自己改）：

> **色軸講誰，徽章講到哪。**

| 左側色軸 | 意思 |
|---|---|
| 實色（持有者的 kind 色） | 現任持有者還在房裡 |
| **斷開 + 名字劃掉** | **孤兒。狀態徽章不動**——「變的是人不是進度」 |
| 半透明 | 有人被指名（`assignee`），但還沒有人站上去 |
| 中性線色 | 沒有人 |
| 無軸（收合成單行） | 已完成——事情結束，誰做的退成註記 |

⚠️ **認領失敗畫成事實，不是錯誤**：卡片直接換成「已經被 X 領走了（13:48）」，
沒有紅字、沒有重試按鈕（§2.2 那條 409 在 UI 上的樣子）。

⚠️ **人類與 agent 看到的不是同一個畫面**：Objective 收尾處，人類看到「確認 /
打回」兩顆按鈕，agent 看到的是「你已於 14:26 送審。等奈留確認。」——
**沒有那顆按鈕**，不是按了才失敗（Q4）。聊天室入口同理：agent 的入口只亮
自己的事（可撿回、被指名），「等你確認」在 agent 那裡不存在。

**唯一會動到既有檔的兩處**（都排在最後一張票）：
- `app/lib/app.dart` — 加一條 GoRoute
- `app/lib/screens/chat/chat_screen.dart` — app bar 加一顆入口。
  ⚠️ 2621 行，且今天已被除錯 Novia 動過（成員列 `⋯` 選單）。
  **多 agent 共用同一個 working tree，這張票要獨占**。

---

## 9. 拆票

✅ **Q1～Q7 已全部定案（§10），schema 不受影響，可以開工。**
Q1 選並存、Q3 選「Objective ＝ 週期／Checklist ＝ 階段分組」，兩者都不動
§1.3 的表結構，T-01 照原文開即可。

| 票 | 範圍（一句） | 依賴 | 驗收 | 高衝突檔 |
|---|---|---|---|---|
| **T-01** | `db.py` 三張 board 表 + room 兩個欄位 + partial index | — | 舊 DB 開得起來、`_migrate` 可重入跑兩次不炸；新表索引存在 | 🔴 `db.py` |
| **T-02** | `GET /board` 讀取端點 + `board_seq` 增量契約 + tombstone | T-01 | `after_board_seq=0` 回全量；改一筆後只回那一筆；軟刪除的列帶 `deleted:true` 回得來 | 🔴 `app.py` |
| **T-03** | Objective／Checklist／Task 的 CRUD 與批次排序 | T-02 | 建/改/軟刪各自推進 `board_seq`；批次排序只領一個號；**刪 Objective 後底下 checklist／task 的 tombstone 都撈得到**（§6） | 🔴 `app.py` |
| **T-04** | claim／release 的 CAS + 孤兒釋放接進四條離場路徑 + **孤兒的獨立系統訊息** | T-03 | 兩個 participant 併發 claim 同一張，一成一敗回 409；**成功那次回應要與資料庫實際狀態一致**（§2.2 的 `fetchone` 判定，**這條測試要先紅**）；sweeper 掃掉持有者後該卡變 `orphaned` 且保留 `claim_name`／`claim_kind`；**四條離場路徑各自寫進不同的 `orphaned_reason`**；孤兒訊息**不 mention 任何人**且 subagent 回收那條**不發**；orphaned 可被別人 claim | 🔴 `app.py` |
| **T-05** | 狀態機守門：Objective 四道閘、Checklist 完成條件、打回限人類 | T-03 | agent 送審後自己 verify → 409 `self_verification_not_allowed`（**先紅**）；**人類送審後自己 verify → 成功**（閘 4 的人類例外，**也要先紅**）；agent 呼叫 verify 一律 403 `human_only` | 🔴 `app.py` |
| **T-06** | 兩條通知規則（system message + mentions） | T-05 | Task 完成後 `mentions` 不含完成者且含其餘 active 成員；Objective 完成含全員；其餘變動 `mentions` 為空 | 🔴 `app.py` |
| **T-07** | Supervisor 設定／摘要／**退場標記（不清空）** | T-06、Q6 | 非建立者設定回 403；**設定當下 supervisor 不在房裡不會被自己的退場規則清掉**（§4.4）；離場後名字與種類**留著**、標成已不在房內，且房內有系統訊息 | 🔴 `app.py` |
| **T-08** | `/updates` 收 `after_board_seq` 參數 + 回應加 `board_seq` + **等待迴圈加返回條件**；`/ws` 同步 | T-02 | **board 變動（不發任何訊息的那種）要讓掛著的 long-poll 立刻返回**，不是等逾時（§5.4，**這條測試要先紅**）；沒帶 `after_board_seq` 的舊 client 行為不變、不會空轉；`you_were_mentioned` 不受影響 | 🔴 `app.py`（與既有 updates 端點同一段） |
| **T-09** | 四個 MCP 工具 + `hub.py` 方法 + `guide.py` 一節 | T-08 | bridge 測試綠；`chatroom_board` 省略 cursor 時沿用本機水位 | 🔴 `server.py` / `guide.py` |
| **T-10** | Flutter model + api + providers | T-02 | 單元測試：增量合併（新／改／刪三種）正確套用到本機快取 | 🟢 新檔 |
| **T-11** | `board_screen.dart` + 卡片 widget（**照設計稿**，§8） | T-10 | `flutter analyze` 0；widget test：**五種軸狀態各畫對**（實色／斷軸+劃掉／半透明／中性／收合）、**孤兒卡的狀態徽章不變**、認領失敗顯示為事實不是錯誤、**agent 視角沒有 verify 按鈕**；缺 `claim_kind`／`orphaned_reason` 時優雅退化 | 🟢 新檔 |
| **T-12** | 路由 + `chat_screen` 入口按鈕 | T-11 | 從聊天進得去、回得來 | 🔴 `app.dart` + `chat_screen.dart`（**獨占**） |
| **T-13** | 文件：`PLANNING.md` §4 新增一節、`CHATROOM.md` 同步 | T-09 | — | 🟡 `PLANNING.md` |

**平行化建議**（同一個 working tree，`app.py` 只能一個人動）：

```
T-01 → T-02 → T-03 → T-04 → T-05 → T-06 → T-07 → T-08 → T-13   ← 一個人從頭做到尾
                └──────────► T-10 → T-11 ──────────► T-12       ← 另一個人（新檔，可並行）
                                              T-09              ← T-08 完成後插隊
```

`app.py` 那條鏈（T-02~T-08）**不可以拆給兩個 agent 並行**——4447 行的單一
`create_app()` 閉包，兩個人同時編輯會直接互相覆蓋且沒有衝突提示
（房內 #10 已經確認過這件事）。

---

## 10. ✅ 已拍板（艾斯維爾，2026-09-01）

七題全部定案，另加一題由 Q4 的答案衍生、當場補問。原始選項與推薦理由見
git 歷史（本節初版）；這裡只留結論與**它改動了哪一節**。

| 題 | 定案 | 落在哪 |
|---|---|---|
| **Q1** Board 取代釘選？ | **並存**，兩者各留。釘選是「這則訊息很重要」（訊息的屬性），Board 是結構化任務 | §3.3。不動 schema |
| **Q2** 三層是否強制？ | **強制**。「隨手記一件事」走每個 Objective 預設的「未分類」Checklist | §1.2、§1.3（`checklist_id` 維持 NOT NULL） |
| **Q3** Objective ＝ 週期？ | **是，且可多條並行**。Checklist ＝**階段分組**，不是驗收條件清單 | §1.2、§1.5 閘 3（維持原文） |
| **Q4** 誰能 verify？ | **只有人類成員**。agent 只能送審；MCP 工具不暴露 verify | §1.4 權限表、§1.5、§7 |
| **Q5** Checklist 完成通知？ | **不通知**。只有 Task 與 Objective 完成會發 | §4.3 |
| **Q6** Supervisor 粒度？ | **摘要**，不逐筆 | §4.4 |
| **Q7** 人類可強制解除認領？ | **可以**，board 上留紀錄 | §2.2、§6（`release` 端點放寬給人類成員） |

### Q8（衍生）人類自己送審的 Objective，他自己能不能 verify？

**可以——人類不受閘 4 限制。**

這題是 Q4 選 A 之後長出來的死鎖，不在原始清單裡：閘 4 要求「確認者 ≠ 送審者」，
Q4 又規定「只有人類能確認」，而房裡的常態是**只有一個人類**
⇒ 只要他自己把某個 Objective 送審，就再也沒有人能確認它，那條週期永遠停在
`review`，而且每一步都合乎規則。

閘 4 存在的目的是擋 agent 自己確認自己，不是擋人。實作寫法見 §1.5。

⚠️ **這個答案的實際效果是讓閘 4 整條退場**（實作完成後才發現，見 §1.5）：
加上「送審者是 agent 時才檢查」這個前提之後，配上 Q4 的「只有人類能確認」，
兩個條件變成不可能同時成立。擋住「agent 自己確認自己」的其實一直是 Q4。
這個決定沒有錯——死鎖是真的、非解不可——但它的代價要寫清楚：
**Board 現在只有一道防線在管這件事，不是兩道。**

## 11. 需求中定義不足的地方 — 逐項結論

規劃當下列出七處，逐項標上後來的結果。**沒有被問到的仍然標成未確認**，
不要因為開工了就當成已經定案。

| # | 事項 | 結論 |
|---|---|---|
| 1 | Objective 與 Checklist 都被描述成「週期」 | ✅ **Q3 定案**：Objective ＝ 週期（可多條並行），Checklist ＝ 階段分組 |
| 2 | 「取代釘選」後面自己標了「待討論」 | ✅ **Q1 定案**：並存 |
| 3 | 「週期」何時開始／結束、誰確認 | ✅ **Q3 + Q4 + Q8**：週期＝Objective 的生命週期；確認只有人類；人類自己送審不受閘 4 限制 |
| 4 | 「指派對象」與「自行認領」是兩套所有權 | ⚠️ **仍是規劃者的裁量，未被明確推翻**。目前作法：指派是建議（`assignee_participant_id`）不鎖卡。Q7 定案「人類可強制解除認領」與這個方向一致，但**沒有人直接回答過「指派要不要即鎖定」**。要改的話動 §2.2 的 CAS 條件 |
| 5 | Supervisor 的形式與數量 | ✅ **Q6 定案**：收摘要不逐筆。數量仍假設**單一**（`room` 上是單一欄位），同樣沒有被直接問過 |
| 6 | 「位置待定」 | ✅ 實質定案：room 底下。T-01 的 schema 已按此落地（三張表都帶 `room_id`），不再是推定 |
| 7 | Visual 沒有具體要求 | ⚠️ **仍然沒有需求**。§8 是依既有 UI 慣例提的方案，做 T-11 之前值得先給艾斯維爾看一眼 |
