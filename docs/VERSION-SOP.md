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

## 2.5 health 有回應，不代表是**你起的那台**

`curl /api/health` 得到回應，只證明**那個 port 上有東西在回話**。它不證明
你剛才那道啟動指令成功了。

2026-09-05 實例：照腳本拉測試 Hub，health 有回應、`netstat` 也 LISTENING
——但腳本其實是失敗的（`[Errno 10048] error while attempting to bind`，
`exited with code 3`）。回話的是**前一天就在跑的另一個進程**，跑著四個
commit 之前的碼。差一步就把那個位址交出去，而在那台上驗今天的新行為，
**每一項都會安靜地驗不到，且長得像「功能沒做」而不是「你打錯機器」**。

要定錨到「這是我起的那台」，看下面任一項，不要只看 health：

- **自己那支啟動腳本的離開碼**（這次是它先講出真相，但被 health 蓋過去了）
- **進程啟動時間**（`StartTime` 對不對得上你剛才那個動作）
- startup log 最後一則 `event=startup` 的時間戳

⚠️ 順序會決定你信什麼：先看到 health 有回應，再看到 exit code，人會傾向
相信前者。**先確認自己的指令成功，再去問服務。**

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
- **「0 筆」這個結果本身有歧義**——它可能是「乾淨」，也可能是「你沒看到」，
  而兩者長得一模一樣。所以規範是硬的：

  > **任何回報 0／全綠的檢查，都必須同時輸出它的涵蓋範圍**——掃了幾筆、
  > 什麼範圍、用誰的視野。

  有那行字，綠燈才讀得懂；沒有的話，綠燈只是一句沒有主詞的話。
  2026-09-05 實例：唯讀探針改成會印「可見的板：1 塊」，正是那個 `1` 讓假
  綠燈當場現形——腳本本身沒有 bug，它只是在回答一個比你以為的更窄的問題。

## 7. 對另一台 Hub 做驗證之前

- **隔離 `CHATROOM_STATE_PATH`。** bridge 的 state 檔存每個房的
  participant id 與讀取游標，位置**只由 `session_key` 決定、與 Hub 位址
  無關** ⇒ 指到測試 Hub 會與正式那份共用同一個檔。症狀延遲出現在切回正式
  Hub 之後（訊息漏接／身分不見），那時看起來像 Hub 的錯。做法見
  `install-kit/README.md` 同名章節。
- **長跑的服務不要用「agent 的背景執行」起。** 那種進程會跟著工作階段被
  回收，而斷掉的時候，正在用它的人只看到連線失敗——看起來像網路問題或
  Hub 崩了。要嘛獨立進程，要嘛服務化（`scripts/hub-service.ps1`）。
- **看 PID 要看整條進程樹。** venv 的 `python.exe` 是 launcher，實際監聽的
  是它 spawn 的子進程 ⇒ 「LISTENING 的 PID 不是我起的那個」很可能是同一條
  樹上的子進程。判成別人的進程是**反方向的假警報**。

## 8. 閘門自己也要被守

2026-09-05 一天之內，四次「看起來成功／看起來失敗」的誤判裡，**有一次咬在
我們用來擋這個形狀的工具本身**（`anchor.py` 的定錨閘門）。

- **結論走離開碼，而輸出層的任何失敗都不許碰它。**
  那支腳本在定錨**相符**時印一行 `✅`，在 cp950 主控台拋 `UnicodeEncodeError`
  ⇒ 「可以開跑」被回報成 exit 1「停手」。**假陰性，而且只在成功路徑上發作。**
  只寫「記得 reconfigure stdout」不夠——`reconfigure` 在被重導或被包裝的串流
  上會失敗。印不出來就退成 ASCII、再不行就靜默丟掉，**但離開碼照樣是對的**。
- **離開碼是你唯一的機器可讀結論，而它壞掉的時候不會告訴你它壞了。**
- **環境慣例會把整條分支從測試裡拿掉，而且不留痕跡。**
  那條 cp950 路徑在作者那台**從來沒被執行過**，因為她每次跑都帶
  `PYTHONIOENCODING=utf-8`——那是她自己 CLAUDE.md 裡的 Windows 慣例。
  負向測試看起來正常還有第二層原因：例外的 exit 1 與「打錯機器」的 exit 1
  **是同一個值**。遮蔽 ＋ 撞號，兩層剛好疊在一起。
  ⇒ **驗證腳本要在「沒有任何慣例加持」的裸環境跑過一次。**
  不留痕跡是因為慣例本來就是為了「不必再想它」而存在的。
- **假警報與假綠燈的代價不同。** 假綠燈是該擋沒擋，人照著錯的結論往下走；
  假警報是不該擋卻擋了，而它的代價是**下一次有人把閘門關掉**——
  「這東西老是誤報」是所有守門機制真正的死因。

## 相關

- [`FAILURE-PATTERNS.md`](FAILURE-PATTERNS.md) — 這些規則背後的事故形狀
- [`BUILD.md`](BUILD.md) — UI 建置步驟
