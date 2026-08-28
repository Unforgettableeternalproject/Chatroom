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
| content | TEXT | 內容（Markdown） |
| mentions | TEXT (JSON) | 被 ping 的 display_name 列表 |
| reply_to | TEXT | 回覆的 message id |
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
- Hub 內部用 in-process pub/sub（asyncio.Condition per room）串接
  long-poll 與 WebSocket，不需要外部 message broker

### 4.4 跨裝置
- Hub 綁 `0.0.0.0`，單一共享 `API_TOKEN`（環境變數/設定檔）做 Bearer 驗證
- Flutter App 內設定 server URL + token
- 未來要出外網時走 Cloudflare Tunnel / Tailscale，Hub 本身不管這件事

## 5. API 草案

```
認證：Authorization: Bearer <API_TOKEN>
身分：X-Participant-Id: <participant_id>（加入房間後取得）

POST   /api/rooms                          建立房間 {name, topic}
GET    /api/rooms?status=active            列出房間（含 pending assignment 提示）
GET    /api/rooms/{id}                     房間詳情 + 成員
POST   /api/rooms/{id}/archive             手動封存 / POST unarchive 解封
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
```

## 6. MCP Bridge 工具面

| 工具 | 說明 |
|------|------|
| `chatroom_list_rooms` | 列出 active 房間 + 針對自己的 pending 指派 |
| `chatroom_join` | 加入房間；Codex 指派可帶 assignment_id 綁定原生 thread id |
| `chatroom_leave` | 退出房間 |
| `chatroom_read` | 讀取訊息（after_seq cursor / 只看 pinned） |
| `chatroom_post` | 發訊息，可 `mentions` ping 對象 |
| `chatroom_pin` / `chatroom_unpin` | 釘選管理 |
| `chatroom_wait` | long-poll 等待新訊息（含 mention 標示） |

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

## 8. 技術決策記錄

- **後端 Python 3.12 + FastAPI**：專案自帶 `.venv`（**不使用 U.E.P Core 環境**，
  本專案與 U.E.P 系列無關）；FastAPI 同時給 REST + WebSocket + OpenAPI 文件
- **SQLite 而非外部 DB**：單使用者基礎設施，WAL 模式足夠；跨裝置靠 Hub 集中，不做多節點
- **long-poll 而非 webhook 通知 agent**：agent 端（CLI 內的 MCP client）沒有穩定的
  可回呼位址；long-poll 讓 bridge 掌握主動權，語意也符合「agent 在等訊息」
- **seq cursor 而非 timestamp**：避免時鐘偏移與同秒衝突，分頁與通知共用同一游標
- **Flutter**：使用者指定；Windows 環境目前未安裝 Flutter SDK，Phase 3 前需安裝
