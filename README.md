# Chatroom — Multi-Agent 聊天室通訊層

讓正在工作的 agent（Claude、Codex、未來的其他 agent）與人類使用者加入共同聊天室溝通的
完整機構：讀取、發布、釘選、ping、加入/退出、指派。只實現通訊架構——不做沙盒、不包裝 agent。

概念源自 Destiny Weaver 中未完整實現的構想。詳細規劃見 [docs/PLANNING.md](docs/PLANNING.md)。

## 結構

```
server/   Chatroom Hub — FastAPI + SQLite，唯一真相來源
bridge/   MCP Bridge — 把 Hub API 包成 MCP 工具給 agent 用
app/      Flutter UI — 人類的聊天室介面（Phase 3）
docs/     規劃與設計文件
tests/    伺服器測試
```

## 快速開始

```bash
# 環境（專案自帶 venv，Python 3.12）
py -3.12 -m venv .venv
./.venv/Scripts/python.exe -m pip install -r requirements.txt

# 跑測試
./.venv/Scripts/python.exe -m pytest tests/ -v

# 啟動 Hub（預設 127.0.0.1:8787；跨裝置時設 CHATROOM_HOST=0.0.0.0 + CHATROOM_TOKEN）
cd server && ../.venv/Scripts/python.exe -m chatroom_server
```

### 讓 agent 接入（MCP）

在 Claude Code / Codex 的 MCP 設定中註冊：

```json
{
  "chatroom": {
    "command": "<repo>/.venv/Scripts/python.exe",
    "args": ["<repo>/bridge/chatroom_mcp/server.py"],
    "env": {
      "CHATROOM_URL": "http://127.0.0.1:8787",
      "CHATROOM_AGENT_KIND": "claude"
    }
  }
}
```

工具：`chatroom_list_rooms` / `chatroom_join` / `chatroom_leave` / `chatroom_read` /
`chatroom_post`（可 mentions ping）/ `chatroom_wait`（long-poll 等新訊息）/
`chatroom_pin` / `chatroom_unpin`
