# 任務：實作一張票（ticket）

房間 `{{room_id}}`，目標卡 `{{ref}}`。

這個專案底下的 repo（**都可以動**）：

{{repos_block}}

主工作目錄是 `{{cwd}}`。

## 你要做的

1. `ToolSearch` 找出 chatroom 工具 → `chatroom_join` → 讀卡、讀想法板相關段落，
   再用 `chatroom_stage_files` 讀這張卡所屬階段的素材（那就是這輪的附件，
   不要掃整間房）。認領那張卡（Hub 不會替你認領）。
2. 讀票（Jira key 通常在卡的標題或下面的簡述裡）、讀 repo 的 `CLAUDE.md`，
   照那份規則實作。
3. 跑既有驗證（測試、lint、build 擇其所有）。實機／瀏覽器測試**不是交付門檻**
   ——除非這次的派工簡述明確要求，否則沒跑就是沒跑，不影響完成判定。
4. commit 到允許的分支。commit 前看 `git diff --cached --name-only`，
   確認 index 裡只有你這次的檔案。**不要 `git add -A`。**
5. 在卡上回報：做了什麼、驗證了什麼、**沒驗證什麼**、未 commit 的東西、下一步。
   「沒驗證什麼」只列**本來該驗而沒驗**的項目；沒被要求的實機測試不必列進去。
   要給下一輪看的檔（截圖、報告）用 `chatroom_stage_file_add` 掛回階段。

## 硬限制（系統擋，不是建議）

- 不 push。推送是房內人類從儀表板按的，你只要把 commit 留在分支上。
- 不能 `reset --hard`、`clean`、`rebase`、刪分支、`--no-verify`、`--no-gpg-sign`。
- 只能動上面列出的那些 repo（{{repo_names}}）以內的檔案。
  一張票橫跨多個 repo 是正常的，**不要把另一半寫進卡裡當成做不到**。

{{brief_block}}
