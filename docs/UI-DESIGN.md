# Chatroom Flutter UI — 前置架構設計（Phase 3）

> 本文件是 P3-02 ~ P3-10 的施工圖。P3-01（Flutter SDK 安裝）完成後，
> 照本文件的資料夾結構、介面契約與狀態機直接動工，不需要再回頭做選型討論。
>
> 對應規劃書：`docs/PLANNING.md` §5 API 草案、§4.3 通知與 ping。
> API 契約以 `server/chatroom_server/app.py` 的實作為準（本文件已逐條核對過）。

---

## 0. 設計前提

| 前提 | 內容 |
|------|------|
| 目標平台 | Windows desktop（主）、Android（次）。**不做 Flutter Web** |
| 使用者數 | 單一使用者的個人基礎設施，無多租戶、無帳號系統 |
| 認證 | 單一共享 `API_TOKEN`（Bearer）；房間身分用 `X-Participant-Id` |
| 真相來源 | Hub 伺服器。Client 端**不做離線編輯佇列**，只做讀取快取 |
| cursor | 房內遞增 `seq`（整數），**絕不使用 timestamp 排序或去重** |

**不做 Flutter Web 的理由（奈留）**：server 端 `create_app()` 完全沒有掛
`CORSMiddleware`，Web 版第一個 preflight 就會死；而且 Web 上
`flutter_secure_storage` 只是 localStorage 包裝，token 等同明碼。
若日後真要 Web，那是 server 端該補的事，不是 UI 層繞得掉的。

---

## 1. 選型與理由

### 1.1 狀態管理 → **Riverpod**（`flutter_riverpod` + `riverpod_annotation` codegen）

**結論：用 Riverpod，不用 Bloc。**

這個 app 的狀態本質是「一條 WebSocket 串流 + 數個 REST 查詢，合流成 per-room 的訊息快照」，
不是「使用者操作驅動的狀態轉移」。Riverpod 的三個特性直接命中需求：

1. **`family` 參數化 provider**：`messagesProvider(roomId)` 天生就是「每個房間一份獨立狀態」，
   不需要像 Bloc 那樣手動管理 `Map<roomId, Bloc>` 的生命週期。
2. **`autoDispose` + `ref.keepAlive()`**：離開聊天畫面自動退訂房間、釋放記憶體，
   這正是 P3-04 驗收條件 3「前背景切換不造成連線洩漏」最省力的解法。
   用 Bloc 得自己在 `dispose` 裡追每一條 subscription。
3. **provider 間相依可宣告**：`connectionStateProvider` → `wsClientProvider` →
   `messagesProvider`，任一層變動自動向下傳播，重連後的補訊觸發不用手寫膠水。

Bloc 的 event/state 樣板在「使用者互動複雜、需要嚴格可追蹤的狀態轉移」時值回票價；
本 app 的互動面積小（發訊息、釘選、刪除、建立房間），為此付出每個功能三個檔案的成本不划算。
`setState` / `ChangeNotifier` 則在多房間訂閱與跨畫面共享時會迅速失控，直接排除。

> 奈也：Riverpod 讓「房間列表」跟「聊天視窗」共用同一份快取的手感很自然，
> 從列表點進去不會閃一下空白再載入。
>
> 奈留：唯一代價是 codegen（`build_runner`）進了工具鏈。接受——
> 手寫 provider 型別在 `family` + `AsyncNotifier` 疊起來時可讀性極差，
> 這筆技術債換得的型別安全是正收益。

**版本策略**：使用 Riverpod 3.x。P3-02 時鎖定 `pubspec.yaml` 的 minor 版本
（`^3.0.0` 而非 `any`），並提交 `pubspec.lock`。

### 1.2 路由 → **go_router**

宣告式路由，官方維護。選它的實質理由是 **ShellRoute**：桌機版要「左側房間列表 + 右側聊天區」
的雙欄佈局，手機版要「列表 push 進聊天」的堆疊佈局——用 ShellRoute 可以讓兩者共用同一組
路由定義，只在 shell 的 builder 裡依 `MediaQuery` 切換佈局，不需要兩套導航邏輯。

次要理由：URL 形式的路由（`/rooms/:roomId/pinned`）讓「從釘選牆跳回原文位置」
這類跨畫面跳轉可以用參數表達（`/rooms/:roomId?focusSeq=42`），而不是傳一堆物件。

### 1.3 HTTP → **dio**

選 dio 而非 `package:http`，理由集中在 **Interceptor**：

- 每個請求都要塞 `Authorization: Bearer <token>`，房內操作還要塞 `X-Participant-Id`。
  用 interceptor 集中處理，API 方法本體乾淨。
- 401/403/404/409 → app 層例外的轉譯（P3-03 驗收條件 2）在 `onError` 一處完成，
  不必在 30 個方法裡各寫一次 `if (res.statusCode == 409)`。
- 統一的 `connectTimeout` / `receiveTimeout` 設定，以及 token 遮蔽的 log interceptor
  （P3-02 驗收條件 4：token 不出現在任何 log）。

`package:http` 要達到同樣效果得自己包一層 client，等於重寫 dio 的一小部分。

### 1.4 WebSocket → **web_socket_channel**

Dart 團隊維護，`WebSocketChannel.connect()` 在 Windows / Android 都走原生實作。
Server 的 `/ws` 是純 JSON text frame 協定（`subscribe` / `unsubscribe` / `ping`），
沒有 Socket.IO / STOMP 之類的分層協定，套 `socket_io_client` 只會多一層不相容的握手。

**重連不用第三方套件**：`web_socket_channel` 本身不含重連。市面上的
auto-reconnect 包裝套件都沒有「重連後帶 `after_seq` 補訊」這個領域概念，
硬套反而綁手。§4 的狀態機自己寫，約 200 行，可完整單元測試。

### 1.5 本機儲存 → **flutter_secure_storage**（機密）+ **shared_preferences**（其餘）

分兩層，界線清楚：

| 套件 | 存什麼 | 理由 |
|------|--------|------|
| `flutter_secure_storage` | `api_token`、`device_session_key` | Windows 走 DPAPI、Android 走 EncryptedSharedPreferences。token 是唯一的認證憑據，落地必須加密 |
| `shared_preferences` | `server_url`、主題模式、上次開啟的房間、最近使用的 session_key 清單 | 非機密、讀取頻繁；secure storage 每次讀取都有加解密成本，不該拿來存 UI 偏好 |

`device_session_key` 放 secure storage 的理由見 §6——它不是機密，但它必須與
`api_token` 有相同的生命週期（一起被清除），放在一起管理最不容易出錯。

**P3-01 完成後必須驗證**：`flutter_secure_storage` 的 Windows 實作需要
`windows` platform 支援，若 `flutter doctor` 的 Visual Studio toolchain 不完整會編不過。
這是 P3-02 的第一個實質風險，建議在專案骨架建好的當天就跑一次
「寫入 → 重啟 → 讀回」的手動驗證。

### 1.6 Markdown 渲染 → **flutter_markdown_plus**（首選）/ **markdown_widget**（備選）

訊息的 `content` 欄位是 Markdown（`PLANNING.md` §3）。需求範圍很窄：
粗體、清單、行內程式碼、程式碼區塊（P3-06 驗收條件 4），不需要表格編輯或 HTML 內嵌。

**注意**：官方的 `flutter_markdown` 已由 Flutter 團隊標記為停止維護，
不應用於新專案。`flutter_markdown_plus` 是保持 API 相容的社群延續版本，
遷移成本最低；`markdown_widget` 是另一條路，內建目錄與程式碼高亮，但 API 不相容。

> **P3-02 施工時必須做的第一件事**：到 pub.dev 覆核這兩個套件的當下維護狀態與
> Flutter SDK 相容性，再定案。本文件給的是方向，不是免驗證的結論。

程式碼區塊高亮另外掛 `flutter_highlight`（或使用 `markdown_widget` 內建）。
**安全限制**：一律關閉 HTML 內嵌渲染（`selectable: true`, 不啟用 raw HTML），
訊息內容來自 agent，不該有能力注入任意 widget。

### 1.7 其他

| 用途 | 套件 | 一句話理由 |
|------|------|-----------|
| 資料模型 / JSON | `freezed` + `json_serializable` | 不可變模型 + `copyWith` + 自動 `==`，是 seq 去重與 UI diff 的基礎 |
| 連線偵測 | `connectivity_plus` | §4 重連的關鍵：網路恢復時**立即中斷退避等待**，否則會卡在 30 秒的退避裡（P3-04 驗收條件 1 的 5 秒門檻靠這個達成） |
| 生命週期 | `WidgetsBindingObserver`（SDK 內建） | 前背景切換時暫停/恢復 WS，不需第三方 |
| UUID | `uuid` | 產生 `device_session_key` |
| 日誌 | `logging`（SDK 官方） | 搭配一個遮蔽 filter，確保 token 不外洩 |

---

## 2. 資料夾結構

```
app/
├─ pubspec.yaml
├─ analysis_options.yaml          # 開啟 flutter_lints + 自訂規則（禁 print）
├─ lib/
│  ├─ main.dart                   # ProviderScope + App 啟動
│  ├─ app.dart                    # MaterialApp.router / 主題 / go_router 綁定
│  │
│  ├─ core/                       # 不依賴任何上層的基礎設施
│  │  ├─ config/
│  │  │  ├─ app_settings.dart     # server_url / token / 主題 的讀寫（Settings repo）
│  │  │  └─ secure_store.dart     # flutter_secure_storage 薄封裝
│  │  ├─ errors/
│  │  │  └─ api_exception.dart    # ApiException 家族（見 §3.4）
│  │  ├─ logging/
│  │  │  └─ redacting_logger.dart # token 遮蔽
│  │  └─ identity/
│  │     └─ device_identity.dart  # device_session_key 產生與存放（見 §6）
│  │
│  ├─ models/                     # 純資料，無任何 I/O 依賴
│  │  ├─ room.dart                # Room（含 member_count / status / activated_at）
│  │  ├─ participant.dart         # Participant
│  │  ├─ message.dart             # Message（seq / kind / pinned / deleted / mentions）
│  │  ├─ assignment.dart          # Assignment
│  │  └─ ws_event.dart            # WsEvent sealed class（messages / pong）
│  │
│  ├─ api/                        # REST 層（P3-03）
│  │  ├─ api_client.dart          # dio 實例 + interceptors（auth / 錯誤轉譯 / log）
│  │  ├─ rooms_api.dart           # 房間 / 成員 / heartbeat
│  │  ├─ messages_api.dart        # 訊息讀寫 / pin / delete
│  │  └─ assignments_api.dart     # 指派
│  │
│  ├─ ws/                         # 即時層（P3-04）
│  │  ├─ ws_client.dart           # 單一 socket 連線；send/receive 原語
│  │  ├─ ws_protocol.dart         # 指令與事件的 encode/decode（協定唯一定義處）
│  │  ├─ reconnect_policy.dart    # 純函式退避計算，可單測
│  │  └─ realtime_service.dart    # 狀態機 + 訂閱管理 + REST 補訊編排（§4 核心）
│  │
│  ├─ state/                      # Riverpod providers
│  │  ├─ settings_provider.dart
│  │  ├─ connection_provider.dart # ConnectionState 對外可觀察
│  │  ├─ rooms_provider.dart      # 房間列表 AsyncNotifier
│  │  ├─ room_detail_provider.dart# family(roomId)：房間 + 成員
│  │  ├─ messages_provider.dart   # family(roomId)：訊息 store（§3.3 的核心）
│  │  ├─ identity_provider.dart   # family(roomId)：本機人類的 participant_id
│  │  └─ assignments_provider.dart
│  │
│  ├─ screens/                    # 一個畫面一個資料夾
│  │  ├─ settings/settings_screen.dart
│  │  ├─ rooms/room_list_screen.dart
│  │  ├─ chat/chat_screen.dart
│  │  ├─ pinned/pinned_wall_screen.dart
│  │  ├─ assignments/assignment_screen.dart
│  │  └─ shell/app_shell.dart     # 桌機雙欄 / 手機堆疊 的分流
│  │
│  └─ widgets/                    # 可跨畫面複用、無業務邏輯
│     ├─ message_bubble.dart
│     ├─ system_message_tile.dart
│     ├─ markdown_body.dart       # Markdown 套件的唯一接觸點（換套件只改這裡）
│     ├─ mention_field.dart       # @ 自動完成輸入框
│     ├─ connection_banner.dart   # 連線狀態橫幅
│     └─ empty_error_states.dart  # 空狀態 / 錯誤狀態（中文文案集中處）
└─ test/
   ├─ api/                        # mock dio adapter
   ├─ ws/                         # reconnect_policy 與狀態機的純邏輯測試
   └─ state/                      # ProviderContainer 測試
```

### 各層職責與依賴方向

```
screens ──► widgets
   │           │
   ▼           ▼
 state ──────────────► models
   │
   ├──► api ──► core
   └──► ws  ──► core
```

**依賴方向是單向的，任何反向 import 都視為錯誤**：

| 層 | 可以 import | 絕對不可以 |
|----|------------|-----------|
| `models` | 無（只有 freezed/json 註解） | 任何其他層 |
| `core` | `models` | `api` / `ws` / `state` / `screens` |
| `api` | `core`, `models` | `state`, `ws`, `screens`, `flutter/material.dart` |
| `ws` | `core`, `models`, `api`（補訊需要 REST） | `state`, `screens`, `flutter/material.dart` |
| `state` | `core`, `models`, `api`, `ws` | `screens`, `widgets` |
| `widgets` | `models`（顯示用）, `state`（僅讀） | `api`, `ws` |
| `screens` | 全部 | — |

> 奈留：`api` 與 `ws` **不得 import `package:flutter/material.dart`**。
> 這條規則的價值在於它讓整個資料層可以用純 `dart test` 跑，
> 不需要 `flutter_test` 的 widget binding，測試速度差一個量級。
> 建議在 `analysis_options.yaml` 用 `import` lint 規則機械化這條約束，別靠自律。

---

## 3. 資料流設計

### 3.1 全景

```
                         ┌──────────────────────────────┐
                         │        Chatroom Hub          │
                         └───┬──────────────────────┬───┘
                REST         │                      │   WebSocket /ws
        (歷史 / 補訊 / 寫入)  │                      │  (即時新訊息推播)
                             ▼                      ▼
                     ┌──────────────┐      ┌──────────────────┐
                     │  api/*_api   │◄─────│ realtime_service │
                     └──────┬───────┘      └────────┬─────────┘
                            │  Message 列表          │ WsEvent 串流
                            └───────────┬────────────┘
                                        ▼
                          ┌───────────────────────────┐
                          │ messagesProvider(roomId)  │
                          │  ┌─────────────────────┐  │
                          │  │ SplayTreeMap        │  │  ← 以 seq 為鍵，天然排序 + 去重
                          │  │   <int seq, Message>│  │
                          │  ├─────────────────────┤  │
                          │  │ lastAppliedSeq      │  │  ← 送給 server 的 after_seq
                          │  │ oldestLoadedSeq     │  │  ← 往上捲的邊界
                          │  │ hasMoreHistory      │  │
                          │  └─────────────────────┘  │
                          └─────────────┬─────────────┘
                                        ▼
                              ChatScreen / PinnedWall
```

**核心設計：REST 與 WS 都寫進同一個 store，走同一條 upsert 路徑。**
兩者的差異只在「誰觸發」，不在「怎麼寫」。這樣重連補訊、冷啟動載入、
往上捲歷史三個場景共用同一份合併邏輯，不會出現三套各自為政的 bug。

### 3.2 訊息 store 的 upsert 契約

```dart
/// 唯一的訊息寫入入口。REST 與 WS 都必須走這裡。
void upsertAll(Iterable<Message> incoming) {
  for (final m in incoming) {
    _bySeq[m.seq] = m;   // ← 覆寫，不是 skip
  }
  _recomputeCursors();
}
```

**必須是「覆寫」而不是「已存在就跳過」**，這是最容易寫錯的一點：

server 的 WS pump 與 REST 回傳的是**訊息當下的完整快照**，
包含 `pinned` 與 `deleted` 的最新值。同一個 `seq` 第二次到達時，
內容可能已經被別的 client 釘選或軟刪除了。若寫成 `putIfAbsent`，
P3-08 驗收條件 2（釘選即時同步到其他 client）會直接失敗。

去重的正確性由 **`(room_id, seq)` 的唯一性**保證（server schema 有
`UNIQUE(room_id, seq)`），`SplayTreeMap<int, Message>` 用 seq 當鍵，
去重與排序一次解決，不需要額外的 `Set<String> seenIds`。

**絕不用 `id` 去重、絕不用 `created_at` 排序**：訊息 id 是 uuid 無序，
`created_at` 有同秒衝突與時鐘偏移風險——這正是 `PLANNING.md` §8 選 seq 的原因。

### 3.3 兩個 cursor 的定義與管理

| cursor | 定義 | 用途 | 更新時機 |
|--------|------|------|---------|
| `lastAppliedSeq` | **已連續套用的最大 seq**（連續前綴的尾端） | 送給 WS `subscribe.after_seq` 與 REST `after_seq` | 每次 upsert 後重算 |
| `oldestLoadedSeq` | store 中最小的 seq | 往上捲載入歷史的邊界 | 每次 upsert 後重算 |

**`lastAppliedSeq` 必須是「連續前綴」而非「最大值」。** 說明：

```
store 中有 seq = [1,2,3,4, 7,8]     ← 5,6 因某次分頁截斷缺失
  max     = 8   ← 用這個當 after_seq，5 和 6 永遠補不回來 ✗
  連續前綴 = 4   ← 用這個，下次 after_seq=4 會把 5..8 全部帶回，
                   7,8 因 upsert 覆寫而不重複                  ✓
```

實作：

```dart
int _computeLastAppliedSeq() {
  // baseSeq：本次會話已知的起點（冷啟動時為 firstLoadedSeq - 1）
  var s = _baseSeq;
  while (_bySeq.containsKey(s + 1)) { s++; }
  return s;
}
```

代價是重複傳輸幾則訊息，換來的是「無遺漏」的硬保證。
在單使用者、房內訊息量以千計的規模下，這個代價可以忽略。

> 奈留：如果哪天覺得重傳礙眼想改成 max，先回來重讀這一段。
> P3-04 驗收條件 1 寫的是「無重複**無遺漏**」，遺漏比重複嚴重得多。

### 3.4 錯誤轉譯契約（P3-03 驗收條件 2）

Server 的 `HTTPException` 一律回 `{"detail": "..."}`。轉譯表：

| HTTP | 例外型別 | 語意 | UI 中文提示 |
|------|---------|------|------------|
| 401 | `AuthException` | token 錯誤 / 缺 `X-Participant-Id` | 「API token 無效，請至設定檢查」 |
| 403 | `ParticipantInvalidException` | participant 非 active，或不屬於此房 | 「你的房間身分已失效，正在重新加入…」→ **觸發自動 re-join**（見 §6.4） |
| 404 | `NotFoundException` | 房間 / 訊息 / 指派不存在 | 「找不到指定的房間或訊息」 |
| 409 | `RoomArchivedException` | 房間已封存（唯讀） | 「此聊天室已封存，無法發言」→ 停用輸入區與管理操作 |
| 逾時 / socket | `NetworkException` | 連不上 Hub | 「無法連線到 Hub，請確認伺服器位址」 |
| 其他 5xx | `ServerException` | — | 「伺服器發生錯誤（HTTP {code}）」 |

401 與 403 語意不同，**不可合併處理**：401 是設定問題（要跳設定頁），
403 是身分過期（要靜默重新 join）。混在一起會讓使用者在正常的閒置回來場景
被踢到設定畫面。

---

## 4. WebSocket 重連演算法（P3-04 核心）

### 4.1 連線狀態機

```
                    ┌──────────────┐
      app 啟動 /     │ disconnected │◄──────── 使用者手動離線 / 設定變更
      設定完成 ──────►└──────┬───────┘          / token 錯誤(4401)
                            │ connect()
                            ▼
                    ┌──────────────┐   握手失敗 / socket error
                    │  connecting  ├────────────────────┐
                    └──────┬───────┘                    │
                           │ onOpen                     ▼
                           ▼                    ┌────────────────┐
                    ┌──────────────┐  斷線/     │  reconnecting  │
                    │   syncing    │  pong逾時  │  (退避等待中)   │
                    │ (REST 補訊中) ├───────────►└───────┬────────┘
                    └──────┬───────┘                    │ 退避到期
                           │ 補訊完成                     │ 或 網路恢復
                           ▼                            │ 或 回到前景
                    ┌──────────────┐                    │
                    │  connected   ├────────────────────┘
                    └──────────────┘
```

對 UI 曝露的狀態（P3-04 驗收條件 2）合併為三種，`connection_banner.dart` 據此顯示：

| 對外狀態 | 內部狀態 | 橫幅 |
|---------|---------|------|
| 連線中 | `connecting` / `syncing` | 「連線中…」（`syncing` 時顯示「正在補齊訊息…」） |
| 已連線 | `connected` | 不顯示橫幅 |
| 重連中 | `reconnecting` | 「連線中斷，{n} 秒後重試」+ 立即重試按鈕 |
| 離線 | `disconnected` | 「已離線」+ 連線按鈕 |

```dart
sealed class RealtimeStatus {}
class Disconnected  extends RealtimeStatus { final String? reason; }
class Connecting    extends RealtimeStatus {}
class Syncing       extends RealtimeStatus { final int roomsRemaining; }
class Connected     extends RealtimeStatus { final DateTime since; }
class Reconnecting  extends RealtimeStatus {
  final int attempt;
  final Duration delay;
  final DateTime retryAt;   // ← UI 倒數用
}
```

### 4.2 指數退避參數

```dart
// reconnect_policy.dart —— 純函式，可完整單元測試
const baseDelay   = Duration(milliseconds: 300);
const factor      = 2.0;
const maxDelay    = Duration(seconds: 30);
const jitterRatio = 0.25;              // ±25% full jitter

Duration delayFor(int attempt) {       // attempt 從 0 起算
  final raw = baseDelay * pow(factor, attempt);
  final capped = raw > maxDelay ? maxDelay : raw;
  final j = capped.inMilliseconds * jitterRatio;
  return Duration(
    milliseconds: (capped.inMilliseconds + _rng.nextDouble() * 2 * j - j).round(),
  );
}
```

退避序列（未加 jitter）：`0.3s → 0.6s → 1.2s → 2.4s → 4.8s → 9.6s → 19.2s → 30s（封頂）`

**三個必須立即取消退避、重置 `attempt = 0` 並馬上重連的事件**：

1. `connectivity_plus` 回報網路由「無」轉為「有」
2. App 由背景回到前景（`AppLifecycleState.resumed`）
3. 使用者按下橫幅上的「立即重試」

> 這三條是 P3-04 驗收條件 1（「斷網後恢復，5 秒內自動重連」）能不能過的關鍵。
> 純靠退避計時器，若斷線已久退到 30 秒檔位，網路恢復後最壞要等 30 秒——直接不合格。
> 奈留：這是唯一一個「不能只實作退避就交卷」的地方，寫的時候別偷懼。

**其他必須遵守的規則**：

- `attempt` 只在**成功握手並完成 syncing** 後才重置為 0。
  單純 `onOpen` 就重置會導致「連上立刻斷」的壞伺服器狀態下退避失效，變成緊迫迴圈。
- 收到 `close code 4401`（server 的 token 驗證失敗）→ **直接進 `disconnected`，不重連**。
  重連只會用同一個錯 token 撞牆。UI 導向設定畫面。
- 進背景時：Android 上主動 `close()` 並轉 `disconnected(reason: background)`；
  Windows desktop 不處理（視窗最小化不算背景）。回前景時重連並走完整補訊流程。

### 4.3 應用層心跳與半開連線偵測

Server 只在收到 `{"type":"ping"}` 時回 `{"type":"pong"}`，**不會主動發送**。
TCP 半開連線（拔網路線、NAT 逾時）在 client 端不會觸發 `onDone`，
可能靜默地永遠收不到訊息。因此 client 必須自己探測：

```
每 20 秒送 {"type":"ping"}
  ├─ 10 秒內收到 {"type":"pong"} → 正常，重置計時
  └─ 10 秒內未收到              → 判定連線已死
                                  → close() → reconnecting（attempt 不重置）
```

Windows / Android 上不要依賴 WebSocket 協定層的 ping frame——
`web_socket_channel` 不保證跨平台曝露該事件。用應用層 ping 是唯一可靠的做法。

### 4.4 斷線期間的 REST 補訊流程

**設計原則：WS `subscribe.after_seq` 本身就會補訊**（server 的 `pump()` 從
`after_seq` 開始查，每批最多 200 則、連續發送直到追平）。但我們仍然先走 REST，
理由有三：

1. 補訊有明確的**完成時點**，才能把 `syncing → connected` 的狀態轉移做對，
   UI 才知道何時可以收起「正在補齊訊息」；WS 推播是無界串流，無法判定「補完了」。
2. REST 可控制批次大小與進度回報，大量補訊時不會讓 UI 一次收到數百則而卡頓。
3. REST 失敗有明確的 HTTP 錯誤碼（如 404 房間已刪、409），
   WS 上這些狀況只會表現為靜默無回應。

**完整流程**：

```
[1] 握手成功（onOpen）→ status = syncing
     │
     ▼
[2] for each 訂閱中的 roomId（並行，上限 3 條並行避免打爆 Hub）:
     │   cursor = store(roomId).lastAppliedSeq
     │   loop:
     │     GET /api/rooms/{roomId}/messages?after_seq={cursor}&limit=200
     │     ├─ 回傳空陣列        → 補齊，跳出
     │     ├─ 回傳 < 200 則     → upsertAll(msgs); cursor = 新的 lastAppliedSeq; 跳出
     │     └─ 回傳 == 200 則    → upsertAll(msgs); cursor = 新的 lastAppliedSeq; 繼續 loop
     │   ※ 迴圈上限 50 圈（= 10000 則）的保險絲，超過則放棄補訊、
     │     清空該房 store 並改為「從最新開始」重新載入，避免無限迴圈
     │
     ▼
[3] 補訊完成後，對每個房間送出：
     {"type":"subscribe","room_id":"...","after_seq": <補完的 lastAppliedSeq>}
     │
     │  ← 這裡刻意用補完後的 cursor 而非 0，讓 server 端 pump 不重推歷史。
     │     即使 [2] 與 [3] 之間有新訊息插入（競態），pump 會從 after_seq
     │     開始補，一則都不會漏；重疊的部分由 upsert 覆寫吸收。
     ▼
[4] 一併重新拉取房間中繼資料（成員名單 / room.status），
     因為斷線期間可能發生「成員被 sweeper 移除」或「房間被自動封存」，
     這些狀態變化雖然有對應的 system 訊息會經由 [2] 補回，
     但 participants 清單與 room.status 欄位本身需要 GET /api/rooms/{id} 才會更新
     │
     ▼
[5] status = connected；啟動心跳計時器
```

**競態安全性論證（奈留）**：步驟 [2] 與 [3] 之間若有新訊息 seq=N 產生，
會發生兩件事之一——(a) 它落在 [2] 最後一批之後，則 [3] 的 `subscribe.after_seq`
小於 N，pump 會推它；(b) 它已被 [2] 拉到，則 `lastAppliedSeq >= N`，
pump 不重推。兩種情況都不遺漏。**前提是 [3] 的 after_seq 必須來自 [2] 完成後
重新讀取的 store 值，而不是 [2] 開始前快取的變數。** 這是實作時最容易寫錯的一行。

### 4.5 訂閱管理

`realtime_service` 維護 `Map<String roomId, int refCount>`：

- `messagesProvider(roomId)` 建立時 → `subscribe(roomId)`，refCount++
- provider `autoDispose` 觸發時 → refCount--，歸零則送 `unsubscribe` 並延遲 30 秒才真正
  移除本機 store（使用者在房間之間來回切換時不必重新載入）
- 重連後只重新 subscribe **refCount > 0** 的房間

server 端 `pumps` 是 `dict[room_id, Task]`，重複 `subscribe` 同一房間會被忽略
（`if rid not in pumps`），所以 client 端的重複訂閱是安全的；但 `unsubscribe`
會直接 cancel task，因此 refCount 必須準確，否則會誤退訂還在看的房間。

---

## 5. 畫面與導航圖

### 5.1 導航關係

```
                            ┌──────────────────┐
     首次啟動 / 設定不完整 ──►│ SettingsScreen   │
                            │   /settings      │
                            └────────┬─────────┘
                                     │ 連線測試通過
                                     ▼
              ┌──────────────────────────────────────────┐
              │             AppShell  (ShellRoute)        │
              │  桌機：左欄房間列表 + 右欄內容              │
              │  手機：單欄，列表 push 進內容               │
              └───┬──────────────────────────────────┬────┘
                  │                                  │
    ┌─────────────▼─────────────┐      ┌─────────────▼──────────────┐
    │     RoomListScreen        │      │       ChatScreen           │
    │     /rooms                │─────►│  /rooms/:roomId            │
    │  ・active / archived 切換  │      │  ?focusSeq=<int>           │
    │  ・建立房間（Dialog）       │      └──┬──────────┬──────────┬───┘
    │  ・封存 / 解封（滑動操作）   │         │          │          │
    └───────────┬───────────────┘         │          │          │
                │                          │          │          │
                │              ┌───────────▼──┐  ┌────▼─────┐   │
                │              │ PinnedWall   │  │ Members  │   │
                │              │ /rooms/:id/  │  │ Panel    │   │
                │              │   pinned     │  │(側欄/BS) │   │
                │              └──────┬───────┘  └──────────┘   │
                │                     │ 點擊「跳回原文」          │
                │                     └────────────────────────►┘
                │                       導回 /rooms/:id?focusSeq=N
                ▼
    ┌───────────────────────────┐
    │  AssignmentScreen         │
    │  /rooms/:roomId/assign    │   ← 從房間列表的 overflow menu 進入
    └───────────────────────────┘
```

### 5.2 各畫面 widget 層級

#### SettingsScreen（P3-02）

```
Scaffold
└─ ListView
   ├─ TextField(server URL)         ・預填 http://127.0.0.1:8787
   ├─ TextField(API token)          ・obscureText，右側眼睛圖示可切換顯示
   ├─ FilledButton「測試連線」        ・GET /api/health
   ├─ _ConnectionTestResult          ・成功 / token 錯誤(401) / 連不上，各自中文提示
   ├─ Divider
   ├─ SwitchListTile(深色主題)
   └─ ListTile「本機裝置識別」         ・顯示 device_session_key（可複製、可重新產生）
```

#### RoomListScreen（P3-05）

```
Scaffold
├─ AppBar
│  ├─ title「聊天室」
│  ├─ SegmentedButton[進行中 | 已封存]      ← 切 status=active/archived
│  └─ IconButton(設定)
├─ body: RefreshIndicator              ← 下拉刷新（驗收條件 1）
│         └─ AsyncValue.when(
│              loading  → ListView.skeleton
│              error    → ErrorState(中文訊息 + 重試)
│              data     → ListView.builder
│                          └─ RoomTile
│                             ├─ 房名 + status chip
│                             ├─ topic（單行省略）
│                             ├─ 成員數 icon + 最後活動時間（相對時間）
│                             └─ 未讀點（本機 lastReadSeq < room 最新 seq 時顯示）
│                             ・長按 / 滑動 → 封存 / 解封 / 指派
└─ FAB「建立房間」→ Dialog(name, topic)
```

**「最後活動時間」的資料來源問題見 §7 R-3**——`GET /api/rooms` 沒有回傳
最新訊息的時間，需要在 P3-05 開工前確認補法。

#### ChatScreen（P3-06 / P3-07 / P3-08）

```
Scaffold
├─ AppBar
│  ├─ 房名 + 成員數
│  ├─ ConnectionBanner（狀態非 connected 時撐開）
│  └─ actions: [釘選牆, 成員, 指派, overflow]
├─ body: Stack
│  ├─ ListView.builder(reverse: true)        ← reverse 讓「貼底」成為預設
│  │   itemBuilder:
│  │     ├─ kind == 'system' → SystemMessageTile
│  │     │                      ・置中、灰底膠囊、小字（驗收條件 3）
│  │     └─ kind == 'chat'   → MessageBubble
│  │                            ├─ 發送者名 + 相對時間 + kind 徽章(claude/codex/human)
│  │                            ├─ ReplyQuote（reply_to 非 null 時，顯示原文摘要）
│  │                            ├─ MarkdownBody(content)
│  │                            │   ・deleted == true → 「訊息已刪除」灰字占位
│  │                            ├─ MentionChips（mentions 非空）
│  │                            └─ 長按 → 釘選 / 取消釘選 / 複製 / 回覆 / 刪除
│  │   ・頂端 sentinel 進入視窗 → 載入更舊的歷史（見 §7 R-1）
│  │   ・focusSeq 參數存在時 → 捲到該 seq 並高亮 1.5 秒
│  ├─ Positioned(bottom): _NewMessagesPill
│  │     ・使用者不在底部時，新訊息不強制捲動，改顯示
│  │       「有 N 則新訊息 ↓」（驗收條件 2）
│  └─ Positioned(top): PinnedStrip（有釘選訊息時顯示最新一則，點擊進釘選牆）
└─ bottomNavigationBar: MessageComposer
   ├─ ReplyPreview（回覆中時顯示，可取消）
   ├─ MentionField
   │   ・輸入 @ → OverlayPortal 顯示房內 active 成員清單（驗收條件 2）
   │   ・選取後在文字插入 @Name 並記錄到待送的 mentions 清單
   └─ IconButton(送出)
   ・room.status == 'archived' → 整條停用，改顯示「此聊天室已封存」
```

#### PinnedWallScreen（P3-08）

```
Scaffold(AppBar「釘選訊息」)
└─ ListView
   └─ PinnedCard          ← 資料來自 GET /messages?pinned_only=true，
      ├─ MessageBubble(唯讀)   再於 client 過濾掉 deleted == true
      ├─ TextButton「跳回原文」→ go('/rooms/:id?focusSeq=${msg.seq}')
      └─ IconButton「取消釘選」 ← archived 房間停用
```

#### AssignmentScreen（P3-09）

```
Scaffold(AppBar「指派 agent」)
└─ Column
   ├─ Card「新增指派」
   │  ├─ Autocomplete(target_session_key)
   │  │   ・選項來自 shared_preferences 的「最近見過的 session_key」清單，
   │  │     由 GET /api/rooms/{id} 的 participants 累積（減少手抄 uuid）
   │  ├─ TextField(note)
   │  └─ FilledButton「送出指派」
   └─ 「本房間的指派」列表 + status chip(pending/accepted/declined/expired)
      ・資料來源問題見 §7 R-2
```

---

## 6. 人類身分處理

### 6.1 device_session_key 的產生與存放

Server 的 `participant.session_key` 對 agent 是「跨房間穩定的 session 識別」，
對人類則是「裝置識別」（`PLANNING.md` §3）。設計如下：

```dart
// core/identity/device_identity.dart
const _kDeviceKeyStorageKey = 'chatroom.device_session_key';

Future<String> ensureDeviceSessionKey() async {
  final existing = await secureStore.read(_kDeviceKeyStorageKey);
  if (existing != null && existing.isNotEmpty) return existing;
  final generated = 'human-${const Uuid().v4().replaceAll('-', '')}';
  await secureStore.write(_kDeviceKeyStorageKey, generated);
  return generated;
}
```

**明確不使用平台裝置 ID**（`device_info_plus` 的 Android ID / Windows machine GUID）。
理由：(a) Android 10+ 的 ANDROID_ID 已按 app 簽章隔離、重裝即變，穩定性不比自產 UUID 好；
(b) 平台 ID 是可跨 app 關聯的識別碼，用它當聊天室身分是不必要的資訊外洩；
(c) 自產 UUID 讓使用者可以主動「重新產生身分」（設定畫面提供此操作），
在 session_key 被誤用或想切換身分時有出路。

`human-` 前綴讓 Hub 端的 assignment 列表一眼可辨，不會誤把人類 key 當成 agent 派工目標。

### 6.2 join 流程（P3-07）

```
使用者首次進入某房間的 ChatScreen
  │
  ▼
identityProvider(roomId) 讀本機快取 Map<roomId, participantId>
（存 shared_preferences，key: 'participant.$roomId'）
  │
  ├─ 有快取 → 直接使用，並在背景送一次 heartbeat 驗證
  │            └─ heartbeat 回 403 → 快取失效，走下面的 join 路徑
  │
  └─ 無快取 → POST /api/rooms/{roomId}/join
              {
                "kind": "human",
                "session_key": <device_session_key>,
                "role": "human",              ← 必填，預設值是 'agent'，漏了會被 sweeper 掃掉
                "preferred_name": <使用者暱稱 或 省略>
              }
              → { participant_id, display_name, rejoined }
              → 存入快取，寫入 identityProvider
```

**`role: "human"` 是不可遺漏的欄位。** Server 的 `JoinRequest.role`
預設值是 `"agent"`，而 sweeper 的 SQL 是
`WHERE status='active' AND role='agent' AND last_seen_at < cutoff`。
若送成 agent，使用者閒置 10 分鐘就會被踢出房間——P3-07 驗收條件 5
（人類身分不會被 sweeper 移除）直接失敗。**這一行寫進 code review 檢查清單。**

同理，`kind` 送 `"human"`（用於 UI 上的徽章顯示），與 `role` 是兩個獨立欄位，別搞混。

### 6.3 join 的冪等性

Server 的 `join_room` 對「同 room + 同 session_key + status='active'」的情況
會直接回傳既有身分並標記 `rejoined: true`，**不會產生重複的 participant，
也不會重複廣播「XXX 加入了聊天室」的 system 訊息**。

因此 client 端可以放心地把 join 當成**冪等的身分取得操作**：
快取遺失、重裝 app、切換裝置後重新 join，都不會污染訊息串。
這也意味著 client 端**不需要**在 join 前先查詢自己是否已在房內。

### 6.4 身分失效的自動復原

人類不會被 sweeper 移除，但仍有兩種失效途徑：
使用者自己按了「離開房間」（status → `left`），或資料庫被重置。
兩者都表現為後續 API 回 **403**。

處理：`api_client` 的 error interceptor 捕捉 403 → 拋 `ParticipantInvalidException`
→ `identityProvider` 清除該房快取 → 自動重新 join → **重試原請求一次**。
重試仍失敗則向上拋出，顯示「無法取得房間身分」。

**只重試一次**，避免 join 本身出錯時進入無限迴圈。

### 6.5 heartbeat 策略

人類不受閒置移除影響，因此 heartbeat **不是為了保命，而是為了讓其他 agent
在成員清單上看到「人類在線」**。策略：

- ChatScreen 在前景且該房間為當前檢視 → 每 **60 秒**送一次
  `POST /api/rooms/{id}/heartbeat`
- 離開畫面 / 進背景 → 停止
- 不對非當前檢視的房間送 heartbeat

（不要為了保險而縮短到 10 秒——`_participant()` 每次都會 `UPDATE` + `commit`，
在 SQLite 上是實質寫入，沒必要為零收益的操作增加寫入壓力。）

---

## 7. 風險與開放問題

> **⚠️ 2026-08-28 更新（諾薇亞）：R-1 ~ R-5 已全數在 server 端補完**
> （commit 82cd247 前後）：`before_seq` 反向翻頁、`GET /api/rooms/{id}/assignments`、
> 房列表 `last_seq`/`last_activity_at`、`update_seq` 推播（釘選/刪除領新序號，
> WS pump 掃 `MAX(seq, update_seq)`）、`reply_preview`。以下原文僅留存歷史脈絡。
>
> **同時作廢 §3.3 的「連續前綴」cursor 演算法**：`update_seq` 與訊息 `seq`
> 共用 `room.next_seq` 計數器，seq 天生有洞，連續前綴會在洞上永遠卡住。
> 實作（`ws/room_feed.dart`）改用 `max(seq, update_seq)` 的最大值，
> 與 long-poll 的 `last_seq` 同語意；舊訊息的狀態更新由 WS pump 補回。

> 前四項是**在讀 `app.py` 時發現的 server 端契約缺口**，
> 不是 UI 層能自己解決的。建議在對應的 P3 卡開工前先確認補法，
> 否則會出現「UI 寫好了但驗收條件過不了」的窘境。

### R-1（高）`GET /messages` 沒有 `before_seq`，往上捲歷史無法實作

- **現況**：`read_messages` 只接受 `after_seq` + `limit`，且 `ORDER BY seq` 升序。
  這是「從舊往新讀」的語意，天生服務 agent 的 long-poll 場景。
- **衝突**：P3-06 的範圍明文寫「往上捲載入歷史（用 `before_seq`）」，
  驗收條件 1 要求「250 則以上訊息可流暢往回捲」。以現有 API 只能
  `after_seq=0&limit=500` 一次全抓，訊息上萬則時必然卡頓。
- **選項**：
  - **(A) server 補參數（建議）**：`read_messages` 增加 `before_seq: int | None`，
    當它非 None 時改為 `WHERE seq < ? ORDER BY seq DESC LIMIT ?`，回傳前再反轉為升序。
    改動 < 10 行，且不影響既有呼叫者。開一張 P1 補卡。
  - (B) client 用 `after_seq = max(0, oldest - N)` 反推。可行但每次都要多讀 N 則，
    且 seq 有洞（軟刪除不會產生洞，但仍是脆弱假設）時頁面大小會抖動。
- **決策點**：P3-06 開工前。若選 (A)，P3-03 的 client 方法簽章要預留 `beforeSeq` 參數。

### R-2（中）沒有「列出某房間所有指派」的端點，P3-09 無法呈現狀態

- **現況**：`GET /api/assignments` 只吃 `session_key`，且 SQL 硬寫死
  `AND a.status='pending'`——查不到 accepted / declined / expired，也無法按房間查。
- **衝突**：P3-09 範圍要「檢視房間的指派狀態（pending / accepted / declined / expired）」，
  驗收條件 2「agent 加入後 UI 上狀態自動轉為 accepted」與條件 3「過期指派顯示為 expired」
  都需要能讀到非 pending 的紀錄。
- **選項**：
  - **(A) server 補 `GET /api/rooms/{id}/assignments`（建議）**，
    可選 `status` 過濾，預設回全部。
  - (B) 放寬現有端點：加 `room_id` 與 `status` 兩個 optional query 參數。
- **決策點**：P3-09 開工前。

### R-3（中）房間列表缺少「最後活動時間」與「最新 seq」

- **現況**：`GET /api/rooms` 回傳 `room.*` + `member_count`，
  沒有最新訊息時間，也沒有房間目前的最大 seq。
- **衝突**：P3-05 範圍要顯示「最後活動時間」；未讀標記也需要房間的最新 seq
  才能與本機 `lastReadSeq` 比較。
- **選項**：
  - **(A) server 在 `list_rooms` 的 SQL 加兩個子查詢（建議）**：
    `last_message_at` 與 `last_seq`（= `next_seq - 1`，`room` 表已有此欄位，
    甚至不需要 JOIN message，直接 `SELECT next_seq` 即可）。成本近乎零。
  - (B) client 對每個房間各打一次 `GET /messages?after_seq=<大數>` —— N+1 查詢，否決。
- **決策點**：P3-05 開工前。**若時間緊迫，(A) 的 `last_seq` 部分可以先做**
  （直接讀 `room.next_seq`），未讀標記優先於相對時間顯示。

### R-4（高）WS 不會推播「既有訊息的釘選 / 刪除變更」

- **現況**：`pin` / `unpin` / `delete_message` 都有呼叫 `events.notify(room_id)`，
  但 WS 的 `pump()` 只查 `WHERE seq > last`。被釘選的訊息 seq 早就 <= last，
  所以 pump 醒來查不到東西，會直接回去 `events.wait()`——**什麼都不推**。
- **衝突**：P3-08 驗收條件 2「釘選 / 取消即時同步到其他連線的 client」無法達成。
  單機測試（自己釘自己看）會因為本機樂觀更新而假性通過，**必須開兩個 client 測**。
- **選項**：
  - **(A) server 在 pin/unpin/delete 時推一個獨立事件（建議）**：
    新增 `{"type":"message_updated","room_id":...,"message":{...}}`。
    需要在 `RoomEvents` 上加一條旁路（notify 時攜帶 payload），
    或讓 pump 額外訂閱一個 `revision` 頻道。改動偏大但語意最乾淨。
  - (B) client 在房間 focus 時每 15 秒輪詢 `GET /messages?pinned_only=true`
    做差異比對。能過驗收但髒，且抓不到「他人的軟刪除」。
  - (C) 降級驗收條件為「重新進入房間後同步」。
- **決策點**：P3-08 開工前，**且 P3-04 的 `ws_protocol.dart` 事件定義要預留
  `message_updated` 的 sealed class 分支**，否則之後補 server 端時 client 要大改。

### R-5（中）`reply_to` 只有 message id，沒有隨訊息附帶原文摘要

P3-07 驗收條件 4 要求「UI 顯示被回覆的原文摘要」。訊息 payload 只有
`reply_to` 的 id，沒有內容；且**沒有「依 id 取單則訊息」的端點**。
若被回覆的訊息不在已載入的視窗內（回覆很舊的訊息），client 無從取得原文。

- 短期解：先從本機 store 依 id 查（`Map<String id, int seq>` 反查索引），
  找不到就顯示「回覆了一則較早的訊息」的降級 UI，點擊時才觸發載入。
- 長期解：server 在 `_message_rows_to_json` 附帶 `reply_to_preview`
  （原文前 80 字 + sender_name），一次查詢解決。**建議走這條。**

### R-6（低）WS 連線不刷新 participant 的 `last_seen_at`

`ws_endpoint` 完全不碰 participant 表。人類不受 sweeper 影響所以不致命，
但意味著 **UI 開著不等於「在線」**——成員清單上人類的 `last_seen_at`
只由 §6.5 的 heartbeat 推進。這是 heartbeat 存在的實質理由，別在優化時刪掉它。

### R-7（低）token 走 WS 的 query string

`/ws?token=<API_TOKEN>` 會出現在 server 的 access log 與任何中間 proxy 的日誌。
Phase 4 上外網（Tunnel / Tailscale）時這會是實質問題。
Client 端能做的只有「不要把完整 WS URL 寫進 app 自己的 log」——
`redacting_logger.dart` 要把 `token=` 之後的字串遮蔽。根治屬於 Phase 4 的範疇。

### 開放問題（需實作時定案，不阻塞設計）

| # | 問題 | 定案時機 |
|---|------|---------|
| O-1 | Markdown 套件的最終選擇（`flutter_markdown_plus` vs `markdown_widget`），需以 pub.dev 當下的維護狀態為準 | P3-02 |
| O-2 | 桌機雙欄佈局的斷點寬度（暫定 900px） | P3-05 |
| O-3 | 訊息 store 的記憶體上限。單房超過 N 則時是否裁掉最舊的（暫定 2000 則，裁切後 `oldestLoadedSeq` 須同步更新，否則往上捲會出錯） | P3-06 |
| O-4 | 是否支援單一 app 同時連多個 Hub（多 server profile）。**目前設計為單一 Hub**，改動會影響 §1.5 的儲存 schema | P3-02（決定後就別改） |
| O-5 | `preferred_name` 是否讓使用者在設定畫面預設（否則每次 join 拿到隨機名字池的名字） | P3-07 |
| O-6 | Android 建置是否納入 P3-10。取決於 P3-01 的 Android toolchain 是否裝成 | P3-01 |

---

## 8. 施工順序建議

依 `TASKS.md` 的依賴圖，加上本文件揭露的風險，調整後的建議順序：

```
P3-01 ─► P3-02 ─► P3-03 ─┬─► P3-04 ─► P3-06 ─► P3-07 ─► P3-08 ─┬─► P3-10
                         └─► P3-05 ──────────┬────────────────┘
                                             └─► P3-09 ────────┘

插入的 server 補卡（不阻塞 P3-01~P3-04，但要在對應卡前完成）：
   R-3 (room 列表欄位)  ──► 必須早於 P3-05
   R-1 (before_seq)     ──► 必須早於 P3-06
   R-5 (reply_to 摘要)  ──► 建議早於 P3-07
   R-4 (WS 更新事件)    ──► 必須早於 P3-08
   R-2 (房間指派列表)    ──► 必須早於 P3-09
```

**這五張 server 補卡都很小（各自 S 規模），建議打包成一張 P1 補強卡一次做完**，
在 P3-04 進行的同時並行處理，不會擋到 Flutter 端的進度。
