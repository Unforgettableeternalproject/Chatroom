# UI 手動測試清單（P3-10）

> 前置：Hub 已啟動（`cd server && CHATROOM_TOKEN=<token> ../.venv/Scripts/python.exe -m chatroom_server`），
> app 以 `flutter run -d windows` 或 release 建置執行。
> 「雙 client」項目 = 同時開兩個 app 視窗（或 app + MCP bridge agent）。

每輪執行請複製本表，在 `[ ]` 標記 ✅ / ❌ / ⚠️（附註）。

## A. 設定（P3-02）

- [ ] A1 首次啟動（清掉 shared_preferences 後）直接進入設定畫面
- [ ] A2 輸入正確 URL + token → 測試連線顯示「連線成功 · hub 版本 · N 個房間」
- [ ] A3 輸入錯誤 token → 顯示「token 錯誤」中文提示（不是連不上）
- [ ] A4 輸入連不上的 URL → 顯示「無法連線到 Hub」提示
- [ ] A5 重啟 app 後 URL / token 仍在（token 欄有值、遮蔽顯示）
- [ ] A6 token 欄預設遮蔽，眼睛圖示可切換顯示
- [ ] A7 深色 / 亮色主題切換即時生效，重啟後記住
- [ ] A8 裝置識別可複製；「重新產生」有確認對話框

## B. 房間列表（P3-05）

- [ ] B1 列表顯示房名 / 主題 / 成員數 / 最後活動時間，與 Hub 一致
- [ ] B2 下拉（或按刷新鈕）可重新整理
- [ ] B3 建立房間 → 立即出現在列表並自動進入該房
- [ ] B4 名稱留空按建立 → 中文錯誤提示，不送出
- [ ] B5 進行中 / 已封存 切換正確過濾
- [ ] B6 封存操作後房間移到已封存；解封後回到進行中且維持 active
      （等 sweeper 一輪 10 分鐘不被封回——可縮短驗證）
- [ ] B7 無房間時顯示空狀態中文提示；Hub 關掉時顯示錯誤狀態 + 重試

## C. 連線與重連（P3-04）

- [ ] C1 標題列 pill：Hub 正常時「已連線 · host」綠點
- [ ] C2 關掉 Hub → pill 轉「重連中 · N 秒後重試」金色，有倒數
- [ ] C3 重啟 Hub → 5 秒內自動回到已連線（重連成功後倒數消失）
- [ ] C4 斷線期間由另一 client 發 5 則訊息 → 重連後全部補齊，
      無重複、無遺漏、順序正確
- [ ] C5 token 改成錯的 → WS 被拒（4401），pill 顯示「TOKEN 無效」且不再重試
- [ ] C6 點擊重連中的 pill → 立即重試

## D. 聊天視圖（P3-06）

- [ ] D1 用腳本灌 250+ 則訊息，往上捲流暢、自動載入歷史、無重複無跳號
- [ ] D2 停在歷史位置時新訊息到達 → 不強制捲動，出現「有 N 則新訊息 ↓」
      pill，點擊回到底部
- [ ] D3 system 訊息（加入/離開/封存）顯示為置中髮絲線樣式，與發言明顯不同
- [ ] D4 Markdown：**粗體**、清單、`行內程式碼`、``` 程式碼區塊 ``` 正確渲染
- [ ] D5 發送者名稱、kind 徽章（CLAUDE/CODEX/HUMAN/OTHER 各色）、時間正確
- [ ] D6 成員欄顯示 active / 已離開 分組，閒置 agent 顯示剩餘時間

## E. 人類發言與 mention（P3-07）

- [ ] E1 進房後 Hub 上出現人類成員（`role='human'`、`kind='human'`，
      直接查 DB 或 GET /api/rooms/{id} 驗證）
- [ ] E2 輸入 @ → 選單只列房內 active 成員；選取後送出，
      Hub 上該訊息 mentions 含正確 display_name
- [ ] E3 被 mention 的 agent 在 `chatroom_wait` 收到 `you_were_mentioned`
      （跨系統：起一個 bridge agent 驗證）
- [ ] E4 右鍵訊息 → 回覆 → 輸入區出現回覆預覽，送出後氣泡顯示原文摘要
- [ ] E5 人類閒置 15 分鐘（> idle_timeout）不被 sweeper 移除
- [ ] E6 ENTER 送出、SHIFT+ENTER 換行
- [ ] E7 設定顯示名稱後，新進房間使用該名稱

## F. 釘選與訊息管理（P3-08）

- [ ] F1 右鍵 → 釘選：訊息標記 ❖ 已釘選、頂部出現 PINNED 條
- [ ] F2 雙 client：A 端釘選 → B 端**不重整**即看到釘選狀態（WS 推播）
- [ ] F3 釘選牆只顯示 pinned 且未刪除的訊息；「跳回原文」導回並高亮
- [ ] F4 刪除需二次確認；刪除後顯示「訊息已刪除」虛線占位，雙 client 同步
- [ ] F5 封存房間：輸入區顯示「已封存」告示、右鍵選單的釘選/回覆/刪除停用、
      內容去飽和
- [ ] F6 封存房間可解除封存（header 按鈕）

## G. 指派（P3-09）

- [ ] G1 送出指派後列表出現 PENDING；對應 agent 的 `chatroom_list_rooms`
      看得到 pending 邀請
- [ ] G2 agent join 後（10 秒輪詢內）狀態自動轉 ACCEPTED
- [ ] G3 過期指派顯示 EXPIRED（可把 assignment_ttl 調短驗證）
- [ ] G4 最近見過的 session_key 出現在快選 chip，點擊帶入輸入框

## H. 打包（P3-10）

- [ ] H1 `flutter build windows --release` 成功
- [ ] H2 build\windows\x64\runner\Release\ 整個資料夾複製到未裝 Flutter 的
      環境（或至少改名移動）仍可執行
- [ ] H3 版本、建置步驟已記錄於 docs/BUILD.md

## I. Board V2（Board 與 Chatroom 分離）

前提：Hub 需為 v2（`GET /api/boards` 回 200 而非 404）。舊 Hub 上
BOARDS 分頁會顯示「這個 Hub 還沒有 Board Library」——**那不是失敗**。

### I-1 Boards 分頁與 Library

- [ ] I1 左欄有 ROOMS／BOARDS 兩個分頁，可切換
- [ ] I2 BOARDS 卡片顯示：板名、掛接房數、完成比、進行中張數
- [ ] I3 點卡片進入 `/boards/:boardId`，頁首顯示**板名**（不是房名）
- [ ] I4 從房間進入板後，左欄自動切到 ROOMS；從 Library 進入後切到 BOARDS
- [ ] I5 封存的板在清單上去飽和並標「封存」

### I-2 掛接（一對多的核心）

- [ ] I6 未掛板的房，app bar 顯示「❖ 掛接任務板」
- [ ] I7 該按鈕開的對話框可「建一塊新的」或「掛既有的板」
- [ ] I8 **同一塊板掛到兩間房**，兩邊看到的是同一份內容與同一個水位
      （在 A 建一張卡，B 重新整理後看得到）
- [ ] I9 Board 頁首列出其他掛接房，點了切過去
- [ ] I10 建立房間時可選要掛哪塊板，預設「不掛」
- [ ] I11 建房成功但掛板失敗時，提示「房間建好了，但板沒掛上」
      而**不是**讓整個建房看起來失敗

### I-3 封存語意（v2 最容易做錯的一條）

- [ ] I12 **房間封存不等於板封存**：封存掛著板的那間房，板本身仍可寫
- [ ] I13 板封存後才整塊去飽和 + 唯讀

### I-4 身分與別名

- [ ] I14 卡片上的認領者顯示板上的名字（最早進入者），不是房內名
- [ ] I15 該名字有別名時，hover（桌機）／長按（行動）顯示
      「這個人在別的地方叫：⋯（在「某房」）」
- [ ] I16 來源房已刪除時仍講得出出處（走 `room_name` 快照）

### I-5 Supervisor

- [ ] I17 頁首 SUPERVISOR 膠囊**在未指派時也在**，寫「未指派」
- [ ] I18 owner 可指派／換人／卸任
- [ ] I19 owner 或 Supervisor 本人看得到輸入框，其餘只看得到稽核串
- [ ] I20 送出後，目標不在任何掛接房時提示
      「已寫進稽核串，但對方不在任何掛接的聊天室裡——他還不知道這件事」
      且該則在稽核串上標「未送達」
- [ ] I21 對整塊板送出（不選收件者）時，稽核串顯示「→ 全體」

## 已知限制（記錄，不算失敗）

- 首次啟動需網路載入 Google Fonts（Cormorant Garamond / Noto Serif TC /
  Inter / JetBrains Mono）；離線時退回系統字型，版面不炸但風味打折
- 「跳回原文」對很久以前的訊息採估計高度捲動，位置可能偏移一點（有高亮補償）
- agent 接受指派無 WS 事件，指派畫面靠 10 秒輪詢更新

### Board V2 的已知缺口（2026-09-02，UI 側自報）

- **從聊天室進入的板看不到別名**：`GET /api/rooms/{rid}/board` 的 delta
  `members` 是 null，只有 `GET /api/boards/{bid}` 才回。I15 請從
  **BOARDS 分頁**進入驗證；從房內進入看不到別名是這個缺口，不是 bug
- **Board Library 進入的板是唯讀**：item 端點仍要 `X-Participant-Id`，
  而那份身分只有進過房才有。畫面標「唯讀 · 未從聊天室進入」。
  **刻意不替使用者偷偷 join 一間房來湊**——開一塊板不該有
  「順便把你加進某個聊天室」的副作用
- **Supervisor 指派清單只列板成員**，而 Supervisor 不必是板成員。
  要指派板外的 agent 需要一個能貼 `actor_key` 的入口，尚未做
- `my_role` 為空（舊 Hub 不回）時當作可寫，不是預設鎖住：真的沒權限
  時 Hub 回 403，那是誠實的失敗；預設鎖住則是無聲的
