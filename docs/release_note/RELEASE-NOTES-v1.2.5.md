# Chatroom v1.2.5

執行器登入健康版。執行器會自己發現 Claude 登入失效並停止領單，並支援長效 token。
Hub 沒有程式變更，資料庫版本不動；要拿到這一版的修正只需要重裝執行器與 App。

---

## 執行器

- 新增長效 token：狀態目錄下有 `claude-oauth-token` 時，內容以
  `CLAUDE_CODE_OAUTH_TOKEN` 帶給執行器起的每一個 claude 子進程。每次起進程都重讀，
  換 token 不必重啟執行器。
- 新增定期登入重驗（`login_check_seconds`，預設 900 秒）：登入失效時狀態改
  `limited`、原因 `login_expired` 並停止領單，恢復後自動續領。
- run 撞到 OAuth 過期或未登入時，整台執行器停收，而不是只把那一筆標成 failed。
- 修正登入檢查誤判：沒登入時 `claude auth status --json` 的退出碼是 1、JSON 照樣印在
  stdout。原本只在退出碼 0 才讀 `loggedIn`，沒登入因此退回憑證檔判準，檔案還在就判成
  已登入並照常領單。現在只認 JSON 裡布林的 `loggedIn`。
- 修正勾選的 MCP 仍卡在權限提示：允許清單裡的伺服器現在一併加入
  `mcp__<server>__*` 預授權；先前只解除 deny，`auto` 模式下工具仍然要人核可。
- 修正帶連字號的伺服器名被正規化：`lore-vault` 不再被算成 `lore_vault`。

## 執行器安裝包

- 安裝器判斷登入時先問 `claude auth status`，問不到才看憑證檔；有長效 token 檔也算。

## App

- 執行器分頁的登入列改用 `claude auth status` 判斷，分得出已登入／已過期／未登入。
- 登入按鈕會開新終端執行 `claude auth login`。
- 可以產生、貼上、清除長效 token；畫面只顯示已設定或未設定，不回顯內容。
- MCP 區塊與派工儀表板在執行器登入過期時顯示「登入已過期」。
- 修正附件圖片顯示不出來：伺服器網址結尾帶 `/` 時組出 `//api/attachments/...`，
  Hub 回 404。現在會先去掉結尾的 `/`。

## 升級注意

- 執行器重裝後設定檔原樣保留。新鍵 `login_check_seconds` 沒寫時用預設值。
- 重裝後執行器會真的驗登入：設定目錄沒登入、也沒有長效 token 的機器，自檢不會過，
  不再上線領單。先登入或在 App 貼上長效 token。
