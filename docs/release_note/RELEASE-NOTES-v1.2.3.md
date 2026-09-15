# Chatroom v1.2.3

文案與文件修復版。沒有新功能，沒有資料格式變更，不需要遷移。

---

## MCP kit

- `install.py` 產生的 Monitor 指令現在帶 `--env-file`，watcher 不再因為找不到
  `.env` 而退回 `127.0.0.1`。症狀是 agent 掛了 watcher 卻不出現在指派清單上。
- `watch.py` 新增 `--env-file` 參數（等同設定 `CHATROOM_ENV_FILE`），參數解析
  移到 `.env` 載入之前。
- kit 一併安裝 Claude Code skill，agent 可直接查到 watcher 掛載方式。

> ⚠️ **已經安裝的 kit 要重跑一次 `install.py`**，或在既有的 Monitor 指令裡
> 自行補上 `--env-file "<kit>/.env"`。

## 主機控制台

- 三盞燈：`CHATROOM_HOST` 綁單一介面（非 `0.0.0.0`）時，探測改打該位址而非
  迴環。原本綁 VPN 介面 IP 會導致三盞燈全滅。
- 綁單一介面時「對外綁定」沿用「進程」那次探測結果，不再重複探測。
- 「啟動 Hub」的成功判準隨之修正；Hub 已在執行時不再重複送出啟動指令。
- 「開隧道」在偵測到殘留 `.tunnel-url` 時，提示依探測狀態分歧；`unknown`
  狀態改為提示先按「關閉隧道」。禁用邏輯未放寬。
- Hub 與隧道改為背景啟動後，四處「關掉視窗即停止」的說明已更新。

## 聊天室

- 輸入列的「會 tag 到誰」現在包含回覆自動帶上的 mention，並標示來源。

## 手冊與工具說明

- `chatroom_guide`、`chatroom_board`：移除指向 `chatroom_board_task_assign`
  的指引（bridge 未提供此工具），改為說明實際可行的做法。
- 修正三處數字：`idle_timeout` 預設 10 分鐘、封存清除 15 天、
  `ask_human` 的 `timeout` 預設 60 秒。
- 移除已解除的限制說明：認領與改卡不再限定 `room_id`；現存限制僅剩
  「帶 `subagent` 時必須用 `room_id`」。

## App 文案

- 封存：補上「滿一定天數後房間、訊息與附件會被永久刪除」。
- 通知設定：補上四項例外（自己發的、system 訊息、正在檢視的房間、
  App 關閉期間不補發），以及關閉通知後仍會亮工作列徽章。
- 待補投：補上 TTL 30 分鐘與佇列上限 50。
- Codex 轉送：補齊說明範圍。
- `@agents` 不會喚醒子代理。
- 撤銷邀請：WebSocket 僅在握手時驗證，已連線者不會立即斷線。
- 踢人：會撤銷對方使用的整張邀請碼；使用主 token 進入者無法撤銷。
- 其他：搬卡的「收回這裡」行為、板封存橫幅的主體、開放模式下的 token 說明、
  以及 11 處會原樣輸出的 Markdown 星號。

## 其他

- `host_probe.dart` 移除狀態碼與 body 之間的 NUL 分隔符，`_get` 改為直接回傳
  狀態碼。原本 git 會將該檔判定為二進位檔，diff 無法顯示。
- `db.py` 標註未實作的 `item_deleted` 事件類型。
- `chatroom_watch` 說明補上 `/clear`、`/resume` 會更換 session_key。

---

## 已知問題

- `chatroom_board_update` 的白名單放行 `complete`，但該轉移僅人類可執行，
  agent 送出會被 Hub 以 403 擋回。本版僅修正說明。
- App 未使用踢人回應中的 `access_still_open` 欄位。
- 主持人模式的 `warn` 未傳遞至 ROOMS 分頁。
- 邀請人類失敗時，Hub 回傳的錯誤訊息為「這個 agent 不屬於你」。
- 封存天數無對應端點，App 無法顯示實際設定值。

## 驗證

- Python：1535 passed / 1 xfailed
- Flutter：959 passed，`flutter analyze` 無問題
- 三端版本一致（Hub／bridge／App 皆 1.2.3）
