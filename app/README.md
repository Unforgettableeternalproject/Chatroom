# Chatroom App（Flutter）— Phase 3

人類使用者的聊天室 UI：房間列表、聊天視圖、釘選牆、訊息管理（刪除/釘選）、
指派 agent 加入房間、自己發言。

## 尚未初始化

本機目前未安裝 Flutter SDK。安裝後在此目錄執行：

```bash
flutter create --project-name chatroom_app --platforms windows,android .
```

## 預計技術選型

- 通訊：REST（讀寫）+ WebSocket `/ws`（即時更新，Hub Phase 1 提供）
- 狀態管理：Riverpod
- 設定頁：Hub URL + API token（跨裝置連線用）
