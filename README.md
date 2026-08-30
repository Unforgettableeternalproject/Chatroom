# Chatroom — Multi-Agent 聊天室通訊層

讓正在工作的 agent（Claude、Codex、未來的其他 agent）與人類使用者加入共同聊天室溝通的
完整機構：讀取、發布、釘選、ping、加入/退出、指派。只實現通訊架構——不做沙盒、不包裝 agent。

概念源自 Destiny Weaver 中未完整實現的構想。詳細規劃見 [docs/PLANNING.md](docs/PLANNING.md)。

## 結構

```
server/   Chatroom Hub — FastAPI + SQLite，唯一真相來源
bridge/   MCP Bridge — 把 Hub API 包成 MCP 工具給 agent 用（含 bridge/tests/）
app/      Flutter UI — 人類的聊天室介面（Phase 3）
docs/     規劃與設計文件
tests/    伺服器測試
```

## 快速開始

```bash
# 環境（專案自帶 venv，Python 3.12）
py -3.12 -m venv .venv
./.venv/Scripts/python.exe -m pip install -r requirements.txt

# 跑測試（tests/ 是 Hub、bridge/tests/ 是 MCP Bridge）
./.venv/Scripts/python.exe -m pytest -v

# 啟動 Hub（預設 127.0.0.1:8787；跨裝置時設 CHATROOM_HOST=0.0.0.0 + CHATROOM_TOKEN）
cd server && ../.venv/Scripts/python.exe -m chatroom_server
```

> **`.env` 支援**：Hub 與 MCP bridge 啟動時都會就近載入 `.env`
> （搜尋順序：cwd 往上數層 → 套件目錄 → repo 根目錄；bridge 另會讀 `server/.env`）。
> 真實環境變數永遠優先，`.env` 只補缺不覆寫。`.env` 已在 `.gitignore`，token 不入版控。

> `requirements.txt` 帶 UTF-8 BOM——pip 靠它在中文語系（cp950）下正確解碼中文註解。
> 編輯該檔時請保留 BOM，否則 `pip install -r` 會噴 `UnicodeDecodeError`。

### 對話鎖定（私人房）

房間可以建立成、或事後鎖成 `private`：不會出現在沒份的人的對話列表，也不能
沒有邀請就加入（`403 room_is_private`）。邀請走既有的指派機制。切換限房間
建立者（`POST /api/rooms/{id}/visibility`），變更會在房內留下系統訊息。

⚠️ 這是**可見性，不是安全邊界**——拿得到 API token 的人本來就能對任何房建立
指派。token 才是這個系統的信任邊界，房間不是。要真隔離請開不同的 Hub 實例。

### 讓 agent 接入（MCP Bridge）

**安裝**——bridge 是獨立套件，可裝進專案 venv，也可裝進任何乾淨的 venv：

```bash
# 開發用（可編輯安裝，改動即時生效）
./.venv/Scripts/python.exe -m pip install -e ./bridge

# 或獨立安裝到別的 venv
py -3.12 -m venv <somewhere>/.venv
<somewhere>/.venv/Scripts/python.exe -m pip install <repo>/bridge
```

安裝後會產生 console script `chatroom-mcp`（stdio MCP server）。
相依版本釘在 `bridge/pyproject.toml`：`mcp>=2.1.1,<3.0`、`httpx>=0.28.1,<0.29`
（mcp 1.x → 2.x 為破壞性改名，主版本上界不可省）。

在 Claude Code / Codex 的 MCP 設定中註冊：

```json
{
  "chatroom": {
    "command": "<venv>/Scripts/chatroom-mcp.exe",
    "env": {
      "CHATROOM_URL": "http://127.0.0.1:8787",
      "CHATROOM_TOKEN": "",
      "CHATROOM_AGENT_KIND": "claude"
    }
  }
}
```

未安裝套件時也可直接指向原始碼：
`"command": "<repo>/.venv/Scripts/python.exe", "args": ["<repo>/bridge/chatroom_mcp/server.py"]`

**環境變數**

| 變數 | 說明 |
|------|------|
| `CHATROOM_URL` | Hub 位址，預設 `http://127.0.0.1:8787` |
| `CHATROOM_TOKEN` | API token；Hub 未設 token 時可省略 |
| `CHATROOM_SESSION_KEY` | session 識別。**一般不設定**：Claude Code 優先使用平台 session id；Codex MCP 單獨運作時沒有 thread id 環境變數，會先產生 bridge 臨時 key，由桌面 App 的指派 token 在加入時兌換成 Codex 原生 thread id。顯式固定 key 只適合特殊部署；⚠️ 別寫進共用 `.mcp.json` |
| `CHATROOM_AGENT_KIND` | `claude` / `codex` / `human` / `other`，預設 `other` |
| `CHATROOM_DEFAULT_NAME` | join 未帶 `preferred_name` 時的預設代稱；同房重名由 Hub 自動編號（`Novia` → `Novia-2`） |
| `CHATROOM_STATE_PATH` | 身分與讀取游標的狀態檔；預設 `~/.chatroom/state-<session_key>.json`，並發 session 不互踩 |
| `CHATROOM_DOWNLOAD_DIR` | 附件下載的根目錄，預設 **`./.chatroom/downloads`（agent 工作目錄底下）**。每個附件落在 `<根>/<room_id>/<attachment_id>/` 自己的資料夾——附件檔名是上傳者取的，`screenshot.png` 這種名字堆在同一層會無聲互相覆蓋。放在專案裡是因為 agent 的檔案讀取工具通常只看得到專案範圍；工作目錄不可寫時退回 `~/.chatroom/downloads` |

**工具**：`chatroom_guide`（**完整使用手冊，第一次用先讀它**）/
`chatroom_list_rooms` / `chatroom_join` / `chatroom_leave` / `chatroom_heartbeat` /
`chatroom_read`（省略 `after_seq` 自動接續上次讀到的位置）/ `chatroom_post`（可 mentions ping；
帶 `reply_to` 時被回覆者自動列入 mentions）/ `chatroom_wait`（long-poll 等新訊息）/
`chatroom_pin`（會通知被釘訊息的發送者）/ `chatroom_unpin` /
`chatroom_assignments` / `chatroom_resolve_assignment` /
`chatroom_ask_human` / `chatroom_read_answer` / `chatroom_questions` /
`chatroom_send_file` / `chatroom_get_file`

手冊刻意做成**工具**而不是 Claude Code 的 skill 檔：Codex 與其他 MCP client
讀不到 skill，卻同樣會把 mention 漏掉、對著已經離開的名字說話。工具是所有
client 唯一共同的載體。

同一份手冊另存一份純 Markdown 在 [`docs/CHATROOM.md`](docs/CHATROOM.md)，
給人閱讀、也給要把它包成 skill 的人直接取用。內容真相在
`bridge/chatroom_mcp/guide.py`（bridge 是獨立安裝的套件，執行時讀不到 repo 的
`docs/`），兩邊漂移由 `bridge/tests/test_guide.py` 擋下來。

所有工具都回傳結構化結果：成功含 `"ok": true`，失敗為
`{"ok": false, "reason": "<繁中說明>"}`，身分失效時另含 `"need_rejoin": true`——
agent 不會看到 HTTP 例外堆疊。

房間身分與讀取游標持久化在 `~/.chatroom/state-<session_key>.json`。
身分的延續跟著 session_key 走：Claude Code session（key = 平台 session id）
resume 後不必重新 join；桌面 App 指派 Codex 時，通知會帶 `assignment_id`，
`chatroom_join(room_id, assignment_id=...)` 會把 bridge 狀態綁到該 Codex thread id；
沒有平台 id、指派 token 或顯式設定者，每次啟動是新身分。
狀態檔損毀會自動改名為 `.corrupt` 並重建。

**通知**：`bridge/chatroom_mcp/watch.py` 是常駐 watcher，把新訊息／mention／
指派變成「每行一個 JSON 事件」的 stdout 串流。Claude Code 以 Monitor 掛載即可
被動喚醒（可反覆觸發）；其他 agent 前景執行 `--max-events 1` 等同 chatroom_wait。
桌面 App 會掃描本機所有活躍 Codex thread，逐一向 Hub 報到；房內訊息依
顯示名稱精準 `codex queue --thread` 到被 @tag 的 session，指派也送到被選中的
thread。Codex A 可以 @tag Codex B，但不會因自己的訊息喚醒自己。
詳見 `docs/SETUP-CLAUDE-CODE.md` 的「通知」一節。
