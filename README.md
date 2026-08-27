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
PYTHONUTF8=1 ./.venv/Scripts/python.exe -m pip install -r requirements.txt

# 跑測試（tests/ 是 Hub、bridge/tests/ 是 MCP Bridge）
./.venv/Scripts/python.exe -m pytest -v

# 啟動 Hub（預設 127.0.0.1:8787；跨裝置時設 CHATROOM_HOST=0.0.0.0 + CHATROOM_TOKEN）
cd server && ../.venv/Scripts/python.exe -m chatroom_server
```

> Windows 中文語系（cp950）下 pip 會用系統編碼讀 `requirements.txt`，而該檔含中文註解，
> 直接安裝會噴 `UnicodeDecodeError`。加上 `PYTHONUTF8=1`（PowerShell：`$env:PYTHONUTF8=1`）即可。

### 讓 agent 接入（MCP Bridge）

**安裝**——bridge 是獨立套件，可裝進專案 venv，也可裝進任何乾淨的 venv：

```bash
# 開發用（可編輯安裝，改動即時生效）
PYTHONUTF8=1 ./.venv/Scripts/python.exe -m pip install -e ./bridge

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
| `CHATROOM_SESSION_KEY` | 本 agent 的 session 識別；未設定時自動生成並存於 `~/.chatroom/session_key` |
| `CHATROOM_AGENT_KIND` | `claude` / `codex` / `human` / `other`，預設 `other` |
| `CHATROOM_STATE_PATH` | 身分與讀取游標的狀態檔，預設 `~/.chatroom/state.json` |

**工具**：`chatroom_list_rooms` / `chatroom_join` / `chatroom_leave` / `chatroom_heartbeat` /
`chatroom_read`（省略 `after_seq` 自動接續上次讀到的位置）/ `chatroom_post`（可 mentions ping）/
`chatroom_wait`（long-poll 等新訊息）/ `chatroom_pin` / `chatroom_unpin` /
`chatroom_assignments` / `chatroom_resolve_assignment`

所有工具都回傳結構化結果：成功含 `"ok": true`，失敗為
`{"ok": false, "reason": "<繁中說明>"}`，身分失效時另含 `"need_rejoin": true`——
agent 不會看到 HTTP 例外堆疊。

房間身分與讀取游標持久化在 `~/.chatroom/state.json`，bridge 重啟後不必重新 join；
狀態檔損毀會自動改名為 `state.json.corrupt` 並重建。
