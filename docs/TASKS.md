# Chatroom — 任務卡（Phase 1 ~ Phase 4）

> 本文件是 `docs/PLANNING.md` §7 開發階段的可執行拆解。
> 每張卡的粒度為「一張卡 = 一個 PR」，完成後併回 `develop`。
>
> - 規模：**S** ≈ 半天以內、**M** ≈ 一天、**L** ≈ 兩天以上（超過 L 就該再拆）
> - 狀態欄位只在非「待辦」時標註
> - 卡號一經指派不重用；取消的卡標 `已取消` 但保留卡號

## Phase 0 已完成範圍（拆卡基準）

實際落地的程度**超過** PLANNING 表格所寫，拆卡時請以此為準：

- `server/chatroom_server/` — 房間 CRUD、join/leave（房內唯一命名 + 冪等重入）、
  heartbeat、訊息發布/讀取、pin/unpin、軟刪除、long-poll `updates`、
  assignment 建立/查詢/resolve、presence sweeper（閒置移除 + 自動封存）、
  Bearer token 驗證、`/api/health`
- `bridge/chatroom_mcp/server.py` — 8 個 MCP 工具（list_rooms / join / leave /
  read / post / wait / pin / unpin）、session_key 持久化
- `tests/test_smoke.py` — 5 個冒煙測試（訊息流、重入、pin/delete、指派、leave）

**尚未存在**：WebSocket `/ws`、sweeper 專屬測試、認證測試、封存語意的完整處理、
分頁邊界、bridge 的指派工具與錯誤處理、Flutter app（`app/` 只有 README）、任何部署設施。

---

# Phase 1 — Hub 完整化

目標：Hub 成為可信賴的唯一真相來源，行為在邊界條件下可預測，測試能擋住回歸。

## P1-01：WebSocket `/ws` 即時通道

**狀態：✅ 完成（諾薇亞，f097230）**——訂閱指令為 `{"type":"subscribe","room_id":...}`
單房一次一間（可多次訂閱）；驗收條件 4（斷線殘留壓測）尚未寫專屬測試，留給 P1-10 一併驗。

- **範圍**：新增 `WS /ws?token=`，握手驗證 token，支援 client 送
  `{"action":"subscribe","room_ids":[...]}` 訂閱多房；房間有事件時推播增量訊息。
  接在既有 `RoomEvents` 上，不另建 broker。
- **不做**：WS 上的雙向發訊息（發言仍走 REST POST）、presence 顯示、離線訊息佇列。
- **驗收條件**
  1. 未帶 / 帶錯 token 的連線被拒（close code 明確，非 500）
  2. 訂閱 room A 後，另一路 REST 發訊息，WS 端於 1 秒內收到含 `seq` 的事件
  3. 只收到已訂閱房間的事件，未訂閱房間不外洩
  4. client 斷線後 server 端不留殘留 task / 訂閱項（重複連斷 100 次無成長）
  5. 有對應的 WS 測試（`httpx` / `starlette.testclient` 皆可）
- **依賴**：無
- **規模**：M

## P1-02：Presence sweeper 單元測試

**狀態：✅ 完成（諾薇亞，f097230）**——採短間隔 Config 而非 `_sweep_once()` 抽取；
驗收 2（human 不移除）與 5（例外續跑）尚無專屬測試，補測時建議順手做 `_sweep_once()` 重構。

- **範圍**：為 `_sweeper()` 建立可控時間的測試——用極短的 `idle_timeout` /
  `sweep_interval` Config，或把 sweeper 迴圈本體抽成可直接 await 的
  `_sweep_once()` 再測（建議後者，避免測試 sleep）。
- **不做**：改變 sweeper 的判定邏輯（那是 P1-03 / P1-04 的事）。
- **驗收條件**
  1. 逾時的 agent 被標為 `removed`，且房內出現對應 system 訊息
  2. 人類成員（`role='human'`）逾時**不**被移除
  3. 房內最後一個 agent 被移除後，房間轉為 `archived`
  4. 從未有 agent 加入過的空房間不會被誤封存
  5. sweeper 遇單次例外不會終止迴圈（注入例外後下一輪仍執行）
- **依賴**：無
- **規模**：M

## P1-03：解封後不被立刻重新封存

**狀態：✅ 完成（諾薇亞，64bb9ea + 607a897）**——採第三方案：`room.activated_at`
記錄最近一次變 active 的時間，sweeper 只計入該時點後加入的 agent。比寬限期
確定性強（不靠時間窗），比 `pinned_open` 少一個要人手動清的旗標。

- **範圍**：修正 `unarchive_room` 的實際缺陷——目前解封後房內沒有 active agent，
  下一輪 sweeper 會立刻再封存回去，人類完全無法把房間救回來。
  作法擇一（需在 PR 描述說明選擇理由）：解封時記錄 `unarchived_at` 並給予
  寬限期（新增 `CHATROOM_ARCHIVE_GRACE`），或加入 `pinned_open` 旗標。
- **不做**：改動自動封存的其他判定條件。
- **驗收條件**
  1. 解封後於寬限期內連續執行多輪 sweep，房間維持 `active`
  2. 寬限期過後仍無 agent → 正常再次封存
  3. 解封成功時房內出現 system 訊息（目前 archive/unarchive 皆未廣播）
  4. 對已是 `active` 的房間解封回傳明確結果，不製造重複 system 訊息
  5. 有涵蓋上述的測試
- **依賴**：P1-02（借用 `_sweep_once()` 的可測結構）
- **規模**：M

## P1-04：封存房間的唯讀語意一致化

**狀態：✅ 完成（諾薇亞，64bb9ea + 607a897）**——與卡面有一處刻意偏離：
`leave` 與人類 `delete_message` 在封存房仍允許（成員清理自身狀態、人類事後管控
不該被唯讀擋住），已含測試。`create_assignment` 經 `_room_or_404` 已擋 archived。

- **範圍**：目前只有 `post_message` / `join` 會擋 archived 房間；
  `pin` / `unpin` / `delete_message` / `leave` / `create_assignment` 走的是
  message id 或 participant，繞過房間狀態檢查。統一為：封存房間只允許讀取
  （`GET messages` / `GET updates` / `GET room`）與 `unarchive`。
- **不做**：權限分級（誰能封存誰不能）——單使用者環境不需要。
- **驗收條件**
  1. 對封存房間的所有寫入端點皆回 409 且錯誤訊息一致
  2. 讀取端點在封存房間仍正常
  3. archive 時房內留下 system 訊息作為時間軸標記
  4. 每個被封鎖的端點都有測試
- **依賴**：P1-03
- **規模**：M

## P1-05：跨房間身分驗證漏洞修補

**狀態：✅ 完成（諾薇亞，64bb9ea）**——`_participant()` 增加 room_id 比對；
`pin`/`unpin` 依 message 反查 room 後驗證。回歸測試在 tests/test_room_integrity.py。

- **範圍**：`_participant()` 只驗 participant 存在且 active，**不驗它屬於路徑上的
  room_id**。因此 A 房的 participant id 可以拿去 B 房 leave / 發訊息 / pin。
  改為驗證 `(participant_id, room_id)` 配對；`pin`/`unpin` 依 message 反查 room 後比對。
- **不做**：多租戶隔離、per-participant token。
- **驗收條件**
  1. 用他房 participant id 呼叫任一帶身分端點 → 403
  2. 正常同房呼叫不受影響（既有測試全綠）
  3. `heartbeat` 同樣受驗證，且只刷新該房身分的 `last_seen_at`
  4. 有專門的負向測試
- **依賴**：無
- **規模**：S

## P1-06：訊息分頁邊界與 `has_more`

- **範圍**：`GET /api/rooms/{id}/messages` 補上分頁契約——回傳
  `has_more` / `next_after_seq`；新增 `before_seq` 支援往回捲（UI 載入歷史）；
  `limit` 上下界與非法值處理；`updates` 內硬編碼的 `LIMIT 200` 抽成設定。
- **不做**：全文搜尋、時間區間查詢。
- **驗收條件**
  1. 房內 250 則訊息，`limit=100` 三次翻頁可完整取得且無重複無遺漏
  2. `has_more` 在最後一頁為 `false`
  3. `before_seq` 反向取得的順序與正向一致（皆以 seq 遞增排列）
  4. `limit=0` / 負數 / 超過上限 → 422 或夾到上限，行為有明文定義並測試
  5. `pinned_only` 與分頁參數同時使用時語意正確
- **依賴**：無
- **規模**：M

## P1-07：Assignment 過期機制

- **範圍**：`assignment.status` 定義了 `expired` 但沒有任何程式碼會產生它。
  在 sweeper 內加入：pending 超過 `CHATROOM_ASSIGNMENT_TTL`（預設 24h）→ `expired`。
  `GET /api/assignments` 明確只回 pending。
- **不做**：重新指派 / 提醒通知。
- **驗收條件**
  1. 超過 TTL 的 pending 指派被標為 `expired`，且不再出現在查詢結果
  2. 已 accepted / declined 的不受影響
  3. TTL 可由環境變數覆寫
  4. 有測試
- **依賴**：P1-02
- **規模**：S

## P1-08：認證與錯誤回應一致化

- **範圍**：統一錯誤格式（`{"error": {"code", "message"}}` 或明確沿用 FastAPI
  預設但補齊語意）；補齊 token 驗證測試；`api_token` 為空時在啟動 log 明確警告
  「未啟用驗證，僅限本機」；WS 與 REST 的驗證行為一致。
- **不做**：多 token / 權限範圍（Phase 4 再議）。
- **驗收條件**
  1. 設定 token 後，所有 `/api/*` 端點未帶或帶錯 token 皆 401（`/api/health` 除外）
  2. `/api/health` 不需 token 且不洩漏設定內容
  3. 空 token 啟動時 stderr 出現警告字樣
  4. 有涵蓋 REST 與 WS 的驗證測試
- **依賴**：P1-01（WS 驗證部分）
- **規模**：S

## P1-09：結構化日誌

- **範圍**：導入 `logging`，取代 sweeper 中的裸 `except Exception: pass`；
  記錄請求層級的關鍵事件（join / leave / archive / sweep 結果 / WS 連斷）；
  log level 由環境變數控制。
- **不做**：外部 log 聚合、tracing。
- **驗收條件**
  1. sweeper 例外會被記錄（含 traceback）且迴圈續行
  2. `CHATROOM_LOG_LEVEL` 可調整輸出量
  3. 日誌不含 token 等敏感值
  4. 有一個驗證「例外被記錄且不中斷」的測試
- **依賴**：P1-02
- **規模**：S

## P1-10：Hub 測試覆蓋補完與 CI 腳本

- **範圍**：補齊命名池（無 preferred_name、名字池耗盡）、long-poll 逾時路徑、
  重入後 `last_seen_at` 更新、軟刪除訊息在 `updates` 中的呈現等未覆蓋分支；
  加上 `pytest --cov` 設定與一鍵測試腳本。
- **不做**：效能 / 壓力測試（Phase 2 端到端時再看）。
- **驗收條件**
  1. `server/chatroom_server/` 行覆蓋率 ≥ 85%
  2. 一鍵指令可跑完整測試（使用專案自帶 `.venv`，非 U.E.P Core 環境）
  3. 測試不依賴真實時鐘 sleep 超過 2 秒
- **依賴**：P1-01 ~ P1-09
- **規模**：M

---

# Phase 2 — MCP Bridge 完整化與實際接入驗證

目標：Claude Code 與 Codex 兩個真實 agent 能透過 bridge 在同一房間對話。

## P2-01：Bridge 補齊指派相關工具

- **範圍**：新增 `chatroom_assignments`（查自己的 pending 指派）、
  `chatroom_resolve_assignment`（accept / decline）、`chatroom_heartbeat`。
  工具描述用繁體中文寫清楚使用時機，讓 agent 知道何時該呼叫。
- **不做**：bridge 端自動接受指派（保留 agent 的判斷權）。
- **驗收條件**
  1. 三個工具皆能對本機 Hub 正常往返
  2. 工具 docstring 明確說明用途與參數語意
  3. `chatroom_list_rooms` 的回傳中 pending 指派可讀（含 room_name / note）
- **依賴**：Phase 1 完成（API 契約穩定）
- **規模**：S

## P2-02：Bridge 錯誤處理與友善訊息

- **範圍**：目前一律 `raise_for_status()`，agent 只看到 HTTP 例外堆疊。
  改為捕捉並回傳結構化結果（`{"ok": false, "reason": "房間已封存，無法發言"}`），
  涵蓋 401 / 403 / 404 / 409 / 連線失敗 / 逾時。
- **不做**：自動重試（long-poll 除外，見 P2-03）。
- **驗收條件**
  1. Hub 未啟動時工具回傳可讀的中文說明，而非 traceback
  2. token 錯誤、房間封存、身分失效三種情境各有明確訊息
  3. 有以 mock transport 撰寫的 bridge 單元測試
- **依賴**：P2-01
- **規模**：M

## P2-03：Bridge 的 cursor 與身分續存

- **範圍**：`_identities` 只活在進程記憶體中，bridge 重啟即失去房間身分；
  `after_seq` 完全交給 agent 記憶，容易漏讀或重讀。
  改為在 `~/.chatroom/state.json` 持久化 room → (participant_id, last_seq)，
  `chatroom_read` / `chatroom_wait` 的 `after_seq` 可省略時自動沿用。
- **不做**：跨機器同步狀態。
- **驗收條件**
  1. bridge 重啟後 `chatroom_post` 不需重新 join 即可發言（身分仍有效時）
  2. 身分已失效（被 sweeper 移除）時自動偵測並提示需重新 join
  3. 省略 `after_seq` 的連續 `chatroom_read` 不重複、不遺漏
  4. state 檔損毀時能安全重建而非崩潰
- **依賴**：P2-02
- **規模**：M

## P2-04：Bridge 打包與啟動入口

- **範圍**：加上 `pyproject.toml`（或 `bridge/pyproject.toml`）與 console script
  entry point，讓 MCP 設定能以單一指令啟動；釘住相依版本。
- **不做**：發佈到 PyPI。
- **驗收條件**
  1. 於乾淨 venv 中可安裝並以 entry point 啟動 bridge
  2. 相依版本明確（`mcp`、`httpx`）
  3. README 記錄安裝步驟
- **依賴**：P2-03
- **規模**：S

## P2-05：Claude Code 接入設定與驗證

- **範圍**：撰寫 `docs/SETUP-CLAUDE-CODE.md`，含 MCP server 設定範例
  （環境變數 `CHATROOM_URL` / `CHATROOM_TOKEN` / `CHATROOM_SESSION_KEY` /
  `CHATROOM_AGENT_KIND=claude`），並實際在本機 Claude Code 完成一次
  list → join → post → read 流程。
- **不做**：Codex 端（見 P2-06）。
- **驗收條件**
  1. 依文件從零設定可成功載入 8+ 個 chatroom 工具
  2. 實際完成一次加入並發言，Hub 端看得到訊息與 system 訊息
  3. 文件記錄至少一個實測踩到的問題與解法
- **依賴**：P2-04
- **規模**：M

## P2-06：Codex CLI 接入設定與驗證

- **範圍**：同 P2-05，對象換成 Codex CLI（`CHATROOM_AGENT_KIND=codex`），
  文件 `docs/SETUP-CODEX.md`。特別確認 Codex 的 MCP 設定格式與環境變數傳遞方式。
- **不做**：修改 Hub 或 bridge 的核心邏輯（若發現必須改，另開卡）。
- **驗收條件**
  1. Codex CLI 能載入 chatroom 工具並成功 join
  2. Codex 發的訊息在 Hub 上 `kind='codex'` 標記正確
  3. 兩端 session_key 不衝突（各自獨立）
- **依賴**：P2-04
- **規模**：M

## P2-07：雙 agent 端到端對話演練

- **範圍**：Claude Code 與 Codex 同時加入同一房間，進行一次有 mention、
  有 pin、有 long-poll 等待的完整往返；記錄逐步操作與觀察到的行為到
  `docs/E2E-LOG.md`。這是驗證「機構是否真的成立」的關鍵卡。
- **不做**：自動化這個流程（人工演練即可）。
- **驗收條件**
  1. A 發訊 mention B，B 的 `chatroom_wait` 被喚醒且 `you_were_mentioned` 為 true
  2. 雙方訊息的 seq 嚴格遞增無重號
  3. 其中一方閒置逾時後被自動移出，另一方讀得到 system 訊息
  4. 最後一個 agent 離開後房間自動封存
  5. 演練紀錄含實際耗時與發現的問題清單
- **依賴**：P2-05、P2-06
- **規模**：L

## P2-08：E2E 演練問題修復

- **範圍**：處理 P2-07 記錄的問題清單。若問題數量或性質超出一個 PR，
  於本卡中再拆為 P2-08a/b/... 子卡。
- **不做**：範圍蔓延到 Phase 3 的 UI 議題。
- **驗收條件**
  1. P2-07 清單中每一項皆有處置（修復 / 明確延後並記錄理由）
  2. 修復項皆有回歸測試
  3. 重跑一次縮短版 E2E 演練通過
- **依賴**：P2-07
- **規模**：M（視清單調整）

---

# Phase 3 — Flutter 人類管控 UI

> ⚠️ 本機**尚未安裝 Flutter SDK**，P3-01 是所有後續卡的硬前置。

## P3-01：Flutter 開發環境安裝與驗證

- **範圍**：在 Windows 安裝 Flutter SDK（stable channel）、設定 PATH、
  安裝所需 toolchain（Windows desktop 一定要；Android 視是否要上手機而定），
  執行 `flutter doctor` 直到無阻斷性問題；把安裝步驟與版本寫入 `docs/SETUP-FLUTTER.md`。
- **不做**：iOS toolchain（Windows 無法）、建立專案（P3-02）。
- **驗收條件**
  1. `flutter doctor` 對目標平台無 ✗
  2. `flutter create` 出的樣板能在 Windows desktop 跑起來
  3. 文件記錄 SDK 版本與安裝路徑，並註明未來升級注意事項
  4. SDK 路徑不寫死進任何專案程式碼
- **依賴**：無
- **規模**：M

## P3-02：`app/` 專案骨架與設定畫面

- **範圍**：在 `app/` 建立 Flutter 專案，決定並落地狀態管理方案（於 PR 說明選型理由）、
  資料夾結構、主題（含深色）；實作「伺服器設定」畫面：server URL + API token，
  持久化於本機安全儲存，附連線測試按鈕（打 `/api/health`）。
- **不做**：任何聊天功能。
- **驗收條件**
  1. `flutter analyze` 無警告，`flutter test` 通過
  2. 設定的 URL / token 重啟 app 後仍在
  3. 連線測試對正確 / 錯誤 token 各有明確的中文提示
  4. token 不出現在任何 log 或畫面明碼（可切換顯示）
- **依賴**：P3-01
- **規模**：M

## P3-03：API client 層

- **範圍**：以 Hub 的 OpenAPI 為準，實作 Dart 端的 REST client 與資料模型
  （Room / Participant / Message / Assignment），統一錯誤轉譯為 app 層例外。
- **不做**：WebSocket（P3-04）、UI。
- **驗收條件**
  1. Phase 1 定案的所有端點皆有對應方法
  2. 401 / 403 / 404 / 409 轉為具語意的例外型別
  3. 以 mock HTTP client 撰寫的單元測試覆蓋主要路徑
  4. 模型欄位與 server schema 一致（含 `seq` 為整數 cursor）
- **依賴**：P3-02、P1-06
- **規模**：M

## P3-04：WebSocket 即時連線層

- **範圍**：連上 `/ws`，管理訂閱、自動重連（指數退避）、斷線期間以 REST
  `after_seq` 補齊漏掉的訊息。
- **不做**：離線編輯佇列。
- **驗收條件**
  1. 斷網後恢復，5 秒內自動重連並補齊斷線期間訊息，無重複無遺漏
  2. 連線狀態（連線中 / 重連中 / 離線）可被 UI 觀察
  3. app 進背景 / 前景切換不造成連線洩漏
- **依賴**：P3-03、P1-01
- **規模**：L

## P3-05：房間列表畫面

- **範圍**：列出 active 房間（名稱、主題、成員數、最後活動時間），
  支援切換檢視封存房間、建立新房間、封存 / 解封操作。
- **不做**：搜尋與排序（後續增強）。
- **驗收條件**
  1. 列表與 Hub 狀態一致，下拉可刷新
  2. 建立房間後立即出現在列表
  3. 封存 / 解封操作即時反映，且解封後房間確實維持 active（驗證 P1-03）
  4. 空狀態與錯誤狀態有中文提示
- **依賴**：P3-03
- **規模**：M

## P3-06：聊天視圖

- **範圍**：訊息串（依 seq 排序）、system 訊息與 chat 訊息視覺區分、
  Markdown 渲染、發送者名稱與時間、往上捲載入歷史（用 `before_seq`）、
  即時新訊息插入並維持捲動位置。
- **不做**：釘選牆（P3-07）、管理操作（P3-08）。
- **驗收條件**
  1. 250 則以上訊息可流暢往回捲，無重複無跳號
  2. 新訊息即時出現；使用者若正在看歷史則不強制捲到底，改顯示「有新訊息」提示
  3. system 訊息樣式明顯不同於一般發言
  4. Markdown 基本語法（粗體、清單、行內程式碼、程式碼區塊）正確渲染
- **依賴**：P3-04、P3-05
- **規模**：L

## P3-07：人類發言與 mention

- **範圍**：人類以 `role='human'` join 房間取得身分（裝置識別作 session_key），
  輸入框發送訊息、`@` 自動完成房內成員以填入 `mentions`、回覆某則訊息。
- **不做**：附件、表情反應。
- **驗收條件**
  1. 人類發言在 Hub 上 `role='human'`、`kind='human'`
  2. `@` 選單只列出房內 active 成員，選取後 `mentions` 正確送出
  3. 被 mention 的 agent 在 `chatroom_wait` 端確實收到標記（跨系統驗證）
  4. 回覆訊息的 `reply_to` 正確，UI 顯示被回覆的原文摘要
  5. 人類身分不會被 sweeper 移除（驗證 P1-02 條件 2）
- **依賴**：P3-06
- **規模**：M

## P3-08：釘選牆與訊息管理

- **範圍**：釘選訊息的獨立檢視、在聊天視圖中釘選 / 取消釘選、軟刪除訊息
  （含確認對話框與刪除後的占位呈現）。
- **不做**：編輯訊息、硬刪除。
- **驗收條件**
  1. 釘選牆只顯示 `pinned=1` 且未刪除的訊息，可跳回原文位置
  2. 釘選 / 取消即時同步到其他連線的 client
  3. 刪除需二次確認，刪除後顯示「訊息已刪除」占位而非消失
  4. 對封存房間，釘選與刪除操作被停用（呼應 P1-04）
- **依賴**：P3-07
- **規模**：M

## P3-09：指派操作畫面

- **範圍**：對房間建立指派（輸入 target session_key + note）、
  檢視房間的指派狀態（pending / accepted / declined / expired）。
  提供最近見過的 session_key 快選，減少手抄 uuid 的痛苦。
- **不做**：agent 探索 / 自動列舉線上 session（Hub 目前無此 API；若需要另開 Hub 卡）。
- **驗收條件**
  1. 建立指派後，對應 agent 的 `chatroom_list_rooms` 能看到該 pending 邀請
  2. agent 加入後 UI 上狀態自動轉為 accepted
  3. 過期指派顯示為 expired（驗證 P1-07）
- **依賴**：P3-05
- **規模**：M

## P3-10：UI 打包與手動測試清單

- **範圍**：產出 Windows desktop 建置（以及若環境允許的 Android APK）；
  撰寫 `docs/UI-TEST-CHECKLIST.md` 手動測試清單並執行一輪。
- **不做**：CI 自動建置、應用商店上架。
- **驗收條件**
  1. release 建置可在未安裝 Flutter 的機器上執行
  2. 手動測試清單覆蓋 P3-05 ~ P3-09 的主要流程，全數通過或有記錄的已知問題
  3. 建置步驟寫入文件
- **依賴**：P3-08、P3-09
- **規模**：M

---

# Phase 4 — 跨裝置部署

## P4-01：Token 管理與安全基線

- **範圍**：token 產生工具（`python -m chatroom_server.token` 或同等）、
  `.env` / 設定檔載入、`.env.example`、確保 token 不進版控；
  複查所有日誌與錯誤訊息不外洩 token。
- **不做**：多 token、輪替、per-device 憑證（單使用者環境暫不需要，記為未來項）。
- **驗收條件**
  1. 可一鍵產生高熵 token 並寫入本機設定
  2. `.gitignore` 涵蓋設定檔與 `chatroom.db*`
  3. 以錯誤 token 掃過所有端點，回應中不含正確 token 的任何片段
  4. 文件說明 token 應如何配發給 bridge 與 Flutter app
- **依賴**：P1-08
- **規模**：S

## P4-02：區網部署設定

- **範圍**：Hub 綁 `0.0.0.0` 的正式設定、Windows 防火牆規則說明、
  CORS 設定（Flutter web / desktop 需要時）、確認多 client 併發下
  seq 發放與 WAL 寫入無誤。
- **不做**：外網暴露（P4-04）。
- **驗收條件**
  1. 同網段另一台裝置能連上並完成 join → post → read
  2. 三個以上 client 同時發訊息，seq 無重號無跳號
  3. 部署步驟寫入 `docs/DEPLOY.md`
- **依賴**：P4-01
- **規模**：M

## P4-03：Windows 開機自啟

- **範圍**：把 Hub 註冊為開機自動啟動的常駐服務（工作排程器或 NSSM，
  於 PR 說明選型理由）；含啟動失敗重試、log 落檔、啟停與狀態查詢指令。
- **不做**：Linux / macOS 的等價設定（未來需要再開卡）。
- **驗收條件**
  1. 重開機後 Hub 自動在預期 port 上服務
  2. 手動 kill 進程後能自動重啟
  3. log 落在固定路徑且有輪替或大小上限
  4. 有明確的停用 / 移除步驟
- **依賴**：P4-02
- **規模**：M

## P4-04：外網通道（Tunnel / Tailscale）

- **範圍**：評估並落地一種外網存取方案（Cloudflare Tunnel 或 Tailscale），
  在 `docs/DEPLOY.md` 記錄選型比較與設定步驟；確認 WebSocket 能穿透該通道。
- **不做**：兩種都做；自架反向代理 + 憑證。
- **驗收條件**
  1. 離開家用網路的裝置能連上 Hub 並完成完整聊天流程
  2. **WebSocket 在通道下正常運作且長連線穩定 ≥ 30 分鐘**（這是最容易踩雷的點）
  3. long-poll 25 秒掛起不被通道中間層提早切斷
  4. 未授權存取仍被 token 擋下
- **依賴**：P4-03
- **規模**：L

## P4-05：資料備份與維運

- **範圍**：SQLite 定期備份（WAL 模式下用 `VACUUM INTO` 或 backup API，
  不可直接複製檔案）、保留策略、還原演練；訊息量成長的體積觀察。
- **不做**：異地備份、加密備份。
- **驗收條件**
  1. 備份腳本在 Hub 執行中可安全產出一致快照
  2. 從備份還原後資料完整（含 seq 連續性）
  3. 還原演練有紀錄
- **依賴**：P4-03
- **規模**：S

## P4-06：部署文件收斂與整體驗收

- **範圍**：把 P4-01 ~ P4-05 的片段整併為單一份可依循的 `docs/DEPLOY.md`；
  從零跑一次完整部署驗收（Hub → bridge → app → 外網）。
- **不做**：新功能。
- **驗收條件**
  1. 依文件從零部署成功，過程中不需要查閱其他文件或原始碼
  2. 完整驗收：桌機 Hub + Claude Code + Codex + 手機/筆電 Flutter app 同房對話
  3. PLANNING.md §7 階段表狀態更新為完成
- **依賴**：P4-04、P4-05
- **規模**：M

---

## 附錄：依賴總覽

```
Phase 1
  P1-01(WS,進行中) ─┬─► P1-08 ─┐
  P1-02(sweeper測試,進行中) ─┬─► P1-03 ─► P1-04 ─┤
                             ├─► P1-07          ├─► P1-10
                             └─► P1-09          │
  P1-05（獨立）──────────────────────────────────┤
  P1-06（獨立）──────────────────────────────────┘

Phase 2
  P1-10 ─► P2-01 ─► P2-02 ─► P2-03 ─► P2-04 ─┬─► P2-05 ─┬─► P2-07 ─► P2-08
                                             └─► P2-06 ─┘

Phase 3
  P3-01 ─► P3-02 ─► P3-03 ─┬─► P3-04 ─► P3-06 ─► P3-07 ─► P3-08 ─┬─► P3-10
                           └─► P3-05 ──────────┬────────────────┘
                                               └─► P3-09 ────────┘

Phase 4
  P1-08 ─► P4-01 ─► P4-02 ─► P4-03 ─┬─► P4-04 ─┬─► P4-06
                                    └─► P4-05 ─┘
```

**可並行的機會**：P1-05 與 P1-06 完全獨立，可與進行中的 P1-01 / P1-02 同時推進。
P2-05 與 P2-06 可並行。Phase 3 的 P3-01（Flutter 安裝）與整個 Phase 2 無依賴關係，
**建議提早開始安裝**，因為 SDK 安裝時間長且容易卡在 toolchain。
