# 遠端派工（Remote Ops）規劃書

分支：`feature/remote-ops`（不公開釋出，成熟後再併回 develop）。
撰寫：2026-09-16，敏卡。狀態：**第 9 節已裁決（2026-09-16），P1 開工。**

## 0. 一句話

讓房裡的人類在**有限控制**下，從聊天室啟動艾斯維爾這台機器上的 Claude Code，
對 AI-Website 讀票、調查、實作、commit；agent 是**單次任務、用完即結束**，
超過上限就排隊，撞到 rate limit 就停收並自動續跑，房間本身**持續存在**。

## 1. 起源與範圍

- 起源：艾斯維爾將離開公司一段時間，這段期間他的機器仍要能對 AI-Website 提供
  實作與調查能力，操作者是其他人類（房內成員）。
- 第一階段只開放 **AI-Website**（`mind-door/AI-Website/` 下的 JSAI-Web / JSAI-API /
  JSAI-Functions / JSAI-Skills）。其他專案不在允許清單內，執行器直接拒絕。
- 不做：持久 agent、多主機分派、其他專案、公開釋出。

## 2. 現況（探索與 PM 記憶的結論）

**已經有的、直接復用：**

| 能力 | 位置 | 用途 |
|---|---|---|
| Board v2：Objective（週期）→ Checklist（階段）→ Task（卡） | `board*` 表 | 人類開階段與想法板，agent 開卡 |
| Task claim CAS、orphaned、task_request | `board_task`、`board_task_request` | 卡的認領與接手 |
| 想法板（段落制，人類段落 agent 不可改） | `board_scratchpad*` | 人類記錄想法／需求 |
| 指派（assignment）與 session 名錄 | `assignment`、`session` | 「召喚」某個 session 進房 |
| watcher（session／房內）與 `codex queue` 外部推入 | `bridge/chatroom_mcp/watch.py` | 通知；Codex 冷啟動以外的喚醒先例 |
| 人類／agent 分離憑證、主持人模式 | `access_token.audience` | 人類操作與 agent 操作分權 |
| `chatroom_hold`、heartbeat、subagent 身分 | bridge + Hub | 長工作不被 sweeper 踢 |

**完全沒有的（本階段核心新件）：**

1. 「遠端請求 → 本機**冷啟動**一個新的 Claude Code session」的執行器。
   現有鏈路止於通知；Codex 那條 `codex queue` 只能餵給**已在跑**的 thread。
2. 房間類型。`room` 沒有 `kind` 欄位，所有房都走「無 active agent 即自動封存」。
3. 執行請求的資料模型、佇列、併行上限、rate limit 狀態。

**Claude Code headless 能力（已查證，2.1.273）：**

- `claude -p --output-format stream-json` 一行一事件；最終 `result` 事件帶
  `session_id`、`usage`、`total_cost_usd`、`num_turns`、`subtype`
  （`success` / `error_max_turns` / `error_max_budget_usd` / `error_during_execution`）。
- 參數：`--max-turns`、`--max-budget-usd`、`--permission-mode`、`--allowedTools`、
  `--mcp-config`、`--append-system-prompt`、`--resume <session_id>`、`--model`。
- 429：CLI 自動重試（`CLAUDE_CODE_MAX_RETRIES`，預設 10），stream 裡有
  `system/api_retry` 事件（`error: rate_limit`、`retry_delay_ms`）；重試耗盡
  → `subtype: error_during_execution`。週／月上限是終端錯誤，訊息是
  `You've hit your weekly limit` 類字串，**不會自動重試**。
- Hooks：`PreCompact` **不能取消壓縮**、`SessionEnd` 只是通知；
  `PreToolUse` 回 exit 2 可以**擋下工具並把理由回給模型**。
  **沒有任何方式從外部讀 context 使用百分比**；只能自己從每則
  assistant 訊息的 `usage` 累計。

## 3. 架構

```
房內人類（App）──► Hub（權威：agent_run 佇列、狀態、事件）◄── 執行器 runner（艾斯維爾機器）
                          │                                        │ 每次一個子進程
                          ▼                                        ▼
                    任務板 / 想法板                      claude -p（AI-Website 工作樹）
                                                                   │ MCP bridge
                                                                   └──► 回房發言、開卡、更新卡、ask_human
```

三個原則：

1. **Hub 是佇列與狀態的唯一真相**，執行器是笨執行者：領一筆、起進程、回報、領下一筆。
   執行器重啟不丟佇列；Hub 看得到「誰在跑、誰在排、限額狀態」。
2. **agent 進房用的是既有 bridge**，一個 run 一個 session_key
   （`claude-run-<run_id>`），身分、發言、開卡走現有工具，Hub 不為 run 另開通訊路徑。
3. **人類的控制面是板不是 shell**：人類決定「做什麼、什麼時候做、要不要做」，
   agent 決定「怎麼做」。人類不能下任意 prompt 給執行器（見 §6）。

## 4. 資料模型（Hub）

### 4.1 房間類型

`room.kind`：`chat`（預設，現況）／`ops`（工作房）。

- `ops` 房**不自動封存**、不進 purge；agent 閒置移除照舊（它們本來就該走）。
- `ops` 房固定掛一塊板（建房時建或指定），板隨房；解掛要主持人。
- 建 `ops` 房限人類憑證（split 模式）或主持人。
- 列表與 App 用 `kind` 分區顯示；既有房一律 `chat`（migration 補欄預設）。

### 4.2 執行請求 `agent_run`

```
agent_run
  id, room_id, board_id
  kind          ticket | investigate | stage | scheduled | handoff
  project       允許清單的 key（第一階段只有 ai-website）
  ref           checklist_id 或 task_id（做哪個階段／哪張卡）
  brief         人類寫的簡述（限長度；模板化，見 §6）
  requested_by  actor（人類 participant／actor_key）
  status        queued | claimed | running | limited | handoff | done | failed | cancelled
  priority, position
  runner_id, claude_session_id, attempt, parent_run_id（交接鏈）, handoff_depth
  usage_json    最後一次回報的 tokens / cost / turns
  result        收工摘要（agent 自己寫，執行器補 exit 資訊）
  created_at, claimed_at, started_at, ended_at, updated_at
agent_run_event（稽核串：狀態每一次變化、誰改的、原因）
```

規則：

- 一房一佇列，FIFO + priority；同一 `ref` 在 queued/running 時**不得重複**（409）。
- `cancelled` 只有人類或主持人能下；running 的 cancel 由執行器收到後殺進程，
  agent 的卡由既有孤兒化流程處理。
- `handoff`：run 自己宣告交接，Hub 建子 run（`parent_run_id`），
  `handoff_depth` 上限預設 5，超過即 `failed` 並通知人類。

### 4.3 執行器 `runner`

```
runner
  id, host, label, status(online|paused|limited|offline)
  max_parallel（預設 3）, running_count
  limited_until, limit_reason（rate_limit | weekly_limit | manual）
  usage_window_json（近 5 小時累計 tokens/cost，供軟上限）
  last_seen_at, version
```

- 執行器用 agent 憑證註冊，heartbeat 走 `/api/runners/{id}/heartbeat`（帶狀態），
  逾時未見即 `offline`，房內 system 訊息通知。
- 領單：`POST /api/runners/{id}/claim` 由 Hub 用單一 `UPDATE … RETURNING`
  發放（沿用領號教訓：兩句之間的 await 會讓兩個執行器領到同一筆）。

### 4.4 儀表板狀態 `runner.dashboard_json`

執行器每次 heartbeat 帶上、Hub 原樣存、App 面板讀：

```
repos[]        每個允許 repo：path、branch、unpushed_count、unpushed[]（sha、標題、時間）、dirty
usage          近 5 小時 tokens / cost、軟上限、剩餘；近 7 天累計
limits         status、limited_until、limit_reason
runs           running[]（run id、ref、開始時間、目前 turns、context 估算）、queued_count
runner         version、started_at、last_restart_reason
```

「尚未推送的 commit」是這裡最重要的一格——本機沒有人類，push 是房內人類從
儀表板按的（§5.6）。

### 4.5 排程（第二階段）

`board_schedule`：掛在板或 checklist 上，`interval`／`cron`、`brief` 模板、
`enabled`、`last_fired_at`。Hub sweeper 到時建 `agent_run(kind=scheduled)`。
先做人工觸發，排程等主流程穩了再開。

## 5. 執行器（本機常駐）

新子系統 `runner/`（Python，沿用專案 `.venv`），與 bridge 分開：bridge 是 agent 在房裡的手，
runner 是「起 agent」的手，職責不能混。

### 5.1 主迴圈

```
heartbeat → 若 status 允許且 slots 有空 → claim → 準備工作環境 → spawn → 監看 stream
        → 結束時回報（done/failed/handoff/limited）→ 清理 → 回到 heartbeat
```

### 5.2 spawn 參數

- cwd：`project` 對應的允許路徑（`runner/config`），不是 brief 說了算。
- `--permission-mode auto`（裁決；實測 2.1.273 合法值含 `auto`）；硬限制不靠權限模式，
  靠 §6.4 的 hook 與執行器守門。**`--allowedTools` 在 auto 模式下不是限制**，不能當白名單用。
- `--output-format stream-json` **必須配 `--verbose`**，否則直接 exit 1。
- `--model`：預設 Opus 5（裁決），profile 可依 run kind 覆寫。
- **不用 `--bare`**：`--bare` 只認 API key，本機是 OAuth 登入，加了就是
  「Not logged in」而 `result.subtype` 照樣是 `success`（exit 1、assistant 層 `is_error`）。
  執行器判成敗要看 exit code 與 `is_error`，不能只看 `subtype`。
- 設定隔離：不加 `--bare` 就會載入 `~/.claude/settings.json` 的全域 hooks（persona 注入、
  記憶健檢等艾斯維爾個人的東西）。執行器用獨立的 `CLAUDE_CONFIG_DIR`（例如
  `%LOCALAPPDATA%/UEP/Chatroom/runner/claude-config`），艾斯維爾離開前在那個目錄
  `claude /login` 一次；run 的 hooks 全部寫在那個目錄的 settings。
  ⚠️ 待驗：獨立 config dir 下 claude.ai 連接器（Atlassian）是否仍可用——連接器綁帳號，
  應該可以，P2 第一天實測；不行就退回共用設定並在 run 的 `--settings` 裡覆寫掉不要的 hook。
- `--mcp-config` 的 stdio server：模組搜尋路徑用 `env.PYTHONPATH` 指到 `bridge/`，
  **不要靠 `cwd` 欄位**（實測不生效，會 `No module named chatroom_mcp`）。
  chatroom 工具在 headless 下是 deferred 工具，模型要先 `ToolSearch` 才能叫，run 契約要提醒。
- `--mcp-config`：只掛 chatroom bridge（`CHATROOM_SESSION_KEY=claude-run-<id>`、
  `CHATROOM_DEFAULT_NAME=<執行器 label>-<短 id>`）＋ 專案需要的 MCP（Jira，若可用）。
- `--append-system-prompt`：run 契約（§6.3）。
- `--max-turns`、`--max-budget-usd`：每 run 上限，profile 設定。
- hooks（run 專用 settings，寫進暫存 `--settings`）：
  - `PreToolUse`：讀 `handoff.flag`；有旗標就回 exit 2 並附「請立刻交接」訊息。
  - `PreCompact`：寫 `compacted` 標記（事後判定這個 run 已經被壓過一次）。
  - `Stop` / `SessionEnd`：通知執行器收尾（保險，主要靠 stream 的 `result`）。

### 5.3 stream 監看

- 每則 assistant 訊息的 `usage`（input + cache_read + cache_creation）＝當前 context 大小。
  超過 `context_soft_limit`（預設模型視窗的 70%）→ 寫 `handoff.flag`。
  這是**唯一**能在自動壓縮之前逼 agent 交接的路徑；壓縮本身擋不住。
- `system/api_retry` 且 `error == rate_limit`：記錄；連續出現達門檻即把 runner 標
  `limited`，**停止領新單**，房內發 system 訊息。既有 run 讓 CLI 自己重試。
- `result.subtype == error_during_execution` 且最後錯誤是 rate limit：
  run 標 `limited`，執行器排 `--resume <session_id>` 的重試，退避 5→15→30→60 分鐘，
  每次退避都在房內說一句；恢復成功也說一句。
- 訊息含週／月上限字串：runner `limited(weekly_limit)`，**不自動重試**，等人類解除。
- 其他非零 exit／`error_max_turns`：run `failed`，卡留給人類決定。

### 5.4 交接

1. 收到 `handoff.flag` 的下一次工具呼叫被擋，理由文字要求 agent：
   把「已做／未做／下一步／注意事項」寫到卡（`chatroom_board_update` 的 note 或附件），
   卡狀態保持 `in_progress` 但**釋放認領**，然後結束。
2. run 以 `handoff` 收尾，Hub 建子 run，brief = 原 brief + 指向那張卡。
3. 子 run 開場先讀卡再動手。認領由子 run 自己做（沿用「Hub 不代為認領」原則）。
4. 若 agent 沒照做就結束（stream 沒看到交接寫入）：執行器仍建子 run，但 brief 註明
   「前一輪未留交接，請從卡的 git 狀態與工作樹重建現況」。

### 5.5 併行與工作樹

- `max_parallel` 預設 3；超過即排隊，房內看得到位置。
- **同一 repo 同時只允許一個 run 寫入**（AI-Website 是三個 repo，各一把鎖）。
  PM 記憶裡「共用工作樹互相覆蓋」「commit 帶走別人的 index」發生過不只一次，
  遠端無人看著時代價更高。第一階段：一個 run 一個 repo 鎖，跨 repo 的票序列做；
  第二階段再評估 worktree（放 repo 外）。
- run 開始前執行器記錄 `git status --porcelain`，結束後比對；
  未 commit 的變更由 agent 在收工摘要列出，不自動 stash、不自動還原。

### 5.6 推送（`push` run）

本機沒有人類，所以 push 也是一種 run，但**只有房內人類能建**，且形狀固定：

- `agent_run(kind=push, ref=<repo>, brief=<要推的分支>)`；儀表板上每個 repo 有
  「推送」鈕，按下去就是建這筆。
- 執行器對 `push` run 不起 Claude，直接跑固定腳本：確認分支在允許清單、
  `git log origin/<branch>..<branch>` 與儀表板顯示的一致（sha 集合相同才推，否則拒絕並回報）、
  `git push`、回報結果。**不經模型**：push 沒有需要判斷的事，經模型只是多一個出錯的地方。
- 允許的目標分支由執行器設定寫死（AI-Website：`jsai_dev`、`feature/*`）；
  `jsai_prod` 永遠不在清單裡，任何 run 都推不了。

### 5.7 維護與重啟

- 常駐形式：Windows 排程工作（裁決），登入時啟動、失敗自動重啟、每 5 分鐘檢查存活。
- 房內人類可下 `runner_command`：`pause`（不領新單，跑完手上的）、`resume`、
  `restart`（等所有 run 結束後自我重啟；有 run 在跑就排到它們結束後）、`drain`（取消排隊、跑完現有）。
  命令由 Hub 存、執行器 heartbeat 時取。
- 每日維護窗（預設 04:00，可設）：若無 run 在跑，執行器自我重啟並清暫存；有在跑就順延到下一次 heartbeat 無 run 時。
- 執行器啟動時：驗 `claude --version`、驗 GPG 簽章可用（`gpg --clearsign` 探針）、
  驗每個允許 repo 可讀寫且分支正確；任一失敗即 `status=offline(reason)` 並在房內講。
  GPG 由艾斯維爾自行處理（裁決），執行器只驗、不代管 passphrase。

## 6. 人類的控制面

### 6.1 誰能做什麼

| 動作 | 誰 |
|---|---|
| 建 ops 房、指定執行器允許的專案 | 主持人（艾斯維爾，離開前設好） |
| 開週期／階段、寫想法板 | 房內人類 |
| 「派工」：對一個階段或一張卡建 run | 房內人類（非 viewer） |
| 取消 run、解除 limited、暫停執行器 | 房內人類 |
| 開卡、認領、改卡、commit | agent |
| push（建 `push` run） | 房內人類，從儀表板按（§5.6） |
| 週期「確認無誤」、部署 | 人類；部署不在本系統範圍內 |
| 暫停／恢復／重啟執行器 | 房內人類（§5.7） |

### 6.2 派工的形狀

人類**不寫自由 prompt**。派工 = 選「階段或卡」+ 選「模板」+ 一段簡述（限 2000 字）：

- `investigate`：只讀。查票、查程式、回房報告與建議，不改檔。
- `ticket`：讀票（Jira key 在階段標題或簡述）、實作、跑既有驗證、commit 到指定分支、
  在卡上回報；未實機測試要明說。
- `stage`：把整個階段當一組工作，agent 自己拆卡、逐張做，直到階段做完或交接。

模板正文在 `runner/prompts/`，改模板要進版控，房裡改不了。

### 6.3 run 契約（append system prompt 的骨幹）

- 你是單次任務執行者，房間 `<room>`、卡 `<ref>`；開場先 join、讀卡、讀想法板相關段落。
- 工作只在 `<cwd>`；分支規則、commit 格式（單行 ≤15 字＋日期）、GPG、不 push、
  不 `git add -A`、commit 前看 index——沿用 AI-Website 三個 repo 的 CLAUDE.md。
- 卡住就 `chatroom_ask_human`（timeout 要設，沒人答就寫進卡結束，不空等）。
- 收到「請立刻交接」就照 §5.4 做，不要試圖再多做一步。
- 結束前寫收工摘要：做了什麼、驗證了什麼、沒驗證什麼、未 commit 的東西、下一步。

### 6.4 硬限制（系統擋，不靠 prompt）

裁決：**不能完全相信對方的人類**。以下每一條都由執行器或 hook 強制，agent 與派工者都繞不過：

| 層 | 限制 |
|---|---|
| Hub | 只有人類憑證能建 run；執行器 token 只能領單、回報、heartbeat。派工者每日 run 數上限（預設 20）、同時排隊上限（預設 5）。 |
| 執行器 | `project` 必須在允許清單；cwd 由清單決定；每 run `--max-turns`、`--max-budget-usd`、牆鐘上限（預設 90 分鐘）；5 小時窗軟上限到了停收。 |
| `PreToolUse` hook（拒絕清單，exit 2） | `git push`（非 push run 一律擋）、`git reset --hard`、`git clean`、`git checkout`/`switch` 到允許清單外的分支、`git branch -D`、`git rebase`、`--no-verify`、`--no-gpg-sign`；`rm -rf`／`Remove-Item -Recurse`；任何寫入 cwd 以外的路徑；讀寫 `.env*`、`*.pem`、`server/.env`、`~/.claude/`、`~/.gnupg/`、執行器自己的設定與 hooks；`npm publish`、`az `、`wrangler deploy`、`gh pr merge`；`curl`/`Invoke-WebRequest` 到允許網域以外。 |
| `PreToolUse` hook（允許但記錄） | 其餘每一次工具呼叫寫進 run 的 tool log，隨收工摘要附回卡。 |
| 模板 | brief 只能進模板的一個欄位，模板本身進版控；brief 內容出現在 prompt 時包一層框架
（同 `style_instructions` 的 `CUSTOM_STYLE_FRAME` 做法），明說它是任務描述不是指令。 |
| 分支 | 只允許 `jsai_dev` 與 `feature/*`；`jsai_prod`、`main`、`master` 在任何 repo 都不可 checkout、不可 push。 |

⚠️ **matcher 必須同時寫 `Bash|PowerShell`**（實測：Windows 上模型預設選 PowerShell，
只擋 Bash 時 `echo hi` 直接跑過去）。被擋的訊息回給模型的形狀是
`PreToolUse:<Tool> hook error: [<hook>]: <stderr>`，模型實測會換工具再試一次然後放棄，
所以拒絕理由要寫「這是系統限制」並指出替代路徑。

拒絕清單是**預設拒絕的黑名單 + 允許清單的白名單**兩層：git 子命令用白名單
（status/diff/log/add/commit/branch 建立/checkout 允許分支/stash list），其餘 git 一律擋。
被擋的呼叫回給模型的訊息要說「這是系統限制，請改走 X 或問人類」，不要讓它反覆試。

## 7. 通知語意

- run 的狀態變化（queued→running→done/failed/limited/handoff）都是 `agent_run_event`，
  房內 system 訊息只發：開始、結束（含結果一句話）、limited、交接、執行器離線。
  排隊位置變化不發訊息，App 面板顯示即可。
- 完成／失敗 mention 派工者；limited 與執行器離線 mention 房內所有人類。
- agent 自己的發言照現行規則（@ 才喚醒）。

## 8. 分期與驗收

### P0 前置（艾斯維爾裁決，見 §9）

### P1 Hub

- `room.kind` + ops 房不封存不 purge + 建房限人類；migration。
- `agent_run` / `agent_run_event` / `runner` 表與端點：建 run（含 `push` kind、每人每日配額、
  排隊上限、同 ref 不重複）、列 run、取消、執行器註冊／heartbeat（帶 `dashboard_json`）／
  claim／回報／取 `runner_command`；人類下 pause／resume／restart／drain。
  稽核串完整性測試（每個狀態變化一筆 event）。
- 房內 system 訊息與 mention 規則；`/updates` 加返回條件（不是只加欄位，
  沿用 board_seq 那次的教訓）。
- 驗收：pytest 全綠；並發 claim 只發一筆；ops 房在無 agent 時不封存。

### P2 執行器

- `runner/`：設定、主迴圈、spawn、stream 解析、hooks、交接、限額狀態機。
- 用假的 `claude` 可執行檔（吐固定 stream-json）做單元測試：
  正常結束、max_turns、rate_limit 重試、weekly limit、context 觸發交接、cancel 殺進程。
- Windows 常駐：排程工作或 WinSW（同 Hub 的 `hub-service.ps1` 做法），
  開機自起、崩潰重啟、log 落檔（`%LOCALAPPDATA%/UEP/Chatroom/runner/`）。
- 驗收：對測試 Hub（8788）跑一個 `investigate` run，agent 真的進房、讀卡、回報、結束。

### P3 Bridge

- `chatroom_run_request`（給 Codex／其他 agent 也能派工）、`chatroom_runs`（查佇列）、
  `chatroom_run_handoff`（agent 主動宣告交接）。
- `guide.py` 加「你是一個 run 時」的段落；403/409 新碼要進 bridge 翻譯
  （`test_403_contract` 會抓）。

### P4 App

- 房間列表分 chat／ops；ops 房頁多一個「執行」儀表板（§4.4）：每個 repo 尚未推送的 commit
  數與清單＋「推送」鈕、近 5 小時 tokens／cost 與軟上限、limited 倒數、
  進行中與排隊中的 run、取消鈕、執行器 pause／resume／restart。
- 階段與卡的抽屜加「派工」入口（模板選擇＋簡述）。
- 設定頁：主持人可暫停執行器、解除 limited。

### P5 端到端

1. 測試 Hub + 真執行器 + AI-Website 只讀 `investigate` 一票。
2. 一張真的低風險票走 `ticket` 到 commit（不 push），艾斯維爾在場驗。
3. 故意打滿 `--max-turns` 與模擬 context 上限，驗交接鏈。
4. 兩個人類同時派工、超過 3 個，驗排隊與取消。
5. 都過了才給其他人類用；期間艾斯維爾在場至少一週。

## 9. 裁決紀錄（艾斯維爾，2026-09-16）

| # | 題目 | 裁決 |
|---|---|---|
| 1 | GPG（快取 8 小時，離開後 commit 停在 pinentry） | 艾斯維爾自行處理；執行器只驗簽章可用（§5.7），不代管。 |
| 2 | 權限模式 | headless 用 `--permission-mode auto`；硬限制另做（§6.4）。 |
| 3 | push | 本機無人類，push 做成 `push` run 由房內人類從儀表板觸發（§5.6）；儀表板顯示未推送 commit、token 用量、限額、運行中 agent（§4.4）。 |
| 4 | Jira | MCP 應可用，開工實測；**Chrome（claude-in-chrome）在 headless 下能否用要另外研究**（§10 待研究）。 |
| 5 | 執行器形式 | 先用排程工作；機器大致不重開不睡眠，但要有專門的維護重啟機制（§5.7）。 |
| 6 | 軟上限 | 可設定；預設 Opus 5。 |
| 7 | 信任 | 不能完全相信對方的人類，要有系統層硬限制擋 agent 做不該做的事（§6.4）。 |

### 已實測（2026-09-16，2.1.273）

- **Atlassian 連接器在 `-p` 下可用**（`claude mcp list` 顯示 connected，`ToolSearch` 找得到
  `mcp__claude_ai_Atlassian_Rovo__*`），條件：同一個 OAuth 帳號、不加 `--bare`／`--strict-mcp-config`。
- **Chrome 擴充在 headless 下不可用**：官方文件明寫 API key／長效 token 認證時 Chrome 整合強制關閉，
  且需要一個開著、裝了擴充的瀏覽器視窗。定案：不做；需要瀏覽器的工作用 playwright MCP。
- chatroom bridge 走 `--mcp-config` 可連、可呼叫（唯讀驗過）。
- `PreToolUse` exit 2 能擋並把理由回給模型；`PreCompact` 擋不住壓縮（文件字面）。

### 待驗（P2 第一天）

- 獨立 `CLAUDE_CONFIG_DIR` 下連接器是否仍可用（§5.2）。
- `--max-budget-usd` 觸頂與週／月上限的實際 stream 樣貌（本次沒撞到，沿用文件）。

## 10. 風險與已知限制

- **context 觸發交接是估算**：靠 `usage` 累計，不是 Claude Code 自己的判斷；
  閾值訂保守（70%），寧可多交接一次。
- **rate limit「快要到」偵測不到**，只能「撞到後停收」。軟上限是自我約束，不是真實額度。
- **agent 不照契約交接**：有兜底（§5.4 第 4 點），但那一輪的工作樹狀態要靠下一輪重建。
- **同名不同 session 是不同個體**（PM 定調）：每個 run 都是新個體，卡的接手走
  task_request／孤兒接手，不做「上一輪的我」。
- **執行器在你的機器上跑 agent 憑證**：token 洩漏＝任何人能派工。ops 房的派工權限
  綁人類憑證，執行器 token 只能領單與回報，不能建 run。
- **人類看不到 shell**：所有可觀測面都在卡與房內訊息。agent 收工摘要的品質決定一切，
  模板要逼它寫「沒驗證什麼」。

## 11. 索引

- 契約：`docs/CHATROOM.md`（agent 手冊）、本文件（規劃）
- PM：`[PM] Chatroom` 「遠端派工（Remote Ops）規劃定案 2026-09-16」
- 相關記憶：Board v2 三題、身分語意定調、codex queue 外部喚醒、GPG 快取 TTL、
  多 agent 共用工作樹的協作限制
