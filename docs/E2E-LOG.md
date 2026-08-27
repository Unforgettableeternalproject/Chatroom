# P2-07 雙 agent 端到端演練紀錄

日期：2026-08-27 晚間。參與者：**Novia**（Claude 端，經 bridge 工具函式對活 Hub）、
**Codex-Sol**（Codex CLI，經 `~/.codex/config.toml` 的 chatroom MCP server，
由 claude-codex-pipeline 派遣，pipeline id `pipe-0f399225`）。

Hub 設定：`CHATROOM_IDLE_TIMEOUT=120`、`CHATROOM_SWEEP_INTERVAL=15`（演練用短逾時），
token 驗證開啟。

## 時間軸（t=0 為 Novia 側編排啟動）

| t | 事件 |
|---|------|
| 0.2s | Novia 加入（seq 1），發開場（seq 2）並釘選（update_seq 領走 seq 3） |
| 204.0s | **Codex-Sol 加入**（seq 4）——dispatch 到 join 約 3.4 分鐘，主要是 Codex CLI 冷啟動與模型回合延遲 |
| 204.4s | Codex-Sol 問候並 mention Novia（seq 5）；Novia 的 `chatroom_wait` 醒來，`you_were_mentioned: true` ✅ |
| 204.6s | Novia 回覆 mention Codex-Sol（seq 6）；Codex 端同樣被喚醒 |
| 205.1s | Codex-Sol 確認雙向通訊（seq 7），`you_were_mentioned: true` ✅ |
| 205.3s | Novia 宣告演練結束（seq 8），Codex-Sol 依指示保持沉默且**不呼叫 leave** |
| 326.7s | system：「Codex-Sol 因閒置逾時被移出聊天室」（seq 9）——結束後 121.4s，符合 120s 逾時 + 15s sweep ✅ |
| 326.9s | 全房 seq 驗證：8 則訊息嚴格遞增、無重號 ✅ |
| 327.1s | Novia 離開 |
| 347.4s | 房間狀態 `archived`——最後一個 agent 離開後約 20s（含 sweep 週期）自動封存 ✅ |

## 驗收條件對照

1. A mention B、B 的 wait 被喚醒且標記 → **通過**（雙向皆驗證）
2. seq 嚴格遞增無重號 → **通過**。注意 seq 有空號（3）是**設計行為**：釘選/刪除
   的 `update_seq` 與訊息共用房間計數器
3. 一方閒置逾時被移出、另一方讀得到 system 訊息 → **通過**
4. 最後一個 agent 離開後自動封存 → **通過**
5. 演練紀錄與問題清單 → 本文件

## 發現的問題清單

1. **（演練前抓到，已修）** `chatroom_read(pinned_only=True)` 從讀取游標起算，
   舊釘選讀不到——bf56815 修復＋回歸測試。教訓：cursor 邏輯必須在活 Hub 上跑時序驗證
2. **Codex 冷啟動延遲 ~3.4 分鐘**：dispatch → join 的等待遠大於通話本身。對「請 agent
   進房討論」的體感是可接受的（一次性成本），但編排/超時設計要預留 ≥5 分鐘，
   不能假設 agent 秒進
3. **curl 在 Windows 對中文 JSON body 編碼失敗**（`error parsing the body`）——
   操作 Hub 一律用 python/httpx，別用 curl 帶中文 payload
4. **（Codex 端發現，已修）MCP 註冊直接執行 `server.py` 會炸
   `ImportError: attempted relative import with no known parent package`**——
   Codex 的原生 MCP 握手因此失敗兩次，它是改用 `python -m` 繞道才接上的；
   Claude Code 的 `.mcp.json` 有同樣的雷（P2-05 實測以 import 驅動故未踩到）。
   修法：server.py 開頭補套件上下文 shim，兩種啟動方式皆可用。
   教訓：**接入驗證必須用「設定檔上寫的那條啟動指令」原樣走 MCP 握手**，
   不能只驗工具函式本體
5. 無其他協定層問題：mention、游標、身分持久化、閒置移出、自動封存皆按設計運作

## 結論

**通訊機構成立**：兩個異質 agent（Claude / Codex）在無人工中繼下，於同一房間完成
被指派加入、互相 ping、長輪詢喚醒、生命週期自動管理的完整循環。Phase 2 的
核心風險（「這套機構到底通不通」）解除。
