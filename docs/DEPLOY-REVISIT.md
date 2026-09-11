# 部署路徑 revisit — 從「第一次拿到 kit 的人」回頭看

2026-09-09。承 `DEPLOY-RESEARCH.md`（選型研究，仍然有效）與 `host-kit/README.md`
（出貨中的說明）。**這份不重做選型，它回答一個不同的問題：出貨的東西與當初的
研究對不對得上，以及一般人真正會走的那條路上還缺什麼。**

---

## 1. 先講最容易誤導人的一件事

`DEPLOY-RESEARCH.md` §2.2 推薦的是 **Tailscale 純 tailnet 直連**，而
**host-kit 出貨的是 Cloudflare Quick Tunnel**（`scripts/run-tunnel.cmd`）。

這**不是**矛盾——研究 §2.3 早就寫了「需要讓沒裝也不打算裝 Tailscale 的人存取」
時該改用 Cloudflare Tunnel，而那正是 kit 的目標受眾。但研究文件從頭到尾沒有一句
話說「我們最後出貨的是 B 案」，於是：

> 讀 `DEPLOY-RESEARCH.md` 的人會以為部署方式是 Tailscale，
> 讀 `host-kit/README.md` 的人會以為部署方式是 Cloudflare，
> **兩份都是專案內的正式文件，而它們沒有互相指過對方。**

⚠️ **兩者的紅線不同，混著讀會出事**：`tailscale serve` / `funnel` 的禁令
（研究 §2.2）是針對 A 案的，出貨路徑上根本不會遇到；而 Quick Tunnel 有一份
自己的必辦清單（§2.3），那份才是與出貨相關的。這份文件的存在就是為了把這條
接縫講明。

**處置**：`DEPLOY-RESEARCH.md` 維持不動（它是當時的選型紀錄，改它等於改寫歷史），
由這份文件負責說明現況；README 的內容以出貨路徑為準。

---

## 2. Quick Tunnel 必辦清單 × 現況查核

研究 §2.3 列了改走 Cloudflare 時的五項必辦。逐條對出貨中的程式碼查核：

| # | 必辦事項 | 現況 | 判定 |
|---|---|---|---|
| 1 | WS 要有 ≤30 秒 heartbeat（邊緣約 100 秒 idle 即關閉） | App 每 **20 秒**送 `ping`，10 秒收不到 `pong` 判連線已死（`realtime_service.dart`）；Hub 回 `pong` | ✅ 達成 |
| 2 | long-poll ≤60 秒（保留對 100 秒 524 門檻的餘裕） | Hub 上限 `max_poll_timeout = 55.0`；watcher 預設 `--poll-timeout 50` | ✅ 達成 |
| 3 | `cloudflared` 參數與隔離 | `tunnel.py` 用 `--config` + `--origincert` 隔離掉家目錄的既有帳號設定，`--no-autoupdate` | ✅ 達成（且比清單更嚴） |
| 4 | 前面加一層 Cloudflare Access，不要讓 token 當唯一防線 | **沒有做** | ❌ 未做 |
| 5 | `cloudflared` 也做成 WinSW 服務 | 沒有做，隧道是前景視窗 | ⚠️ 刻意不做 |

**#1 與研究的文字有一處出入，但結論不變**：§2.3 寫的是「server 主動 ping」，
實際做成 client 主動。對「避免邊緣因為沒有流量而關閉連線」這個目的來說兩者等價
——連線上有雙向流量就夠了。差別在半開連線的偵測方向，而 App 那側已經有
pong 逾時判死。

**#4 是這條路徑上唯一的真缺口**，而它已經被誠實記錄：README 有一整段
「token 是唯一的門」，講明 token 是信任邊界、房間不是、封存房也讀得到。
**缺口不在於沒人知道，而在於它靠讀者自律。**

**#5 是對的取捨**：Quick Tunnel 的網址每次重開都會變，做成常駐服務只會產生
一個「還活著但網址早就換掉了」的隧道——比沒有更糟。長期對外要的是 named
tunnel，那條路研究已經寫明不在一鍵範圍內。

---

## 3. 一般人真正會走的那條路

拿到 `chatroom-host-kit.zip` 的人，最短路徑是三步：

1. `python install.py` — 建 venv、寫 `server/.env`、印出位址與 token
2. `scripts\run-hub.cmd` — Hub 跑起來（或 `hub-service.ps1 install` 做成自啟）
3. 把**位址 + token** 發給成員；成員裝 `chatroom-mcp-kit`（agent）或桌面 App（人）

只有在「成員不在同一個內網／VPN」時，才需要第四步 `scripts\run-tunnel.cmd`，
並把那個 `https://<隨機>.trycloudflare.com` 連同 token 發出去。

### 三個岔路，各自的判準

| 你的情況 | 走哪條 | 代價 |
|---|---|---|
| 成員都在同一個 VPN 或同區網 | **不要開隧道**，直接發內網位址 | 無。這是最安全也最穩的路 |
| 有人連不進來、只是臨時要用 | Quick Tunnel | 網址每次重開都變，要重發；token 成為唯一防線 |
| 要長期對外、固定網址 | named tunnel（需自有網域 + Cloudflare 帳號） | 不在一鍵範圍內，且要自己顧一個常駐 `cloudflared` |

**第一列是預設答案，而現在的 README 沒有把它講成預設。** 隧道那節寫得比
「其實你多半不需要它」更顯眼，讀的人容易以為對外協作就得開隧道。

---

## 4. 這次 revisit 找到的、值得處理的三件事

1. **兩份文件互不指涉**（§1）——本文件補上，但 `DEPLOY-RESEARCH.md` 開頭
   最好加一行指回這裡，否則下一個人仍然會先讀到 Tailscale 然後照著做。
2. **「多半不需要隧道」應該講成預設**（§3）——這是文案層的事，不是功能。
3. **Cloudflare Access：明知而不做**（§2 #4）——2026-09-09 裁定（決策Novia）。
   不是漏掉，是權衡過的取捨：Access 會在隧道前面多一層登入，而這個 kit 的
   整個目標是「拿到就能跑起來」，多一層帳號設定就把它推回原本要解決的問題。
   **代價明寫**：隧道開著時 token 是唯一的門，而 token 能讀所有房間（含沒
   加入的與已封存的）。處置是「隧道用完就關、token 只發給信任到可以看全部
   內容的人」，README「token 是唯一的門」那節就是這個代價的說明書。
   要重開這個決定的條件：長期對外常駐（那時本來就該換 named tunnel，
   Access 是那條路上的配套，不是這條路上的）。

前兩件已於 2026-09-09 做掉（研究文件頂端加路標、README 隧道節重排）。

## 5. 沒有改變的紅線

- **`tailscale serve` / `funnel` 仍然不能用**（研究 §2.2）：會剝除 WS upgrade 的
  query 參數，`/ws?token=` 直接失效；且 WS 每 10–40 秒被以 1001 關閉。
  這條與走哪個方案無關，任何時候都不要用。
- **long-poll 上限不得超過 60 秒**，否則撞 Cloudflare 的 524 門檻。
- **備份要同時帶走 `server/chatroom.db` 與 `server/attachments/`**，
  只還原 db 會讓所有附件變成「metadata 在、內容不在」（下載回 410）。
- **`cloudflared` 不要反覆啟停**：Cloudflare edge 的路由表來不及收斂，會讓
  同一個 tunnel 底下部分 hostname 路由到錯的地方，**而 DNS 與 route 設定
  看起來都是對的**。這條在 named tunnel 上才會咬人（Quick Tunnel 每次都是
  新網址，天生沒有這個問題），但排查時很難想到——症狀是「設定沒錯卻連不對」。
  遇到就停下來等幾分鐘再起，不要連續重試。
