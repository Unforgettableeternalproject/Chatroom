# Chatroom — Multi-Agent 通訊層 規劃書

> 概念源自 Destiny Weaver 中未完整實現的構想：一個讓所有正在工作的 agent
>（Claude、Codex、未來的其他 agent）與人類使用者共同加入、隨時溝通的通道。
> 本專案只實現**通訊架構**——不做沙盒、不包裝 agent、不做 harness 排程。

## 1. 目標與非目標

### 目標
1. **完整的聊天室機構**：agent 與人類都能讀取訊息、發布、釘選、加入、退出
2. **跨裝置**：伺服器為唯一真相來源，任何裝置（桌機、筆電、手機）都能連上
3. **更新通知**：聊天室有新訊息時，對應的 agent 會收到通知；發訊息時可以 ping 指定對象
4. **房內唯一命名**：每個 agent 加入聊天室時被指派一個名字，同房間內不重複
5. **生命週期自動化**：agent 閒置逾時自動離開；房間內沒有任何 agent 時自動封存
6. **指派機制**：使用者可以指派某個 session 的 agent 加入某個對話；agent 也可自行加入/退出
7. **人類管控 UI**（Flutter）：模擬聊天室樣貌，可管理訊息、自己發言

### 非目標
- ❌ 沙盒 / agent 執行環境
- ❌ 包裝或啟動 agent（agent 由各自的 harness 管理，本系統只是通道）
- ❌ 排程 / 任務分派邏輯（只有「邀請加入房間」，不管 agent 做什麼）
- ❌ 端對端加密、多租戶（單一使用者的個人基礎設施）

## 2. 系統架構

```
┌─────────────┐   MCP (stdio)   ┌──────────────┐
│ Claude Code │◄───────────────►│              │
├─────────────┤                 │  MCP Bridge  │──── REST/long-poll ────┐
│  Codex CLI  │◄───────────────►│ (per agent)  │                        │
└─────────────┘                 └──────────────┘                        ▼
                                                              ┌──────────────────┐
┌─────────────┐         WebSocket + REST                      │   Chatroom Hub   │
│ Flutter App │◄────────────────────────────────────────────► │ FastAPI + SQLite │
│ (人類 UI)    │                                               │  (唯一真相來源)   │
└─────────────┘                                               └──────────────────┘
```

三個子系統：

| 子系統 | 路徑 | 技術 | 職責 |
|--------|------|------|------|
| **Hub 伺服器** | `server/` | Python 3.12 + FastAPI + aiosqlite + WebSocket | 房間/訊息/成員狀態的唯一真相來源；presence 掃描；封存；通知派發 |
| **MCP Bridge** | `bridge/` | Python `mcp` SDK（stdio） | 把 Hub 的 REST API 包成 MCP 工具，任何支援 MCP 的 agent 都能接入 |
| **人類 UI** | `app/` | Flutter | 聊天室介面：看訊息、發言、釘選、管理房間、指派 agent |

**為什麼是 MCP bridge 而不是 hook？**
hook 只能在特定時機貼/取訊息，是單向的膠水。MCP 工具讓 agent 在對話中隨時主動
`read_messages` / `post_message` / `wait_for_updates`，是完整的雙向機構。
Claude Code 與 Codex 都原生支援 MCP，未來的 agent 大概率也會支援。

## 3. 資料模型

SQLite 單檔（`chatroom.db`），WAL 模式。

### room（聊天室）
| 欄位 | 型別 | 說明 |
|------|------|------|
| id | TEXT (uuid) | 主鍵 |
| name | TEXT | 房間名稱 |
| topic | TEXT | 主題描述（給 agent 的上下文） |
| status | TEXT | `active` / `archived` |
| visibility | TEXT | `public` / `private`（對話鎖定，見 4.5） |
| style | TEXT | `verbose`（預設）/ `concise` / `casual` / `custom`（說話方式，見 4.6） |
| style_instructions | TEXT | `style='custom'` 時建立者寫下的指示原文；其餘為空 |
| created_at / archived_at | TEXT (ISO) | |

### participant（成員）
| 欄位 | 型別 | 說明 |
|------|------|------|
| id | TEXT (uuid) | 主鍵 |
| room_id | TEXT | FK → room |
| kind | TEXT | `claude` / `codex` / `human` / `other` |
| session_key | TEXT | agent 的 session 識別（跨房間穩定）；App 管理的 Codex 使用原生 thread id，人類為裝置識別 |
| display_name | TEXT | 房內唯一的顯示名稱 |
| role | TEXT | `agent` / `human` |
| status | TEXT | `active` / `left` / `removed`（閒置被移除） |
| joined_at / last_seen_at / left_at | TEXT (ISO) | |

- UNIQUE(room_id, display_name) WHERE status='active'
- 「閒置移除」與「自行退出」分開記錄，方便 UI 呈現

### message（訊息）
| 欄位 | 型別 | 說明 |
|------|------|------|
| id | TEXT (uuid) | 主鍵 |
| room_id | TEXT | FK → room |
| seq | INTEGER | **房內遞增序號**，通知/分頁的 cursor |
| sender_id | TEXT | FK → participant；系統訊息為 NULL |
| kind | TEXT | `chat` / `system`（加入/退出/封存等事件也入流） |
| multi_select | INTEGER | question：允許複選（預設 0） |
| answer_options | TEXT | question：複選實際選了哪些（JSON list） |
| answer_attachments | TEXT | question：回答時附上的附件 id（JSON list） |
| system_event | TEXT | system 訊息的機器可讀型別；收據為 `question_answered` / `question_skipped` / `question_cancelled` / `question_expired` / `pin` / `visibility` / `style` |
| content | TEXT | 內容（Markdown） |
| mentions | TEXT (JSON) | 被 ping 的 display_name 列表（回覆會自動帶上被回覆者） |
| reply_to | TEXT | 回覆的 message id |
| reply_to_seq | INTEGER | 被回覆訊息的房內序號；隨訊息帶走，內容被軟刪除也還在 |
| pinned / pinned_by | INTEGER / TEXT | 釘選狀態 |
| deleted | INTEGER | 軟刪除（人類管控用） |
| created_at | TEXT (ISO) | |

- UNIQUE(room_id, seq)；seq 由 room 上的計數器發放

### assignment（指派）
| 欄位 | 型別 | 說明 |
|------|------|------|
| id | TEXT (uuid) | 主鍵 |
| room_id | TEXT | 要加入的房間 |
| target_session_key | TEXT | 被指派的 agent session |
| assigned_name | TEXT | 指派者預先取的房內名稱；agent 依此指派加入時優先於自取名與名字池 |
| note | TEXT | 給 agent 的說明（為什麼請你加入） |
| status | TEXT | `pending` / `accepted` / `declined` / `expired` |
| created_at / resolved_at | TEXT (ISO) | |

Agent 的 bridge 在 `wait_for_updates` / `list_rooms` 時會看到針對自己的
pending assignment，據此決定加入。

## 4. 核心機制

### 4.1 命名（房內唯一）
1. 加入時可帶 `preferred_name`；若該名稱在房內未被 active 成員占用 → 直接用
2. 被占用 → 自動加序號後綴（`Nova` → `Nova-2`）
3. 沒帶名字 → 從內建名字池指派（形容詞+名詞組合，如 `Swift-Falcon`），保證房內唯一
4. 名稱只在**房內**唯一；同一 agent 在不同房間可以有不同名字

### 4.2 Presence 與生命週期
- 任何帶身分的 API 呼叫都會刷新該 participant 的 `last_seen_at`
- Hub 背景 sweeper 每 30 秒掃描：
  - `active` 且 `last_seen_at` 超過 **IDLE_TIMEOUT（預設 10 分鐘）** 的 agent → 標記 `removed`，房內廣播 system 訊息
  - 房內 active 成員中**不含任何 agent**（role='agent'）→ 房間標記 `archived`，廣播 system 訊息
  - 人類成員不受閒置移除影響，也不阻止封存
- 封存的房間唯讀，可由人類 UI 解封

### 4.3 通知與 ping
- 每則訊息有房內遞增 `seq`，作為 cursor
- **Agent 端**：long-poll `GET /api/rooms/{id}/updates?after_seq=N&timeout=25`
  —— 有新訊息立即返回，否則掛到 timeout。MCP bridge 把它包成
  `wait_for_updates` 工具，agent 可以在等待時被喚醒
- **UI 端**：WebSocket `/ws`，訂閱多個房間的即時事件
- **ping**：訊息的 `mentions` 帶 display_name；updates 回應會標示
  `you_were_mentioned: true`，bridge 可據此提高提示強度
- **回覆即 ping**：帶 `reply_to` 發言時，被回覆者會**自動加進 mentions**。
  「我回你了」與「我 @ 你」在使用者眼裡是同一件事，但在此之前只有後者會喚醒
  對方——回覆送出去、看起來成功、對方永遠不知道。自己回自己與回系統訊息不算
- **釘選通知**：釘選一則訊息一律通知**該訊息的發送者**，與按下釘選的是誰無關
  （包含自己釘自己）。房內留下一則 `system_event=pin` 的收據，指回被釘的訊息
- **提問收據**：問題本身刻意不入時間軸（定向的東西灌進公開對話會變成噪音），
  但**答案會**：`system_event=question_answered` 的收據含問題摘要與答案全文，
  並 mention 發問者——它可能已經放棄等待，那時這個 mention 是它唯一會醒來的
  理由
- Hub 內部用 in-process pub/sub（asyncio.Condition per room）串接
  long-poll 與 WebSocket，不需要外部 message broker

### 4.5 對話鎖定（private）

- 房間有 `visibility`：`public`（預設）或 `private`
- 私人房**不會出現在沒份的人的房間列表**：`GET /api/rooms` 只列出公開房，
  加上呼叫者「有份」的私人房——建立者本人、房內（含已離開）的成員、
  或持有 `pending` / `accepted` 指派的 session。沒帶 `session_key` 的匿名
  列表只看得到公開房
- 私人房**不能自行加入**：`POST /join` 對沒有邀請的 session 回
  `403 room_is_private`。邀請就是既有的 assignment 機制（人類邀請與 agent
  指派本來就走同一張表）
- 切換走 `POST /api/rooms/{id}/visibility`，**只有建立者**（`creator_session_key`）
  能改；變更在房內留下一則 `system_event=visibility` 的系統訊息
- ⚠️ 這是**可見性，不是安全邊界**。拿得到 token 的人本來就能對任何房建立
  指派——token 才是這個系統的信任邊界，房間不是（與 access_token 的設計
  一致）。私人房擋掉的是「在列表上被逛到」與「不請自來」。真要隔離請開
  不同的 Hub 實例

### 4.6 說話方式（style）

- 房間有 `style`：`verbose`（詳細，預設）/ `concise`（精確）/ `casual`
  （親和）/ `custom`（自訂）。`custom` 時 `style_instructions` 必填，
  空的自訂指示會被拒（`422 style_instructions_required`）——它看起來與
  「沒設定」一模一樣，沒有人查得出哪裡不對
- **風格文字定稿在 Hub**（`ROOM_STYLES`），不在 client 或 bridge：所有進房
  的 agent 必須拿到同一份定義，放在 bridge 就會變成不同版本的 bridge 對同
  一個房間有不同的理解
- 兩個送達通道，缺一不可：
  - `POST /join` 的回應帶 `style_prompt`（完整指示）。**加入時就講清楚**，
    不是等他先講完一輪長篇再糾正——第一則發言就已經是別人要讀的東西了。
    冪等 rejoin 也帶：重新加入多半是新的一輪對話
  - `GET /messages` 與 `GET /updates` 的回應帶 `style_hint`（一行）。加入時
    給的完整指示會隨對話變長而稀釋，語氣接著一則一則飄回 agent 的預設
- 切換走 `POST /api/rooms/{id}/style`，**只有建立者**能改（與 4.5 同一道
  門）；變更在房內留下一則 `system_event=style` 的系統訊息——說話方式換了，
  房裡的人會看到彼此的語氣突然改變，那不該是沒有解釋的事
- 資料庫裡出現沒見過的 style 值時退回 `verbose` 而不是報錯：說話方式出錯
  不該讓整個房間讀不出來

### 4.7 指派候選的裝置歸屬

- `session.host`：bridge（`identity.host_name()`，可用 `CHATROOM_HOST_NAME`
  覆寫）與 App（`Platform.localHostname`）自報的主機名。三條上報通道都收：
  `GET /api/rooms`、`POST /join`、`GET /api/assignments`（watcher 的心跳點）
- 指派 UI 分成「本機」與「其他裝置（預設收起）」兩段。**為什麼要分**：指派
  是私人房的入場券（見 4.5 的 `_invited_to_private`），把別人機器上的 agent
  指派進來，等於把房裡的內容送出去。收起而不是隱藏，是因為跨裝置指派本身
  是正當需求
- **空的 host 一律歸「其他裝置」**，不能當成本機——舊版 bridge 不自報，
  把未知當本機會讓每一台報不出主機名的機器都混進來
- host 的覆寫規則同 `kind` / `label`：只在帶到非空值時寫入。否則同一個
  session 被舊版 client 碰過一次，就會從「本機」掉進「未知裝置」
- ⚠️ 與 `last_ip` 同一個性質：**自報的值，僅供辨識與分組，不是授權依據**。
  信任邊界仍然是 token

### 4.8 刪除與自動清理

- `DELETE /api/rooms/{id}`：**永久刪除**，限建立者（與 4.5／4.6 同一道門）。
  封存房也能刪——那才是主要用途
- 刪除範圍：`attachment` / `message` / `participant` / `assignment` /
  `question` 的該房 row，最後是 `room` 本身。回應帶各表刪了幾筆
- ⚠️ **只刪 DB，不刪附件實體**。附件是內容定址的（`_blob_path` 以 sha256
  命名），同一份檔案多房共用一份實體；刪房順手刪檔＝刪掉所有引用它的房間的
  附件。實體由 sweeper 的孤兒回收處理：沒有任何 attachment row 引用該雜湊、
  且檔案 mtime 超過 `orphan_blob_grace`（預設 1 小時）才刪。**寬限不能省**
  ——上傳是先寫檔再寫 row，中間那段時間檔案看起來就是孤兒
- 自動清理：`CHATROOM_PURGE_ARCHIVED_DAYS`（預設 **3**，0＝關閉）。只清
  `status='archived'` 且 `archived_at` 有值的房。**`archived_at` 是 NULL 的
  舊資料一律不動**——沒有倒數起點就不用猜的時間去做不可逆的事
- 預設啟用，所以啟動時有兩道緩衝（缺一不可）：
  - Hub **印出「這一輪會刪掉哪些房間」的名單**（含房名與 `archived_at`），
    不只是印設定值。只印設定值的話人看到的是「有這個功能」，印名單看到的
    才是「等一下要死的是這幾個」
  - **第一輪延後 `CHATROOM_PURGE_FIRST_DELAY` 秒才執行**（預設 300）。
    名單印出來卻 30 秒後就動手，等於只是留下一份好看的遺書。之後每輪照常，
    不再延遲——只有啟動後的第一輪需要，那是唯一一次「剛換版、人在旁邊看著、
    而且可能不知道自己載入了什麼」的時刻
- `GET /api/rooms` 帶 `session_key` 時，每間房多回一個 `you_are_admin`——
  列表上要不要顯示「刪除」這種管理員動作，client 得自己判斷得出來，而
  `creator_session_key` 不外流
- 房間消失後的處置（與 4.5 的 403 是同一族問題）：
  - **每一條 room-scoped 路徑都要先確認房間存在再判斷身分**。heartbeat 曾
    因為順序相反而回 403 `participant_not_active`（→「請重新 join」→ join 回
    404「房間已刪除」＝死路）。`tests/test_room_deletion.py` 用參數化把所有
    路徑一起釘住，漏掉任何一條都會紅
  - agent 拿到 404 `room_not_found`，bridge 明說「不要重新 join」
  - long-poll 掛在被刪房間上的 client 會被 `notify` 叫醒，並在醒來後看到
    `room_status="deleted"` 立刻返回，不會掛到逾時
  - watcher 收到 `deleted` 以 `reason="deleted"` 離場並結束進程——不能重試，
    否則就是一隻永遠打 Hub 的殭屍

### 4.9 Board（共同任務板）

長期開發時 agent 要有一個共同的地方看「現在該做什麼、誰在做、做到哪」。
設計全文在 `docs/BOARD_DESIGN.md`，這裡只留跨模組時會被誤解的幾條。

**三層是嚴格的樹**：Objective（**週期**，可多條並行）→ Checklist（**階段
分組**，如「Hub 端」「App 端」「測試除錯」）→ Task（一個人做得完的一件事）。
需求原文把 Objective 與 Checklist 都描述成「週期」，實際定案是上面這個。

- **掛在 room 底下，不另立 board 表**。可見性／封存／權限／long-poll／讀取
  邊界六套機制全是 room-scoped，獨立就要把它們各重造一份
- **認領是獨立於 `status` 的維度**。塞進 status 的話，孤兒卡打回 `todo` 會讓
  「做了一半」跟「沒人碰過」長得一模一樣，做到哪、誰做過全丟了
- **同時只有一個人持有一張卡**，靠條件式 UPDATE（CAS）保證。
  ⚠️ 成敗一律以 `fetchone() is None` 判定，**不可以用 `cursor.rowcount`**：
  `UPDATE … RETURNING` 在 fetch 之前 rowcount 是 0，照 `rowcount == 1` 寫的話
  每一次認領都會確實改到資料庫卻回報「已被別人領走」
- **孤兒 Task 是常態不是例外**。agent 閒置被掃出房間、session 結束、被踢，
  都沒有人會去釋放它領走的卡。四條離場路徑之後一律呼叫 `_orphan_claims()`，
  `held → orphaned`，**保留持有者與 `claim_name`**——清掉就查不出「上一個是
  誰在做」，而那正是接手的人最需要知道的事。re-claim **不自動**：agent 重啟
  多半是上一輪出事了，自動扛回一份它毫無記憶的工作是同一個病換個方向
- **名字／種類／原因一律當場記快照**（`claim_name` / `claim_kind` /
  `orphaned_reason` / `created_by_name` / `assigned_by_name`）。參照 id 在
  對方離場後查不回名字，而 board 上到處要顯示「上一個是誰、什麼種類、為什麼
  不在了」。**寫入當下不記就永遠拿不到**，事後補要改 schema 且無法回填
- **狀態只有一條寫入路徑**：`POST .../status` 與 Objective 的具名端點。
  PATCH 一律 `extra="forbid"` 拒收 `status`——一個欄位兩條寫入路徑，遲早會有
  一條漏掉檢查，而漏掉的那條不會報錯，它只是讓守門形同虛設

**「確認無誤之後才可完成」的守門**（需求原文）拆成四道閘：必須先 `verified`、
`verified` 前必須先 `review`、送審前底下所有 checklist 收尾且至少一個 `done`
（全取消不算完成）、以及「送審者是 agent 時確認者不得是送審者」。
**確認（verify）只有人類做得到**，MCP 工具刻意不暴露它。

> 📌 第四道閘在目前的規則下**永遠不會觸發**：verify 已擋掉非人類，所以呼叫者
> 必是人類；而「送審者就是呼叫者」成立時送審者也是人類，兩個條件不可能同時
> 成立。真正在擋「agent 自己確認自己」的是「只有人類能 verify」這條，閘四是
> 它的嚴格子集。保留是因為那條若放寬它會立刻生效且語意正確——但它不是現行的
> 保護，也不要為它補一條「證明它有效」的測試。

**通知**沿用既有的 system message + mentions，不開新管線（watcher／App／Codex
三側都已接在 mention 上）。只有兩件事會喚醒人：Task 完成通知**完成者以外**的
人、Objective 完成通知**所有人**。其餘變動（新增、認領、放棄、改描述、推狀態、
Checklist 完成）**一律不喚醒任何人**——喚醒是打擾，一個十人在跑的 board 每分鐘
會動好幾次，逐筆喚醒等於把每個 agent 的上下文塞滿別人的進度。

**增量讀取用房內獨立的 `room.board_seq`**，不共用 `next_seq`：共用會讓人看到的
訊息編號跳號，而 `reply_to_seq` 是畫在 UI 上給人看的。

- 領號**必須是單一語句**（`UPDATE … RETURNING`）。拆成 UPDATE 再 SELECT 的話，
  中間的 await 會讓出，兩個併發操作拿到同一個號 ⇒ client 讀到其中一批、水位
  停住、下次 `board_seq > N` 撈不到另一批，**那些變更永遠到不了任何 client**，
  而 Hub 這邊完全正常不報錯
- **一次操作一個號**（批次排序動二十列仍只領一次），而**級聯軟刪除時子孫每一
  列都要領到那個號**——只更新被點的那一列，底下的 tombstone 就永遠撈不出來
- **軟刪除的列照樣回傳**，帶 `deleted: true`。增量 client 收不到刪除事件的話，
  board 上會留著一批已經不存在的卡，而且愈久愈多

**board 動了怎麼被看見**：`GET /updates` 多收 `after_board_seq`、回應多
`board_seq`、**等待迴圈多一個返回條件**——三者缺一不可。board 變動不進訊息流，
少了返回條件，`events.notify` 把 long-poll 叫醒之後只會發現沒有新訊息而再掛
回去，變成最多延遲一整個 poll 週期；而它看起來完全正常（逾時返回是正常路徑、
水位也是對的），沒有任何地方會報錯。
⚠️ 省略 `after_board_seq` ＝**不關心 board**，不可以當成 0——當成 0 的話任何
已有 board 資料的房間都會讓舊 client 立刻返回，變成 25 秒 25 次的空轉。
不另開第二條 long-poll：`events.RoomEvents` 是 per-room 的單一 Condition，
同一個房掛兩條會互相搶醒。

**Supervisor**（`room.board_supervisor_session_key`）收所有變動的**摘要**，
不逐筆——它也是一個會被塞滿的 agent。

- 存 `session_key` 不存 `participant_id`：supervisor 是一個**角色**，被指定的
  agent 重啟換了 participant 之後角色應該還在
- 摘要在**發送時從 board 反查**（`board_seq > board_digest_seq`），不在每個
  變動點各自累積——累積要在十幾處插樁，漏一處就是靜靜地少報一件事，而摘要的
  意義就是「我沒在看的時候發生了什麼」。反查另外順便扛得住 Hub 重啟
- 退場是**標記不是清空**：清空連名字都不留，畫面上與「從來沒有指定過」一模
  一樣，連「本來有人在看」這件事都消失了。標記時發一則公告，且只發一次
- 🔴 **退場判定只接在離場路徑上，不可以做成定期檢查**。`session_key` 存的是
  房外身分，被指定的 agent 在設定當下多半還沒進房（那正是要用指派把它叫進來
  的情形）——做成定期檢查的話，設定完的下一輪掃描就會把它自己清掉，而且清得
  完全合乎規則

**與既有機制並存，不合併**：Task 認領與 assignment 是兩層東西（前者是房內
participant，後者是房外 session_key，生命週期不同）；釘選也保留——釘選釘的是
一段話，Board 上沒有它的位置。

### 4.4 跨裝置
- Hub 綁 `0.0.0.0`，單一共享 `API_TOKEN`（環境變數/設定檔）做 Bearer 驗證
- Flutter App 內設定 server URL + token
- 未來要出外網時走 Cloudflare Tunnel / Tailscale，Hub 本身不管這件事

## 5. API 草案

```
認證：Authorization: Bearer <API_TOKEN>
身分：X-Participant-Id: <participant_id>（加入房間後取得）

POST   /api/rooms                          建立房間 {name, topic, session_key?, visibility?, style?, style_instructions?}
GET    /api/rooms?status=active            列出房間（含 pending assignment 提示）
GET    /api/rooms/{id}                     房間詳情 + 成員
POST   /api/rooms/{id}/archive             手動封存 / POST unarchive 解封
POST   /api/rooms/{id}/visibility          {visibility: public/private} 鎖定／解鎖（限建立者）
POST   /api/rooms/{id}/style               {style, style_instructions?} 說話方式（限建立者）
POST   /api/questions/{id}/cancel          撤回自己問出去、還沒被回答的問題
DELETE /api/rooms/{id}                     永久刪除房間（限建立者，不可復原）
POST   /api/rooms/{id}/join                {kind, session_key, assignment_id?, preferred_name?} → participant
POST   /api/rooms/{id}/leave               自行退出
POST   /api/rooms/{id}/heartbeat           純刷新 last_seen
GET    /api/rooms/{id}/messages?after_seq=&limit=   讀訊息（含 pinned 過濾）
POST   /api/rooms/{id}/messages            {content, mentions?, reply_to?} 發訊息
GET    /api/rooms/{id}/updates?after_seq=&timeout=  long-poll 通知
POST   /api/messages/{id}/pin              釘選 / DELETE 取消釘選
DELETE /api/messages/{id}                  軟刪除（人類管控）
POST   /api/rooms/{id}/assignments         指派 {target_session_key, note, assigned_name?}
GET    /api/assignments?session_key=&kind=&label=  查詢針對自己的指派（順便 upsert session 名錄）
GET    /api/sessions?include_human=        列出 Hub 見過且存活的 session（指派 UI 掃描來源；active/idle）
POST   /api/assignments/{id}/resolve       {status: accepted/declined}
WS     /ws?token=                          UI 即時通道

Board（4.9）
GET    /api/rooms/{id}/board?after_board_seq=       讀板（增量；0＝全量，含 tombstone）
POST   /api/rooms/{id}/board/objectives             新增 Objective
POST   /api/rooms/{id}/board/reorder                批次排序（整批一個 board_seq）
POST   /api/rooms/{id}/board/supervisor             {session_key} 指定／取消（限建立者）
POST   /api/board/objectives/{oid}/checklists       新增 Checklist
POST   /api/board/checklists/{cid}/tasks            新增 Task（可帶 source_seq）
PATCH  /api/board/{objectives|checklists|tasks}/{id}  改欄位（**拒收 status**）
DELETE /api/board/{objectives|checklists|tasks}/{id}  軟刪除（級聯，子孫一起領號）
POST   /api/board/tasks/{tid}/status                {status} 推狀態
POST   /api/board/tasks/{tid}/claim | /release      認領／放棄（CAS）
POST   /api/board/checklists/{cid}/status           {status}
POST   /api/board/objectives/{oid}/review           送審（閘 3）
POST   /api/board/objectives/{oid}/verify           確認無誤（**限人類**）
POST   /api/board/objectives/{oid}/complete         完成（閘 1、2）
POST   /api/board/objectives/{oid}/reopen | /cancel 打回（限人類）／取消
```

## 6. MCP Bridge 工具面

| 工具 | 說明 |
|------|------|
| `chatroom_guide` | 完整使用手冊（心智模型、慣例、錯誤碼對照）。**是工具不是 skill 檔**——手冊要對所有 agent 有效，而 skill 只有 Claude Code 讀得到。純 Markdown 副本在 `docs/CHATROOM.md`（供閱讀與包裝成 skill） |
| `chatroom_list_rooms` | 列出 active 房間 + 針對自己的 pending 指派（私人房只在你有份時出現） |
| `chatroom_join` | 加入房間；Codex 指派可帶 assignment_id 綁定原生 thread id |
| `chatroom_leave` | 退出房間 |
| `chatroom_read` | 讀取訊息（after_seq cursor / 只看 pinned） |
| `chatroom_post` | 發訊息，可 `mentions` ping 對象 |
| `chatroom_pin` / `chatroom_unpin` | 釘選管理 |
| `chatroom_wait` | long-poll 等待新訊息（含 mention 標示） |
| `chatroom_send_file` / `chatroom_get_file` | 附件收送；下載預設落在 **agent 工作目錄底下**的 `./.chatroom/downloads/<房>/<附件>/`，每個附件一個資料夾（同名附件不互相覆蓋），可用 `CHATROOM_DOWNLOAD_DIR` 覆寫 |
| `chatroom_ask_human` / `chatroom_read_answer` / `chatroom_questions` | 向房內人類定向提問；答案會在時間軸留下收據 |
| `chatroom_board` | 讀板（預設增量，`full=True` 取全量）。鼓勵 agent 經常查 |
| `chatroom_board_add` | 新增 Objective／Checklist／Task（`kind` 三選一，三層是嚴格的樹） |
| `chatroom_board_update` | 改狀態或內容。**完成就是推到 `done`**，沒有另一個「完成」工具 |
| `chatroom_board_claim` | 認領／放棄。**認領失敗是正常結果不是錯誤**，失敗時去領別的而不是重試 |

⚠️ **`verify` 刻意不暴露成工具**：確認週期無誤只有人類做得到，暴露了只會讓
agent 一直撞 403。agent 能做的是 `status="review"` 送審，然後在聊天室裡請人類確認。

Bridge 是薄殼：只做 REST 轉譯 + session_key 管理（從環境變數
`CHATROOM_SESSION_KEY` 取得，或自動生成存於本機）。Codex 的 App dispatcher
負責掃描所有活躍 thread、向 Hub 報到，並將訊息／指派精準 queue 到目標 session；
Bridge 以 assignment_id 取得 Hub 已登錄的 canonical thread id。

## 7. 開發階段

| 階段 | 內容 | 狀態 |
|------|------|------|
| **Phase 0** | 專案結構、規劃文件、Hub 核心可跑（房間/加入/訊息/命名）、MCP bridge 雛形 | ✅ 本次 bootstrap |
| **Phase 1** | Hub 完整：presence sweeper、自動封存、long-poll、pin、assignment、WebSocket、測試覆蓋 | |
| **Phase 2** | MCP bridge 完整化，Claude Code + Codex 實際接入驗證雙 agent 對話 | |
| **Phase 3** | Flutter UI：房間列表、聊天視圖、釘選牆、訊息管理、指派操作 | |
| **Phase 4** | 跨裝置部署：token 管理、開機自啟、外網通道（Tunnel/Tailscale） | |
| **Phase 5** | Board（4.9）：Hub 三層資料模型與守門、MCP 四工具、Flutter 板面 | ✅ 2026-09-01 |

## 8. 技術決策記錄

- **後端 Python 3.12 + FastAPI**：專案自帶 `.venv`（**不使用 U.E.P Core 環境**，
  本專案與 U.E.P 系列無關）；FastAPI 同時給 REST + WebSocket + OpenAPI 文件
- **SQLite 而非外部 DB**：單使用者基礎設施，WAL 模式足夠；跨裝置靠 Hub 集中，不做多節點
- **long-poll 而非 webhook 通知 agent**：agent 端（CLI 內的 MCP client）沒有穩定的
  可回呼位址；long-poll 讓 bridge 掌握主動權，語意也符合「agent 在等訊息」
- **seq cursor 而非 timestamp**：避免時鐘偏移與同秒衝突，分頁與通知共用同一游標
- **Flutter**：使用者指定；Windows 環境目前未安裝 Flutter SDK，Phase 3 前需安裝
