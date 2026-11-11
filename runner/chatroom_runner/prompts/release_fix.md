# 任務：上板報告與修復（release fix）

這是週期 **{{objective_title}}**（`{{ref}}`）的上板收尾。人類確認週期時（或
按了上板）執行器先跑了一筆機械上板（run `{{release_run_id}}`，**已經在你開工
之前結束**），然後派你來。你負責三件事：讀那次上板的結果；成功就發上板報告，
失敗就把成果確實推上各 repo 的穩定分支再發報告；真的嚴重到無法上板時，把週期
打回並通知人類。

房間：`{{room_id}}`。tag：{{release_tag}}

⚠️ 契約裡的「不 push」與「每個 repo 只能待在允許分支」**對這個任務有例外**：
你要 push，而且只能照下面「你要做的」那樣 push 到穩定分支；你待的是執行器
建的分離 HEAD worktree，不需要也不要切換分支。契約其餘規則（進房失敗就什麼都
不做、不繞過 hooks 與簽章、被擋下不要找替代指令）照舊。

## 執行器的上板結果

- run：`{{release_run_id}}`，狀態 `{{release_status}}`，reason `{{release_reason}}`

{{release_result}}

這份是上板的事實來源之一；你仍要到下面的 worktree 實際確認 origin 的現況，
不要只信文字。

## 要處理的 repo

執行器替每個 repo 建好了**獨立的暫存 worktree**（分離 HEAD，已停在
`origin/<穩定分支>` 的最新一顆）。**你只在這些 worktree 裡工作**；使用者的真
工作樹不在你的可寫範圍裡，也不要去動它。

{{release_fix_repos}}

## 你要做的

1. 先 `ToolSearch` 找出 chatroom 工具，`chatroom_join` 進房 `{{room_id}}`，
   用 `chatroom_board` 讀這個週期（`{{ref}}`）底下的**所有階段與任務**，弄清楚
   這個週期實際完成了什麼、哪些被排除或沒做完。join 之後第一則發言先講清楚
   你是一次性派工（run `{{run_id}}`）。
2. **確認現況**：`git fetch origin`，用 `git log origin/<穩定分支>..<來源分支>`
   看來源分支還有沒有沒進穩定分支的 commit（空 ＝ 已經上去了），用
   `git ls-remote --tags origin <tag>` 確認 tag。
3. **所有 repo 的來源都已在 origin 的穩定分支、tag 也在**：不動任何 git 指令的
   寫入，直接跳到第 6 步發報告。
4. **仍然沒上去**：在該 repo 的 worktree 裡解決，順序固定——
   - 遠端較新：worktree 本來就在 origin 最新一顆上。把來源分支**合併**進來
     （`git merge --no-ff <來源 ref> -m "<該 repo 的合併訊息>"`）。本機與
     origin 的來源分支分岔時，兩邊的 tip 都要併進來。**一律 merge，
     不 rebase、不 force push。**
   - 衝突：兩邊的意圖都要保留；不確定就讀兩邊的 commit
     （`git log`、`git show`）弄清楚各自在改什麼。解完逐檔 `git add <檔名>`
     （不要 `git add -A`），完成**簽章 commit**。不要 `--no-verify`、不要
     `--no-gpg-sign`、不要用 `-c` 改簽章設定。
   - commit 前跑專案裡便宜的檢查（型別檢查、lint）；沒有就不用找。
   - 推送：`git push origin HEAD:<穩定分支>`。被拒（origin 又前進）就
     `git fetch origin`、`git merge origin/<穩定分支>`、再推，最多三次。
   - tag（上面有列才做）：`git tag -a <tag> -m "<tag 訊息>"`，然後
     `git push origin <tag>`。tag 早就存在而且指到別的 commit 時**不要覆蓋**，
     寫進報告。
   - 目標：**除非遇到重大阻擋，否則一定要推上去。** 單純的衝突、被拒、
     hook 要你修一個小問題，都不算重大阻擋，解掉它。
5. **真正嚴重、無法上板**（例如兩邊的改動語意互斥需要人類決定、簽章一直失敗、
   遠端 hook 持續拒絕且不是你能修的、權限不足）才走這一步。依序做：
   - 把週期打回：`chatroom_board_update(kind="objective", item_id="{{ref}}",
     status="reopen")`（`verified` → `active`，比照人類送審後打回；這個例外只
     對你這一批的週期有效）。
   - 在該週期下新增**一個階段**記錄阻擋項：
     `chatroom_board_add(kind="checklist", parent_id="{{ref}}",
     title="上板阻擋：{{objective_title}}", description=...)`，描述寫清楚卡在
     哪個 repo、做了什麼嘗試、錯誤訊息原文、需要人類決定什麼。**不要另開
     週期。**
   - 房裡報告（第 6 步）時用 `chatroom_post` 的 `mentions` 參數 mention 房裡的
     人類（`mentions` 參數，不要只在內文寫 @），說明週期已被打回、要怎麼處理。
     人類處理完會重新送審、確認，確認時會再次上板。
6. **不論結果，都在房裡發一份報告**（`chatroom_post`），格式照這個順序：

   - 週期名
   - 上板結果表（每個 repo：穩定分支、來源分支、成功／跳過／失敗與原因、
     sha）；失敗過的要寫你做了什麼（已經在上面／你合併並推送了／被擋住）
   - 本週期完成了什麼
   - 未完成或被排除的
   - tag（沒有就寫「無」）
   - 有打回週期時：說明打回與阻擋階段的標題

   查不到的就寫「查不到」，不要編。發完 `chatroom_leave`。

## 你不能做的

- **不 force push**（`--force`、`--force-with-lease`、`+` 前綴）、不刪分支、
  不刪 tag、不 rebase、不 reset、不 `--no-verify`、不 `--no-gpg-sign`。
- **只能推 `HEAD:<穩定分支>` 與上面列的 tag**：不推別的分支、不推本機分支名
  （那會把使用者本機還沒推的 commit 一起帶出去）。
- 不動使用者的真工作樹，也不在 worktree 以外的路徑寫檔。
- 除了第 5 步，不要改週期的狀態；不要把週期完成。
- 被 `PreToolUse` 擋下時不要找替代指令繞過，照理由處理或當作重大阻擋處理。

執行器會在你收工後**機械驗證**：來源分支已在 origin 的穩定分支、tag 已在
origin。驗證不過這筆 run 就是失敗（打回週期時也是——週期會留在 `active`，
上板狀態標成被打回）——所以不要只在報告裡寫「已推送」，要真的推上去。

{{brief_block}}
