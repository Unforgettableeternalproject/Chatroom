# Chatroom v1.2.4

遠端派工（Remote Ops）版。新增工作房、執行器與派工流程，App 可安裝三種 kit
並切換語言。資料庫自動遷移至 DATA_VERSION 6，執行器設定檔需要注意鍵名改動。

---

## 遠端派工

- 工作房要先由房主**綁定一個工作區**（一次性、不可更改）才能派工：綁定前執行頁是空的、
  階段沒有派工鈕；綁定後只列服務該工作區的執行器，派工的 project 鎖定為綁定值。
- 私人工作區（`public: false`）只能綁到私人房間；公開工作區公開／私人房都可以。
- 新增「工作房」（`kind=ops`）：常駐房間，不自動封存也不 purge，用來派工與看結果。
  建房對話框可選，房間列表掛 ops 徽章。
- 新增「執行器」（runner）：註冊到 Hub 的本機常駐程序，領走派工並在本機 repo 上
  跑 Claude Code。四種派工模板（含唯讀的 investigate）與 push 專用流程。
- 派工有硬限制：每日配額 20、佇列上限 5、交接鏈上限 5、執行器逾 180 秒未心跳判離線。
- context 快滿時自動交接給下一棒子 run，交接摘要會傳給下一輪，不必從頭讀卡。
- 派工可「軟停止」：請執行器收尾，逾 300 秒才硬取消。@ 提及會在下一次工具呼叫前
  送進正在跑的 run。
- 任務板 Supervisor 的 agent 可以自己派工（push 模板除外），配額算在指定它的人類頭上。
  Supervisor 離場而仍有排隊的 run 時，Hub 會提醒人類，不自動取消。

## Hub

- 私人工作房派出去的 run 進得了房：`claude-run-<id>` 對得上本房進行中的 run 就不受私人房限制。
- 隨機代稱依 `CHATROOM_LOCALE` 選名字池：每個語言一組形容詞／名詞／預製名單，
  兩種都有時各半抽；zh 系走中文池，其餘走英文池。
- 板讀取加 `checklist_id`：只回那一個階段、其卡片與所屬週期一列，增量也只回該階段。
- 新增 `room.kind` 與 `agent_run`／`agent_run_event`／`runner`／`runner_command`
  四張表，以及記錄執行器掉線／恢復的 `runner_event`。存量房間一律 `chat`。
- 執行器註冊時發 `runner_token`（DB 只存 hash，明文只回一次），之後的心跳、領單、
  回報都要帶；別人拿同一個 id 重註冊接管不了。
- 派工成員在 run 收場時自動離房，不會累積在成員列上；還在跑的成員顯示「派工中」、
  不倒數、不被閒置掃描帶走。
- 訊息新增 `sender_kind` 快照：run 成員離房後，歷史訊息的身分不再退回 other。
- 新增 `GET /api/ops/exceptions`：跨房彙總停滯、恢復、逾時、額度受限與執行器掉線。
- 階段素材：checklist 可掛共享附件，備註可編輯；掛接與卸除都會推進 `board_seq`，
  增量讀板看得到。
- 非預期掉線的通知同一台 30 分鐘只發一則；`restarting` 的離線不再喊「失去連線」。
- 交接過的卡在子 run 收場後可以再派工（原本一張卡交接過一次就永遠派不了）。
- Supervisor 回房時 `left_at` 寫成空字串導致資格看似恢復實則 403 的舊缺陷已修，
  DATA_VERSION 6 會把存量空字串收成 NULL。
- 隨機代稱依 `CHATROOM_LOCALE` 選名字池：zh 系抽中文預製名單，其餘抽 Adjective-Noun。
- system 訊息與錯誤訊息全面精簡，只講結論與下一步；派工完成的系統訊息不再附
  收工摘要，全文留在回報面板。

## bridge

- `chatroom_board` 加 `checklist_id`，派工 agent 找一個階段的卡不必拉全量板。
- `chatroom_ask_human` 被略過時，run 身分的說明改為「由你自行判斷並繼續」，
  不再叫它回到不存在的「原本的對話」。
- 新增五支派工工具：`chatroom_runs`、`chatroom_run`、`chatroom_run_request`、
  `chatroom_run_handoff`、`chatroom_run_cancel`。`run_request` 與 `run_cancel`
  只認人類憑證，說明裡明講 agent 會被 403 拒絕。
- 新增 `chatroom_stage_files`、`chatroom_stage_file_add`、`chatroom_stage_file_note`
  三支階段素材工具。
- 補上遠端派工的錯誤碼翻譯與 429 配額分支，配額超過不再被當成「未預期狀態」而重試。

## 執行器（runner）

- 契約開頭加最強規則：開工第一步 `chatroom_join`，失敗或工具不在就不讀檔、不跑命令，
  只輸出收尾說明後結束。mcp 重試前的回報不再撞 409。
- 設定全部來自 JSON（`%LOCALAPPDATA%` 或 `CHATROOM_RUNNER_CONFIG`），分支與專案
  都是白名單，空清單等於什麼都不允許。
- 設定改「工作區／專案」兩層：頂層 `workspaces`，其下 `projects`，可指定
  `primary_skill` 在開工時優先載入。一次派工可以動同一個工作區下所有 repo。
- PreToolUse 硬限制：git 子命令白名單加預設拒絕黑名單，殼層與直譯器包裝
  （`cmd /c`、`powershell -Command`、`python -c` 等）一律擋，寫入限制在專案範圍內。
- 預先用 `--allowedTools` 授權工具，headless 不再卡在權限提示而整筆 run 空轉。
- run 預設只載入 chatroom MCP，帳號層級的 claude.ai 連接器被 `deniedMcpServers`
  擋掉；要放行其他伺服器用 `allowed_mcp_servers`。
- 派工開始前先 fetch 並 ff-only 同步工作樹；無法快轉時直接 `failed`，不起 agent。
- 啟動時對帳：本機沒有進程而 Hub 上還在跑的 run 收成 `failed(runner_restarted)`，
  不再永遠掛在 running。
- stream 行上限放大到 64MiB，讀到大附件不再讓整個執行任務死掉；附件落在
  run 目錄的 `downloads`，不弄髒被派工的工作樹。
- 自檢的 gpg 改跟 git 同源解析（`gpg_bin` → `git config gpg.program` → PATH）。
- 排程工作改用 `pythonw.exe` 起，子進程不開視窗，安裝時把 runner 路徑寫進 `.pth`，
  不再每分鐘閃一個 cmd 視窗。
- hook 輸出強制 UTF-8，注入訊息與收尾提示在 CP950 主控台下不再是亂碼。
- 維護窗一天只跑一次，不再在 04:00–05:00 每 5 分鐘重啟一次。
- 預設值調整：context 視窗 1M、token 軟上限關閉（只留成本上限）、
  `max_turns` 不設上限。
- `allowed_mcp_servers` 真正生效：探測收全部 MCP 伺服器（含本機 stdio），
  不在清單的一律 deny；勾選的全域 `~/.claude.json` 伺服器定義併進 run 的 `mcp.json`。
- 啟動自檢加 Claude 登入檢查（`claude auth status`），未登入在自檢就擋下，
  不再到第一筆真單才炸。

## kit 與安裝

- 三包各附雙擊即可的 `install.bat`：自動找 Python 3.12+，太舊或沒有分開提示；
  `install.py` 互動模式改為逐步安裝，問題帶預設值、答錯重問、收尾印下一步。
- runner-kit 安裝器開頭印免責聲明：目前只支援 Claude Code，MCP 也限 Claude Code
  設定裡有的。互動安裝完成後可直接在執行器設定目錄登入；`--yes` 回
  `login_required` 與 `login_hint`。
- 從 App 安裝 kit 前可選安裝路徑，不合法路徑在下載前擋下。
- 新增 `runner-kit`：打包 runner 與 bridge、建 venv、註冊排程工作、寫
  `~/.chatroom/runner-kit.json`，支援 `--uninstall`。GitHub Release 一併附上。
- host-kit／install-kit／runner-kit 的 `install.py` 全部支援非互動安裝：`--yes`
  路徑不會停下來問、失敗走 stderr 並 exit 1、最後印一行 `RESULT {json}`。
- App 可直接從 GitHub Release 下載並安裝三種 kit，不必自己抓壓縮檔。
- 安裝器會偵測 Python 3.12，缺的話給下載連結。
- 既有的 `config.json` 與設定檔重跑安裝器不會被覆寫。

## App

- 派工異常改成右側面板；點一筆就地展開全部欄位與該 run 的最後回報，「前往聊天室」是次要按鈕。
- 回報卡標題顯示做這筆 run 的 agent 名稱；沒進房前顯示 kind 與 ref 短碼。
- 三個 kit 分頁安裝前顯示前置條件（Python／Claude Code 或 Codex／Hub 可連），
  不通過就擋安裝；執行器分頁顯示登入狀態與登入指令。找 Python 改判 3.12 以上。
- 任務卡詳情內文改 markdown 渲染。
- 執行器工作區「進階」欄位沿用 Hub 設定的欄位樣式；回合上限提示改「留空＝不設上限」。
- Hub 設定加「隨機代稱語言」；執行器分頁加 MCP 允許清單，來源合併 claude.ai
  連接器與全域 `.claude.json`，逐列標來源。
- 派工 agent 的提問卡略過鍵改為「不回答，讓它自己決定」。
- 沒裝的 kit 分頁說明帶包名；沒有 Release 時指出對應的 `build.py`。
- 全面 i18n：1242 個鍵、繁體中文／English／簡體中文三份 ARB，設定頁可選
  跟隨系統或指定語言。
- 新增「這台機器」頁，依已裝的 kit 分 Hub 主持／Agent 接入／執行器三個分頁；
  沒有 kit 登錄檔時退回本機來源偵測（環境變數、執行器 config、repo 相對位置、排程工作）。
- 「這台機器」可直接編輯 Hub 與 MCP 的 `.env`（只覆寫指定 key，保留註解與順序），
  Hub 存檔後可直接重啟。位址、埠號與兩把 token 唯讀，換 token 走專門入口。
- 執行器分頁以工作區／專案卡片樹狀呈現，可新增或移除工作區與專案、設預設專案、
  指定 skill 目錄與優先載入的 skill，存檔後發 reload 不打斷進行中的 run。
- 工作房新增執行儀表板：執行器狀態、pause／resume／restart／drain、每個 repo 的
  未推送清單與推送鈕、近 5 小時用量、佇列與取消、最近結束的幾筆。
- 階段與卡片各有派工入口；專案清單每次現撈，送出鍵一律可按，擋下來的理由當場寫出來。
- 新增派工異常頁（`/ops/exceptions`），頂欄入口帶未讀水位；執行器掉線與逾時會推通知。
- 回報面板改在訊息區左側開啟，成員清單與回報區各自可捲，回報一頁 20 筆可再載入。
- 任務卡詳情與收工摘要改 markdown 渲染，連結可點、跟隨主題深淺色。
- 說明頁分成主頁／設定／這台機器三份重做，功能旁不再放長篇介紹。
- 字級改五檔（極小到特大），設定頁分連線／視覺／個人化三個 tab，標題樣式統一。
- 版本橫幅同時印 App 與 Hub 的 commit。
- 修正：派工第一次按下去沒反應、建房對話框的房間類型排版炸掉、卸除素材取消後畫面
  變灰、多檔匯入只取第一個檔案。

## 文件與手冊

- 新增 `docs/REMOTE-OPS-PLAN.md` 規劃書與首輪實機驗收紀錄。
- guide 新增 §9.8「你是一個 run 時」：開場三件事、契約、PreToolUse 擋下來不要換
  工具再試、context 滿了用 `run_handoff`、工具是 deferred 要先 ToolSearch。
- guide §9.7／9.8 補 Supervisor 自派工；`docs/CHATROOM.md` 同步。
- 執行器 README 補安裝、獨立 `CLAUDE_CONFIG_DIR` 首次登入、設定欄位、log 位置、
  hook 的黑白名單與退出碼。

## 其他

- `.gitignore` 忽略所有 `.env*` 變體；Flutter 產生檔不再追蹤並固定 LF。

---

## 升級注意事項

- 既有工作房升級後 `workspace_key` 為空，要由房主在執行頁綁定一次才能繼續派工。
- 執行器要更新到本版才會上報私人工作區；舊執行器只有公開工作區可被派工。
- **資料庫自動遷移到 DATA_VERSION 6。** 新增五張表與 `room.kind`、`participant.run_id`、
  `message.sender_kind` 等欄位，存量房間一律視為 `chat`。升級前請自行備份資料庫。
- **新增環境變數 `CHATROOM_LOCALE`（預設 `zh-TW`）。** 決定隨機代稱抽哪個名字池；
  不設定即維持中文預製名單。可在 App 的「這台機器 → Hub 設定」改。
- **執行器 `max_turns` 預設改為不設上限**（`0` ＝ 不傳 `--max-turns`）。輪數不是有效的
  硬限制，真正的界線是 context。要沿用舊行為就在設定檔填一個大於 0 的值。
- **執行器設定檔鍵名改動：** 頂層 `projects` → `workspaces`、`repos` → `projects`、
  `default_repo` → `default_project`。舊鍵相容一版，新舊並存時以新鍵為準並發警告，
  請盡早改過來。每個專案必須是 git repo，不是的會被排除並列入自檢。
- **既有的 runner-kit 安裝可以直接重跑 `install.py`：** `config.json` 已存在就原樣保留，
  不會被覆寫。
- **`config.example.json` 改為佔位路徑與機器名**（`C:/path/to/…`、`this-machine`／
  `runner-1`），`state_dir` 與 `claude_config_dir` 移除交給預設值。直接複製範例的人
  要自己填成本機實際路徑。
- **已安裝的執行器排程工作要重跑 `install-task.ps1`。** 新版會把 `runner/` 寫進直譯器
  的 `chatroom_runner.pth` 並改用 `pythonw.exe`；不重跑的話仍會是啟動失敗加不斷重試。
- **執行器預設只允許 chatroom MCP。** 需要其他 MCP 伺服器的專案要在 config 的
  `allowed_mcp_servers` 補上，否則 run 起來看不到那些工具。
- **執行器預設值變更：** context 視窗 1M（`CHATROOM_RUNNER_CONTEXT_WINDOW_TOKENS`
  可覆寫）、token 軟上限關閉只留成本上限。自行調過這兩項的設定檔不受影響。
- **只有裝了 runner-kit 的機器才能建「工作房」**，加入別人的工作房不受影響。
- App 已改為多語言；第一次啟動會跟隨系統語言，要固定語言請在設定頁的視覺分頁選。

## 驗證

- Python：2047 passed / 1 xfailed
- Flutter：1242 passed，`flutter analyze` 無問題
- 三端版本一致（Hub／bridge／App 皆 1.2.4）
