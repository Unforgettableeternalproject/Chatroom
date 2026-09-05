# 版本定錨 SOP

> 這份文件回答一個問題：**我現在看到的這個版本號，能不能當作判斷依據？**
>
> 「為什麼版本字串要帶 commit hash」寫在 [`FAILURE-PATTERNS.md`](FAILURE-PATTERNS.md)
> §「產物識別：根因不在程式碼裡」，那是事故的形狀。這裡只寫**操作規範**，
> 不重複那一份。

---

## 1. 權威順序

判斷「某個進程正在跑哪一份程式碼」，由可信到不可信：

| 來源 | 地位 | 說明 |
|---|---|---|
| **startup log**（`hub.jsonl` `event=startup`） | **權威** | 那一行是那個進程啟動當下寫的，事後無法被工作樹影響 |
| `GET /api/health` 的 `build` | **快篩** | 正常情況與 startup log 一致，見 §2 的前提 |
| 檔案時間戳、zip 大小、「我記得我 rebuild 過」 | **不可用** | 見 FAILURE-PATTERNS §「不要用產物的外部屬性推斷內容」 |

⚠️ **版號（`1.1.5`）不是版本。** 它只說得出「這是哪一版設計」。2026-09-05 房內
同時存在三包版號都是 `1.1.5` 的 kit，commit 各不相同——唯一分得出來的欄位是
`_build.json` 的 `commit`。報告版本時一律連 commit 一起講。

## 2. health 為什麼可信，以及它什麼時候不可信

`build_info()` 有 `lru_cache`，而 `create_app` 的 lifespan 裡那句
`info = build_info()` 是啟動後第一個呼叫它的地方 ⇒ 版本被凍在**啟動當下**，
之後 `/api/health` 回的不會跟著工作樹跑。

**這個保證是隱式的。** 拿掉那一句，health 就變成「現查 git HEAD」——
一台跑著舊碼的 Hub 會回報新 commit，而且不會有任何地方報錯。

- 該行在 `server/chatroom_server/app.py` 的 lifespan 內，已標註 load-bearing
- `tests/test_health_version_anchor.py` 釘住這個行為（驗過會紅）
- **改動 lifespan 開頭時，先看那條測試再動手**

跑 source 的開發機上，health 的 commit 可能帶 `-dirty`；那表示啟動當下工作樹
就是髒的，不是現在髒。

## 3. dirty 判定的範圍

`-dirty` 只看**這份產物實際收錄的路徑**：

| 產物 | scope |
|---|---|
| Hub（`server/chatroom_server/version.py`） | `server/` |
| bridge（`bridge/chatroom_mcp/version.py`） | `bridge/` |
| host-kit | `server/` `host-kit/` `scripts/` |
| install-kit | `bridge/` `install-kit/` |

理由：Hub 的版本不該因為別人在改 Flutter 而變成「對不回任何 commit」。
2026-09-05 實測，七個髒檔裡五個在 `app/`，而那五個一行都不會進 Hub 的包。
**scope 開太大會讓警告恆真，而恆真的警告沒有人看。**

⚠️ scope **內**的 untracked 仍然算髒——新檔案沒 commit，一樣對不回去。

## 4. 驗收凍結準則

決定「這個版本能不能拿來驗收」：

- `git status --porcelain -- server/ bridge/` **非空 ⇒ 不驗收**
- runtime 乾淨但別處髒（例：只有 `app/` 髒）⇒ **可驗收，但附上收據**
  （貼那條 `git status` 的輸出，讓看的人自己判斷）
- 版本判定以 startup log 為準，health 只當快篩

## 5. 打包與交付

- **驗證用的 build 不得寫回 `dist/`。** 想確認打包流程正確就輸出到臨時目錄。
  2026-09-05：為驗證 scope 修法實跑 `install-kit/build.py`，把已經送出去的
  乾淨包覆蓋成 dirty 版——**同名產物被無聲換掉**，正是這份 SOP 要防的形狀。
- 交付一包 kit 時，訊息裡連 `version` + `commit` 一起講，並要求對方**裝之前
  先驗 `_build.json`**。
- 對帳時比 `version` + `commit`。**`built_at` 必然不同**（那是打包當下的時間
  戳，不是 commit 時間），兩台各自 build 同一個 commit 也會不一樣。
- 產物可以走聊天室直接送（`chatroom_send_file`），不必經人手搬運——
  少一個「搬運中途版本又前進」的破口。

## 6. 驗證方法本身的陷阱

- **啟動路徑的失敗不長成紅燈，長成沒有回應。** lifespan 在 `__aenter__` 途中
  拋例外時，pytest 會卡著不返回。「單檔測試跑很久沒結果」要先懷疑這個，
  不要先懷疑自己的測試寫法（2026-09-05 實例）。
- **修復程序只在啟動路徑上時，症狀會被重啟洗掉。** 除錯期間重啟 server
  等於湮滅現場。
- **綠燈要問「它看得到什麼」。** 按可見度過濾的資料上做全庫判定，會得到
  看起來乾淨、其實只是視野之外的結果（2026-09-05：唯讀探針掃不到那塊板，
  綠燈是假的）。

## 相關

- [`FAILURE-PATTERNS.md`](FAILURE-PATTERNS.md) — 這些規則背後的事故形狀
- [`BUILD.md`](BUILD.md) — UI 建置步驟
