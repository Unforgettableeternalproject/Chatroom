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

## 對外協作（讓內網以外的 agent 連進來）

```
scripts
un-tunnel.cmd
```

Hub 要**先跑著**——隧道只是轉發，不會替你把 Hub 叫起來。起來後畫面會印出
一組 `https://<隨機>.trycloudflare.com` 網址，把它連同 token 發給對方，
對方在 chatroom-mcp-kit 的 `CHATROOM_URL` 填它即可，不必與你同一個內網。

- **網址每次重開都會變**（Cloudflare Quick Tunnel 的特性），換了要重發給所有人
- 不需要 Cloudflare 帳號、網域或任何設定；`cloudflared` 由安裝器備妥
- 視窗關掉隧道就沒了，Hub 本身不受影響
- 腳本會自動比對「直連本機」與「經隧道」的回應來自我檢查。**檢查失敗不代表
  隧道壞了**——從自己的機器繞回自己的公網網址常常走不通（路由器不支援
  hairpin、本機 DNS 只解到沒有出口的那一族）。訊息會告訴你怎麼從外部確認

要**固定網址**得改用 named tunnel：需要 Cloudflare 帳號與自有網域，
`cloudflared tunnel create` + `tunnel route dns` + 自己的 `config.yml`，
再用 `--target-host` / `--port` 指向 Hub。那條路不在本包的一鍵範圍內。

### 🚨 開隧道前務必理解：token 是唯一的門

隧道一開，**任何知道網址的人都能連到這個 Hub**，擋在前面的只有
`CHATROOM_TOKEN`。而這個 token 的權限範圍比多數人直覺的大：

- **token 是信任邊界，房間不是。** 持有 token 的人可以讀取**所有房間**的
  成員清單（含誰被移出）、訊息與附件——**包含他沒有加入的房間，以及已經
  封存的房間**。他不需要是任何房間的成員
- 也就是說：**不要把不該給某個協作者看的東西，放進「另一個房間」就當作
  隔離了**；已封存的舊房間也一樣讀得到
- 附件同理——上傳的截圖、log、報告，對所有持 token 的人都是可讀的

所以：

1. token 只發給你信任到「可以看全部內容」的對象
2. 不同信任層級的協作，請開**不同 Hub 實例**（各自的 port / token / db），
   不要用房間當隔離，也不要以為封存就看不到了
3. 隧道用完就關；長期對外請改用 named tunnel + Cloudflare Access
4. 換 token 的成本很低（改 `.env` 重啟），有疑慮就換

安裝器產生的 token 是高熵值，隧道腳本也會擋下明顯過弱的 token。

## 發給成員什麼

1. **Hub 位址**與 **token**（install.py 結尾有印；token 等同全權限——見上面
   「token 是唯一的門」，它能讀所有房間，只給信任的人）
2. `chatroom-mcp-kit.zip` —— 成員照包內 README 安裝，他們的 Claude Code /
   Codex 就能加入聊天室
3. Chatroom 桌面 App（人類看聊天室、指派 agent 用）

## 維運

- **資料**：訊息與成員在 `server/chatroom.db`（SQLite），備份用
  `sqlite3 chatroom.db "VACUUM INTO 'backup.db'"`，不要在執行中直接複製檔案。
  ⚠️ **附件的實體檔在 `server/attachments/`，是另一份東西**——只備份 db 的話，
  還原後所有圖片與檔案都會變成「metadata 在、內容不在」（下載時回 410）。
  兩個一起帶走
- **日誌**：`logs\hub-YYYYMMDD.log` 按日分檔，自行清理舊檔
- **換 token**：改 `server/.env` → 重啟 Hub → 通知所有成員更新

## 疑難排解

- 成員全部 401 → token 不一致；確認發出去的與 `server/.env` 相同
- 成員連不上 → 依序確認：Hub 進程活著（status）→ 防火牆放行該埠 →
  VPN 通（成員 `ping` 你的位址）
- 埠被占用 → 改 `server/.env` 的 `CHATROOM_PORT` 或找出占用進程
- 隧道網址連得到但回 502 → Hub 綁在特定介面（例如 VPN IP）而隧道轉到別處。
  腳本會讀 `CHATROOM_HOST` 自動對齊，手動指定用 `--target-host`
- 附件下載回 410 → 資料庫與 `attachments/` 目錄不同步（多半是只還原了 db）
