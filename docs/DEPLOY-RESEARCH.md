# Chatroom Phase 4 部署選型研究

> 研究日期：2026-08-27
> 範圍：P4-03（Windows 常駐）、P4-04（外網通道）、P4-05（SQLite 備份）的選型結論，
> 供 P4-03 / P4-04 / P4-05 直接照結論施工。
> 本文件為**純研究**，未安裝任何軟體、未變更任何系統設定、未啟動任何服務。

## 0. 部署前提摘要

| 項目 | 內容 |
|------|------|
| Hub | Python 3.12 + FastAPI + uvicorn（`server/`，專案自帶 `.venv`） |
| 主機 | Windows 11 桌機，長期開機 |
| 資料 | SQLite 單檔 `chatroom.db`，WAL 模式 |
| 驗證 | 單一共享 `API_TOKEN`（Bearer）；WS 走 `/ws?token=` |
| 必須穿透 | ① WebSocket 長連線穩定 ≥ 30 分鐘 ② `GET /api/rooms/{id}/updates?timeout=25` 的 25 秒 long-poll 掛起 |

**這兩個「必須穿透」是本次選型的唯一硬條件**，其餘（成本、便利性）都是次要權衡。

---

## 1. Windows 常駐方案比較（P4-03）

### 1.1 候選比較表

| 方案 | 註冊為原生服務 | 進程崩潰自動重啟 | 開機自啟 | Log 落檔與輪替 | 設定可版控 | 移除難易 | 維護狀態 |
|------|------|------|------|------|------|------|------|
| **工作排程器**（Task Scheduler） | ✗（只是排程觸發的進程） | 弱：`RestartOnFailure` 只對「任務失敗」生效，需搭配輪詢式健康檢查才可靠 | ✓（At startup 觸發器） | ✗ 完全自理（要自己重導 stdout/stderr、自己輪替） | 部分（可匯出 XML，但欄位冗長難讀） | 易（刪任務） | 系統內建，恆定 |
| **NSSM** | ✓（Service Control Manager 認得） | ✓ 強（內建 restart throttle、exit-code 動作對應） | ✓ | ✓ 內建 stdout/stderr 重導 + 依大小輪替 | ✗ 設定存在 Registry，要靠 `nssm dump` 才能導出 | 易（`nssm remove <svc> confirm`） | ⚠ 最後穩定版 2017（2.24），長期未更新但廣泛使用中 |
| **WinSW** | ✓ | ✓ 強（`onfailure` 可設 restart/reboot/none，含 `resetfailure` 與延遲） | ✓（含 delayed-auto-start） | ✓ 內建多種 log mode：`roll-by-size` / `roll-by-time` / `roll-by-size-time` | ✓✓ **設定就是一個 XML/YAML 檔，可直接進 git** | 易（`winsw uninstall`，單一 exe + xml，刪目錄即淨） | 維護中（2.x 穩定線，v3 開發中） |
| **Shawl** | ✓（Rust 單一 binary，包裝任意 exe 成服務） | ✓（依賴 SCM recovery 設定 + 自身 restart 策略） | ✓ | ⚠ 較陽春（需自行搭配重導） | ✓（純 CLI 參數） | 易 | 維護中、活躍 |
| **直接寫 pywin32 服務** | ✓ | 自理 | ✓ | 自理 | ✓ | 中 | — |

### 1.2 推薦：**WinSW**

理由，按重要性排序：

1. **設定即程式碼**。WinSW 的整份服務定義（執行檔路徑、工作目錄、環境變數、log 策略、失敗動作）就是一個 `chatroom-hub.xml`，可以直接放進 `deploy/` 目錄版控。NSSM 把設定塞在 Registry，是本專案（「所有設定必須版本控制」）最不能接受的一點。
2. **log 輪替是內建的**，直接滿足 P4-03 驗收條件 3（「log 落在固定路徑且有輪替或大小上限」），不需要另外寫輪替腳本。
3. **原生 Windows 服務**，由 SCM 監管進程存活。工作排程器不是進程監管器 —— 它的重啟語意是「任務動作失敗時重試」，對付「uvicorn 進程被 kill 掉」需要額外的輪詢腳本，會變成「服務 + 腳本」兩個要維護的東西，直接違反驗收條件 2（手動 kill 後能自動重啟）。
4. **移除乾淨**：`winsw.exe uninstall` 後只剩一個目錄可刪，滿足驗收條件 4。
5. NSSM 雖然功能夠用且極輕，但最後一版停在 2017，加上 Registry 設定不可版控，作為新專案起手不建議。

> 若之後嫌 XML 囉唆，Shawl 是可接受的替代（純 CLI、winget 可裝），但 log 要自己接，會失去上面第 2 點。

### 1.3 施工要點（給 P4-03）

- 服務直接跑 `.venv\Scripts\python.exe -m uvicorn ...`，**不要**經由 `.bat` 包一層 —— 多一層 shell 會讓 SCM 看到的是 cmd 的存活而非 uvicorn 的存活，kill uvicorn 時不會觸發重啟。
- `<onfailure action="restart" delay="10 sec"/>` 搭配 `<resetfailure>1 hour</resetfailure>`，避免啟動失敗時無限快速重啟燒 CPU。
- Log 用 `roll-by-size-time`，設每日 + 單檔上限（例 10 MB）、保留 14 份。
- `API_TOKEN` 走服務層的 `<env>` 或指向 `.env` 檔，**不要**寫進版控的 XML 裡；XML 只放 `.env` 的路徑。
- 服務帳號：用登入使用者帳號（需 "Log on as a service" 權限）或 `LocalSystem`。注意 `LocalSystem` 的使用者目錄不同，`chatroom.db` 的路徑務必用絕對路徑。
- 提供 `deploy/service-install.ps1` / `service-uninstall.ps1`，狀態查詢用 `Get-Service chatroom-hub` 與 `sc.exe query`。

**來源**：[WinSW（GitHub）](https://github.com/winsw/winsw)、[RestartOnFailure（Task Scheduler schema）](https://learn.microsoft.com/en-us/windows/win32/taskschd/taskschedulerschema-restartonfailure-settingstype-element)、[Service vs scheduled task（Microsoft Learn 討論）](https://learn.microsoft.com/en-us/archive/msdn-technet-forums/4bcc4c79-ce03-415a-8942-2f129c63441a)、[Servy vs. NSSM vs. WinSW 比較](https://dev.to/aelassas/servy-vs-nssm-vs-winsw-2k46)

---

## 2. 外網通道比較（P4-04）

### 2.1 三個候選

| | **A. Tailscale（純 tailnet 直連）** | **B. Cloudflare Tunnel（named tunnel）** | **C. Tailscale Serve / Funnel** |
|---|---|---|---|
| 架構 | 裝置間 WireGuard 點對點，Hub 綁 `100.x.y.z:8000`，**中間沒有任何 L7 代理** | `cloudflared` 出站連 Cloudflare 邊緣，公網 HTTPS 反向代理回 Hub | Tailscale 內建的 HTTPS 反向代理（Funnel 再對公網開放） |
| WebSocket | ✓ 原生，**無中間層 idle timeout** | ✓ 支援全方案，但**邊緣有 idle timeout（Free/Pro 約 100 秒無流量即關閉）** | ⚠ 已知每 10–40 秒被關閉（close code 1001） |
| 25 秒 long-poll | ✓ 完全不受影響 | ✓ 安全：Cloudflare 對源站的 Proxy Read Timeout 為 125 秒、524 門檻 100 秒，25 秒遠低於門檻 | ✓（但 WS 問題已否決此方案） |
| `?token=` query 參數 | ✓ 原樣傳遞 | ✓ 保留 | ✗ **已知會把 WS upgrade 的 query 參數剝掉** —— 直接打死本專案的 `/ws?token=` |
| 公網暴露面 | **零**（Hub 不在公網上，token 不是唯一防線） | Hub 端點在公網，token 是主要防線（可加 Cloudflare Access 補強） | 公網 |
| 免費額度 | Personal 方案免費：6 users、**裝置數不限**、50 tagged resources、3 ACL groups | Tunnel 本身免費無流量限制（每帳號 1000 tunnels、每 tunnel 100 條邊緣連線）；**但 named tunnel 需自有網域託管在 Cloudflare DNS** | 同 A |
| 行動裝置體驗 | 需裝 Tailscale app 並登入；之後 Flutter app **只需把 base URL 改成 MagicDNS 名稱**，無其他設定。代價：手機常駐 VPN profile（耗電、與其他 VPN 互斥） | **零客戶端安裝**，任何網路直接連 `https://chat.example.com`；Flutter app 完全不需改動 | 零安裝 |
| 設定複雜度 | 低：裝 client、登入、記下 MagicDNS 名稱。無 DNS、無憑證、無設定檔 | 中：需網域 + Cloudflare 帳號 + `cloudflared` 也要做成 Windows 服務（等於多一個常駐要顧） | 低 |

### 2.2 推薦：**A. Tailscale 純 tailnet 直連**（明確排除 Serve / Funnel）

理由：

1. **它把硬條件變成不存在的問題。** P4-04 驗收條件 2 和 3（WS 穩定 ≥30 分鐘、long-poll 25s 不被切斷）之所以是「最容易踩雷的點」，全都源自中間有一層 L7 反向代理。tailnet 直連沒有那一層 —— Flutter app 打到 Hub 的封包只是被 WireGuard 加解密，HTTP 語意零改寫。這不是「應該會過」，是「結構上不可能失敗」。
2. **Cloudflare Tunnel 的 100 秒 WS idle timeout 是真實而且要另外處理的。** 官方明說「WebSockets are supported on all Cloudflare plans」，同時也明說在雙向都沒有資料傳輸一段時間後會關閉連線，社群普遍觀測到 Free/Pro 是 100 秒，且只有 Enterprise 能調。這意味著 Hub 的 WS 必須實作 ≤ 30 秒間隔的 ping/pong heartbeat，否則安靜的房間會反覆斷線 —— 這會反過來變成 P1-01（WebSocket）的需求。
3. **不需要自有網域。** Cloudflare named tunnel 必須有一個託管在 Cloudflare DNS 的網域；quick tunnel（`cloudflared tunnel --url`）的 URL 每次重啟都會變，不能拿來當 Flutter app 的固定設定，不適合常駐用途。
4. **降低安全面積。** 本專案的驗證只有一個共享 token（P4-01 明確不做輪替、不做 per-device 憑證）。把這樣的服務直接掛上公網、讓 token 成為唯一防線，風險偏高。tailnet 讓 token 退居第二道防線。
5. **少一個常駐要顧。** 走 Cloudflare Tunnel 的話 `cloudflared` 也得跟 Hub 一樣做成服務、一樣要 log、一樣要監控，P4-03 的工作量會多一份。

**必須明確寫進 DEPLOY.md 的禁令：不要用 `tailscale serve` / `tailscale funnel` 來暴露 Hub。** 這兩者是 Tailscale 自帶的 HTTPS 反向代理，已知 (a) 會剝除 WebSocket upgrade 請求的 query 參數 —— 本專案 `/ws?token=` 會直接失去 token 而驗證失敗；(b) WS 連線每 10–40 秒被以 1001 關閉。用了它就等於把方案 A 的全部優勢丟掉，還額外踩兩個坑。

### 2.3 什麼情況該改用 Cloudflare Tunnel

- 需要讓**沒有安裝 Tailscale、也不打算安裝的人**存取（例如臨時分享）
- 手機端因為公司 MDM / 其他 VPN 佔用而無法常駐 Tailscale
- 已經有網域託管在 Cloudflare，且願意實作 WS heartbeat

改用時的必辦清單：
1. Hub 的 WS 加 **≤ 30 秒的 ping/pong heartbeat**（server 主動 ping），並在 Flutter 端做指數退避重連
2. long-poll `timeout` 維持 25 秒，**上限不得超過 60 秒**，保留對 100 秒 524 門檻的餘裕
3. `cloudflared` 的 `keepAliveTimeout` 設 90s 左右、`noTLSVerify` 保持關閉
4. 前面加一層 Cloudflare Access（免費方案含 50 seats），不要讓 token 當唯一防線
5. `cloudflared` 同樣用 WinSW 做成服務

### 2.4 兩案共通的驗收方式（給 P4-04）

- 用手機行動網路（**關掉 Wi-Fi**）測，不能用同網段自欺
- WS 開著掛 40 分鐘不發任何訊息，觀察是否斷線 —— 安靜的連線才是真正的測試
- 連續發 30 次 25 秒空 long-poll，確認每次都是 200 + 空結果，而不是 5xx 或提早返回
- 帶錯誤 token / 不帶 token 打一次全部端點與 WS，確認被擋

**來源**：[Cloudflare WebSockets 官方文件](https://developers.cloudflare.com/network/websockets/)、[Cloudflare Connection limits（Proxy Read Timeout 125s）](https://developers.cloudflare.com/fundamentals/reference/connection-limits/)、[Cloudflare Error 524（100 秒門檻）](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-5xx-errors/error-524/)、[Websocket timeout over cloudflare tunnel（社群回報）](https://community.cloudflare.com/t/websocket-timeout-over-cloudflare-tunnel/524610)、[Tailscale 免費方案](https://tailscale.com/docs/account/manage-plans/free-plans-discounts)、[tailscale/tailscale#18651：serve 剝除 WS query 參數](https://github.com/tailscale/tailscale/issues/18651)、[tailscale/tailscale#18827：serve 的 WS 每 10–40 秒斷線](https://github.com/tailscale/tailscale/issues/18827)、[Tailscale Funnel 文件](https://tailscale.com/kb/1223/funnel)

---

## 3. SQLite WAL 備份要點（P4-05）

### 3.1 先講不能做的事

WAL 模式下**絕對不可以直接複製 `chatroom.db`**。已提交但尚未 checkpoint 的交易只存在於 `chatroom.db-wal` 中，單獨複製主檔會得到一個「舊的、缺最近訊息」的資料庫。同時複製 `.db` + `-wal` + `-shm` 三個檔也不安全 —— 三次複製之間資料庫可能被寫入，得到的組合不是任何一個時間點的一致狀態。**P4-05 的驗收條件 1（執行中可安全產出一致快照）只能靠 SQLite 自己的機制達成。**

### 3.2 `VACUUM INTO` vs Backup API

| | `VACUUM INTO 'path'` | Backup API（`sqlite3_backup_*` / Python `Connection.backup()`） |
|---|---|---|
| 一致性 | 產出是來源資料庫的一致快照（在單一讀交易內完成） | 一致，但作法不同：分頁增量複製 |
| 併發寫入 | 執行期間持讀鎖；WAL 模式下寫入者不被阻擋，但若有連線持有阻止寫入的鎖，VACUUM 會失敗 | 若複製過程中來源被寫入，**備份會從頭重啟**；寫入頻繁時可能長期無法完成 |
| 產出體積 | **最小**：重建、去碎片、清除已刪除內容 | 與來源同大小（含空頁碎片） |
| 資源 | CPU / I/O 較重，一次做完 | CPU 較省，可分批增量執行（`pages` 參數 + `sleep`） |
| 中斷後果 | 目標檔不完整，需刪除重來（不影響來源） | 同樣需重來（不影響來源） |
| 呼叫方式 | 一行 SQL，可從任何 client 執行，**不需要停服** | 需要 Python 程式碼 |

### 3.3 推薦：**`VACUUM INTO`**

本專案的寫入型態是「單使用者、少量聊天訊息、絕大多數時間閒置」，Backup API 的兩個優勢（省 CPU、可增量）在這裡沒有價值，而它的最大弱點（來源被寫入就重啟複製）在夜間備份時反而是不必要的不確定性。`VACUUM INTO` 一行 SQL、產出緊實、語意最單純，是明確的選擇。

### 3.4 施工要點（給 P4-05）

```sql
-- 備份腳本核心（以唯讀之外的連線執行，不需停 Hub）
VACUUM INTO 'D:/backup/chatroom-20260827T030000.db';
```

- 檔名帶 UTC ISO 時戳；目標**必須是不存在的檔案**，`VACUUM INTO` 不覆寫既有檔
- 寫成 `deploy/backup.ps1`，由工作排程器每日執行（備份是排程任務，這裡用工作排程器是對的，不要和 P4-03 的常駐服務混為一談）
- 保留策略：日備留 14 份、每月 1 號那份另存留 6 份
- 備份完立刻對產出跑 `PRAGMA integrity_check;`，失敗就保留錯誤檔並告警
- 還原演練：停服 → 移走 `chatroom.db` / `-wal` / `-shm` **三個檔** → 把備份改名放回 → 起服 → 驗 `SELECT room_id, MAX(seq) FROM message GROUP BY room_id;` 與訊息總數，確認 seq 連續（驗收條件 2）
- 觀察體積成長：每次備份後把檔案大小追加到 `backup-size.csv`，作為「訊息量成長的體積觀察」的紀錄

**來源**：[SQLite VACUUM（含 VACUUM INTO 與 Backup API 的官方比較）](https://sqlite.org/lang_vacuum.html)、[SQLite Backup API](https://sqlite.org/backup.html)、[SQLite WAL 模式](https://sqlite.org/wal.html)

---

## 4. 建議落地順序與工作量預估

| # | 步驟 | 對應卡 | 預估 | 備註 |
|---|------|--------|------|------|
| 1 | Token 產生工具、`.env` 載入、`.gitignore` 覆蓋 `chatroom.db*` 與設定檔、token 不外洩複查 | P4-01 | 0.5 天 | 前置，無選型爭議 |
| 2 | Hub 綁 `0.0.0.0`、防火牆規則、CORS、多 client seq/WAL 併發驗證 | P4-02 | 1 天 | 併發驗證是主要工時 |
| 3 | **WinSW 服務化**：`deploy/chatroom-hub.xml` + install/uninstall 腳本 + log 輪替 | P4-03 | 0.5 天 | 已定案，照 §1.3 施工 |
| 4 | 重開機驗證 + kill 進程驗證 + log 輪替驗證 | P4-03 | 0.5 天 | 需要一次實機重開機 |
| 5 | **備份腳本 + 排程 + integrity_check**（可與 6 並行） | P4-05 | 0.5 天 | 照 §3.4 |
| 6 | 還原演練並留紀錄 | P4-05 | 0.5 天 | 建議在 7 之前做完，外網開通前先有回復能力 |
| 7 | **Tailscale 安裝 + 桌機/手機/筆電入網 + MagicDNS 名稱固定** | P4-04 | 0.5 天 | 照 §2.2；明令不用 serve/funnel |
| 8 | 外網驗收：行動網路連線、WS 掛 40 分鐘、30 次空 long-poll、未授權阻擋 | P4-04 | 1 天 | 40 分鐘掛機測試可與其他工作並行 |
| 9 | 收斂 `docs/DEPLOY.md`、從零跑一次完整部署驗收 | P4-06 | 1.5 天 | 「不看原始碼就能部署」是硬條件，會來回改 |

**合計約 6.5 人日。**

順序上的兩個刻意安排：
- **備份（5、6）排在外網開通（7、8）之前**。原文的依賴圖把 P4-05 和 P4-04 並列，但先有回復能力再開外網比較安全。
- **Tailscale 排最後才裝**。它會改變本機網路介面，先把區網與服務化的問題全部收乾淨，出問題時才不會有兩個變因。

---

## 5. 需要注意的殘留風險

1. **Tailscale 讓手機常駐 VPN**：與部分企業 MDM / 其他 VPN app 互斥，也會有電量與「其他 app 流量是否走 tailnet」的疑慮（可用 exit node 設定控制，預設不走）。若使用者無法接受，就要回退到 §2.3 的 Cloudflare Tunnel 路線，屆時 WS heartbeat 變成 P1-01 的必做項而非選配。
2. **不論走哪條路，Hub 的 WS 都該有 heartbeat**。方案 A 不強制需要，但它同時也是偵測「對端已死」的唯一手段，建議在 P1-01 就補上，這樣 P4-04 若需要換方案不會被卡住。
3. **`API_TOKEN` 在 WS 走 query string**（`/ws?token=`）。tailnet 內沒問題，但若未來改走任何反向代理，query string 會進入代理的 access log。長期建議改成 `Sec-WebSocket-Protocol` 或首個 message 做驗證 —— 記為未來項，本階段不動。
4. **WinSW 的服務帳號與檔案路徑**：若用 `LocalSystem`，`chatroom.db` 與 log 的相對路徑會解析到 `C:\Windows\System32`。設定檔一律用絕對路徑。
