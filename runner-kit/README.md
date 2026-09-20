# Chatroom 執行器安裝包（runner-kit）

> ⚠️ **支援範圍**
> - 執行器只支援 Claude Code（派工用 `claude -p`）。
> - MCP 只支援 Claude Code 全域設定裡已經有的那些。
> - Codex 或其他 agent 不能當執行器。

這包把**遠端派工的執行端**裝到一台 Windows 機器上：獨立 venv、設定檔、
Windows 排程工作。裝好之後這台機器就能從 Hub 領單，在你指定的工作樹上
起 `claude -p` 做事。

需要 Python 3.12+，以及一個連得到的 Hub（位址與 agent token 跟主持人要）。

## 安裝

```powershell
# 解壓 chatroom-runner-kit.zip 之後
python install.py
```

會問四件事：Hub 位址、agent token、機器名、標籤（同 `host`+`label` 在 Hub
是同一台）。要非互動就給參數：

```powershell
python install.py --yes --hub-url http://192.0.2.10:8787 --token <TOKEN> --label esvel
```

其他參數：

| 參數 | 用途 |
|---|---|
| `--dir` | 安裝目錄，預設 `%LOCALAPPDATA%\UEP\Chatroom\runner-kit` |
| `--config` | 設定檔路徑，預設 `%LOCALAPPDATA%\UEP\Chatroom\runner\config.json` |
| `--task-name` | 排程工作名稱，預設 `ChatroomRunner`。同一台要跑第二個執行器時一定要改，否則撞名 |
| `--no-task` | 不註冊排程工作（之後可手動跑 `runner\install-task.ps1`） |
| `--uninstall` | 移除排程工作與註冊檔。**設定與 log 留著**，重裝不必重設 |

安裝器**不啟動執行器**，也不會覆寫已經存在的設定檔。

`--yes` 下一個問題都不問（桌面 App 就是這樣以子進程呼叫的），stdout 的最後
一行固定是 `RESULT {"ok":true,"kit":"runner-kit","kit_root":…,"version":…,
"commit":…,"registry":…,"config_written":…,"task_registered":…,
"login_required":…,"login_hint":…}`，給呼叫端解析用（三包安裝器同一個
格式）。失敗時退出碼非 0、原因走 stderr。
設定檔本來就在時 `config_written` 是 `false`——這次給的 `--hub-url`／
`--token` **沒有**寫進去。
`login_required` 是「那個 `claude_config_dir` 底下看不到登入憑證」，
`login_hint` 是補登入的那一行 PowerShell 指令；`--yes` 下安裝器**不起**
登入流程。

## 裝完還有兩件事

1. **加專案**。新裝的設定檔 `projects` 是空的——執行器會上線，但一筆單都
   領不到。用 App 的執行器分頁加，或直接編輯設定檔。

   ⚠️ 這包**不含要被派工的 repo**。工作樹仍然要存在於這台機器上，把路徑填進
   `projects.<key>.repos.<name>.path`；`skill_dirs` 同理，指的是真實的本機路徑。

2. **登入獨立的 Claude 設定目錄**（只要做一次，而且要在本人還在電腦前時做）。
   互動安裝的最後會問「現在登入 Claude Code？」，答 Y 就直接跑這一段；
   `--yes` 不會起登入，要自己跑：

   ```powershell
   $env:CLAUDE_CONFIG_DIR = "$env:LOCALAPPDATA\UEP\Chatroom\runner\claude-config"
   claude auth login
   ```

   沒登入的話執行器會上線，但派工的 `claude -p` 起不來。

然後自檢（不領單、不起 agent）：

```powershell
& "$env:LOCALAPPDATA\UEP\Chatroom\runner-kit\.venv\Scripts\python.exe" `
    -m chatroom_runner --selfcheck-only
```

過了再啟動：`Start-ScheduledTask -TaskName ChatroomRunner`。

## 設定檔在哪、怎麼重載

- 設定檔：`%LOCALAPPDATA%\UEP\Chatroom\runner\config.json`
  （安裝時用 `--config` 指到別處的話以那個為準；執行器也認環境變數
  `CHATROOM_RUNNER_CONFIG`）。欄位說明看同包的 `runner\README.md`。
- 同目錄下還有 `state.json`（含這台在 Hub 的 `runner_id`）、`logs\runner.log`、
  `usage.db`、run 暫存。**移除安裝包不會動它們。**
- 改完設定要生效：目前的做法是重啟排程工作

  ```powershell
  Restart-ScheduledTask -TaskName ChatroomRunner
  ```

  ⚠️ 重啟會打斷**正在跑的 run**。佇列的真相在 Hub，被打斷的單會回到 Hub 的
  狀態機，不會憑空消失，但那一次的進度會重來。手上有 run 在跑就等它結束再重啟。

- 註冊檔 `~/.chatroom/runner-kit.json` 只是給桌面 App 的指路牌
  （`kit_dir` / `python` / `config` / `installed_at`）。**不要拿它當設定**——
  改它不會改變執行器的行為。

## 沒裝這包的機器

App 裡「建立工作房」會停用：開工作房的前提是這台機器自己派得出工。
**加入別人的工作房、看派工狀態不受影響**，那些只是讀 Hub。
