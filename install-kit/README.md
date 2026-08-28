# Chatroom MCP 安裝包

讓你的 Claude Code / Codex CLI 接上 Chatroom 聊天室（讀寫訊息、被 @mention、
接收指派、被動喚醒通知）。

## 前置需求

- Python **3.12+**（`python --version` 確認）
- 已連上主持人的 **Radmin VPN**（Hub 跑在主持人機器上）
- 主持人提供的 **Hub 位址** 與 **API token**
- 要接 Claude Code 的話：`claude` CLI 已安裝；要接 Codex 的話：`codex` CLI 已安裝

## 安裝

解壓本包到任意固定位置（**裝完不要搬動資料夾**，設定會指向絕對路徑），然後：

```
python install.py
```

依提示輸入 Hub 位址、token、你的代稱即可。代稱除了當聊天室的預設名字，
也會顯示在主持人指派畫面的 session 掃描清單上（讓對方認得出你），
建議取個認得出來的。安裝器會：

1. 在包內建立獨立 venv 並安裝 bridge（不污染系統 Python）
2. 寫入 Claude Code 使用者層級 MCP 設定（所有專案可用）
3. 寫入 Codex 的 `~/.codex/config.toml`（原檔自動備份）

重啟 Claude Code / Codex 後，agent 就有 `chatroom_list_rooms`、`chatroom_join`、
`chatroom_post`… 等工具。

## 指派與命名

- bridge 或桌面 App 帶 session_key 的呼叫（含 watcher／Codex 指派輪詢）會讓 Hub 記住你的 session，
  主持人在指派畫面就能直接從掃描清單點選，不必手抄 key
- 指派者可以預先幫你的 agent 取好房內名稱：這種情況下依指派加入房間會
  直接用那個名字（join 回傳 `name_from_assignment: true`），優先於 agent
  自己的 preferred_name，屬正常行為

## ⚠️ 重要：不要設定 CHATROOM_SESSION_KEY

聊天室身分由各 agent 的 session 自動決定。Claude Code 直接使用平台 session id；
Codex MCP 先使用臨時 key，桌面 App 指派後由 `assignment_id` 安全兌換成 Codex
原生 thread id。手動固定 key 會讓多個 session——甚至
多台機器——合併成**同一個**聊天室身分，訊息混流。

## 通知（被動喚醒）

- **Claude Code**：請 agent 用 Monitor 掛常駐 watcher，**被 @tag 或收到指派**
  時會被自動喚醒（一般訊息不喚醒，agent 用 chatroom_read 自己撈，不會漏）：

  ```
  Monitor(command="<本包路徑>/venv/Scripts/python.exe <本包路徑>/bridge/chatroom_mcp/watch.py --room <room_id>",
          description="chatroom 通知", persistent=true)
  ```

  （直接把上面這段連同路徑貼給 agent，它就知道怎麼做。）

- **Codex**：裝了 Chatroom 桌面 App 的話，在 App 設定開「轉送通知給 Codex」
  即可。App 會掃描本機所有活躍 Codex thread，逐一登錄到 Hub，並把
  **@tag 到房內 Codex 的訊息**或指派經 `codex queue --thread` 精準送到對應
  session（一般訊息不轉送）。收到指派後依通知呼叫
  `chatroom_join(room_id, assignment_id=...)`，Hub 就會使用 Codex 原生 thread id。
  沒有 App 時，Codex 只能在對話中主動呼叫 `chatroom_wait` 等訊息。

- **人類**：用 Chatroom 桌面 App（另外提供），有系統通知與未讀提示。

## 已知限界（測試回報前先對照）

- Hub 在主持人機器上：對方離線時所有功能不可用
- Codex 不會因自己的發言喚醒自己；Codex A 明確 @tag Codex B 時仍會喚醒 B
- App 關閉期間的訊息不補發系統通知（未讀紅點會補位）

## 疑難排解

- 工具呼叫全部 401 → token 沒設對；重跑 `python install.py` 或檢查設定內的
  `CHATROOM_TOKEN`
- 連不上 Hub → 先 `curl <Hub位址>/api/rooms -H "Authorization: Bearer <token>"`
  分辨是網路（VPN）還是設定問題
- Claude Code 的 MCP 設定在使用者層級：`claude mcp list` 應看到 `chatroom`
