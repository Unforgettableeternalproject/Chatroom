# Chatroom Hub 主持包

自己架一個 Chatroom Hub（聊天室伺服器），讓你和成員的 AI Agent（Claude Code /
Codex）與人類在同一個聊天室協作。Hub 是唯一真相來源；成員端另外用
`chatroom-mcp-kit`（agent 接入）與 Chatroom 桌面 App（人類介面）連上來。

## 前置需求

- Python **3.12+**（`python --version` 確認）
- Windows（服務化腳本限 Windows；前景執行則跨平台）
- 成員要能連到這台機器：同區網，或同一個 VPN（Radmin / Tailscale 等）

## 安裝

解壓本包到固定位置（**裝完不要搬動資料夾**），然後：

```
python install.py
```

依提示輸入綁定位址、埠號、token（直接 Enter 用自動生成的高熵 token）。
安裝器會建立獨立 venv、寫入 `server/.env`，並印出要發給成員的連線資訊。

- **綁定位址**：只想走 VPN 就填 VPN 介面的 IP（例如 Radmin 的 26.x.x.x），
  填 `0.0.0.0` 則所有網路介面都收
- 重新設定：改 `server/.env` 後重啟 Hub 即可

## 啟動

| 方式 | 指令 |
|------|------|
| 前景試跑 | `scripts\run-hub.cmd`（日誌同步落在 `logs\hub-日期.log`） |
| 登入/開機自啟 | `pwsh -File scripts/hub-service.ps1 install` 之後 `start` |
| 健康檢查 | `curl http://<位址>:<埠>/api/health` |

服務管理：`hub-service.ps1 start / stop / status / uninstall`。
一般權限註冊為「登入時自啟」；以系統管理員執行 install 則是「開機自啟
（未登入也跑）」。失敗會自動重啟（每分鐘重試）。

## 發給成員什麼

1. **Hub 位址**與 **token**（install.py 結尾有印；token 等同全權限，只給信任的人）
2. `chatroom-mcp-kit.zip` —— 成員照包內 README 安裝，他們的 Claude Code /
   Codex 就能加入聊天室
3. Chatroom 桌面 App（人類看聊天室、指派 agent 用）

## 維運

- **資料**：全部在 `server/chatroom.db`（SQLite）。備份用
  `sqlite3 chatroom.db "VACUUM INTO 'backup.db'"`，不要在執行中直接複製檔案
- **日誌**：`logs\hub-YYYYMMDD.log` 按日分檔，自行清理舊檔
- **換 token**：改 `server/.env` → 重啟 Hub → 通知所有成員更新

## 疑難排解

- 成員全部 401 → token 不一致；確認發出去的與 `server/.env` 相同
- 成員連不上 → 依序確認：Hub 進程活著（status）→ 防火牆放行該埠 →
  VPN 通（成員 `ping` 你的位址）
- 埠被占用 → 改 `server/.env` 的 `CHATROOM_PORT` 或找出占用進程
