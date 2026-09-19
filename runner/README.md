# Chatroom 執行器（runner）

遠端派工的本機執行端（`docs/REMOTE-OPS-PLAN.md` P2）。它做的事只有一件：
**從 Hub 領一筆 run，在允許的工作樹上起一個 `claude -p` 子進程，回報結果。**
佇列與狀態的真相在 Hub，不在這裡——執行器重啟不影響佇列。

## 安裝

1. 複製設定：

   ```powershell
   New-Item -ItemType Directory -Force "$env:LOCALAPPDATA\UEP\Chatroom\runner"
   Copy-Item runner\config.example.json "$env:LOCALAPPDATA\UEP\Chatroom\runner\config.json"
   ```

   改裡面的 `hub_url`、`label`、`workspaces`（工作區底下的專案路徑與允許分支）。
   `agent_token` 留空、用 `token_env_file` 指到 `server/.env` 比較安全——
   那個檔案本來就不進版控。

2. **首次登入獨立設定目錄**（只要做一次，而且要在艾斯維爾離開前做）：

   ```powershell
   $env:CLAUDE_CONFIG_DIR = "$env:LOCALAPPDATA\UEP\Chatroom\runner\claude-config"
   claude /login
   ```

   用獨立的 `CLAUDE_CONFIG_DIR` 是為了不載入使用者全域的 hooks（persona 注入、
   記憶健檢那些）。⚠️ **連接器（Atlassian）在獨立設定目錄下是否仍可用，
   只能實機驗**：登入後跑一次 `claude mcp list` 確認顯示 connected。
   不行的話退回共用設定目錄，並在 run 的 `--settings` 裡覆寫掉不要的 hook。

3. 自檢（不會領單、不會起 agent）：

   ```powershell
   $env:PYTHONPATH = "$PWD\runner"
   .\.venv\Scripts\python.exe -m chatroom_runner --selfcheck-only
   ```

   ⚠️ `runner\` 不在 repo root 的 import 路徑上。**手動前景跑**時用
   `PYTHONPATH` 補；常駐那條不行（排程工作設不了環境變數），由第 4 步的
   `install-task.ps1` 寫 `.pth` 解決。

   自檢驗三件事：`claude --version`、`gpg --clearsign` 探針、每個 repo
   `git status` 可用且**停在允許分支**。任一沒過就不領單（狀態報 offline，
   原因會出現在房裡與儀表板上）。

4. 常駐：用 `runner\install-task.ps1` 建 Windows 排程工作（登入時啟動、
   失敗重啟、每 5 分鐘存活檢查）。那個腳本**只建工作，不會啟動執行器**。

   它同時做兩件讓排程跑得起來的事：

   - 在直譯器的 site-packages 寫一行 `chatroom_runner.pth` 指向 `runner\`，
     然後**當場驗** `import chatroom_runner`，不通就 throw。
   - 動作用同目錄的 `pythonw.exe`（沒有 console，不會閃黑窗）；找不到
     pythonw 才退回 `python.exe` 並警告。

   搬過位置或換了 venv 就重跑一次（加 `-Force`）——`.pth` 裡是絕對路徑。

## 設定檔欄位

| 欄位 | 說明 |
|---|---|
| `hub_url` / `agent_token` / `token_env_file` | Hub 位置與 agent 憑證。token 三種來源：設定檔 → `CHATROOM_TOKEN` → `.env` |
| `host` / `label` | 註冊身分。**同 host+label 在 Hub 是同一台**（冪等） |
| `max_parallel` | 同時幾個 run（預設 3）。本地與 Hub 兩端都守 |
| `heartbeat_seconds` | 心跳間隔（預設 30） |
| `stall_warn_seconds` | 進行中的 run 多久沒吐出任何 stream 事件就標成停滯（預設 600，`0` ＝關掉）。**只標記、不殺進程**，數字出現在 `dashboard_json.runs.running[].stalled_seconds`；牆鐘上限照舊管終止 |
| `maintenance_hour` | 每日維護窗（預設 4 點）。到點且無 run 時自我重啟 |
| `usage_window_hours` / `usage_soft_cap_tokens` / `usage_soft_cap_usd` | 近 N 小時的軟上限，到了就停收新單。**這是自我約束，不是真實額度** |
| `require_gpg` | 自檢要不要驗簽章（預設 true） |
| `gpg_bin` | 自檢用哪一支 gpg。留空＝跟 git 同源（`git config --get gpg.program`），再退回 PATH 上的 `gpg`。排程工作的 PATH 跟互動 shell 不一樣 |
| `claude_bin` | `claude` 的路徑。要帶參數請給陣列 |
| `claude_config_dir` | 獨立的 `CLAUDE_CONFIG_DIR` |
| `state_dir` | 狀態根目錄（狀態檔、log、usage.db、run 暫存） |
| `backoff_minutes` | 撞到 rate limit 後的退避階梯（預設 5／15／30／60 分鐘） |
| `allowed_domains` | hook 放行的網路目的地。清單以外的 `curl`／`Invoke-WebRequest` 一律擋 |
| `extra_allowed_tools` | 額外預先授權給 run 的工具名（併進 `--allowedTools`），例如 `mcp__claude_ai_Atlassian_Rovo__*`。只是不要卡在權限提示，硬限制仍由 PreToolUse hook 守 |
| `allowed_mcp_servers` | run 准用的 MCP 伺服器（預設 `["chatroom"]`）。**預設拒絕**：跟著登入進來的 claude.ai 連接器，不在這裡也沒被 `extra_allowed_tools` 的 `mcp__<server>__*` 點名的，一律寫進 run 專用 settings 的 `deniedMcpServers`（伺服器不載入）與 `--disallowedTools`／`permissions.deny`（工具移出 context） |
| `workspaces.<key>.folder` | 工作區的外層資料夾（絕對路徑，選填）。**執行器的邏輯不依賴它**：給 App 顯示與當新增專案／skill 目錄的預設起點。路徑不存在只在 log 警告，不影響載入 |
| `workspaces.<key>.projects.<name>.path` | 專案（git 工作樹）路徑。**cwd 由這裡決定，brief 說了不算**；不是 git repo（找不到 `.git`）的專案在載入時被排除，並在自檢與 log 點名 |
| `workspaces.<key>.projects.<name>.allowed_branches` | 可以停留／切換的分支 |
| `workspaces.<key>.projects.<name>.push_branches` | `push` run 可以推的分支 |
| `workspaces.<key>.default_project` | 沒指名專案時用哪一個 |
| `workspaces.<key>.primary_skill` | 這個工作區**不分 kind**都要開工先載入的 skill（至多一個）。驗證與 `skills` 同一套（缺 `SKILL.md` 就是設定錯誤），名字一樣進 `--allowedTools` 的 `Skill(<name>)`，並寫進契約 |
| `workspaces.<key>.skill_dirs` | 起 claude 時每個加一個 `--add-dir`。專案的 skill 放在 cwd 的**上一層**時（cwd 自己是子 repo，skill 發現只往上找到 git root），沒有這個設定就掃不到。啟動自檢驗目錄存在 |
| `workspaces.<key>.skills` | kind → 這種派工**必須遵守**的 skill 名清單，例如 `{"ticket": ["jira-ticket-workflow"]}`。名字會進 `--allowedTools` 的 `Skill(<name>)`，也會寫進契約要求 run 一開始就啟動它。**載入時就驗** `<skill_dir>/.claude/skills/<name>/SKILL.md` 存在，缺就是設定錯誤 |
| `workspaces.<key>.extra_write_dirs` | guard 額外放行寫入的目錄（skill 要求的產出落在 repo 外時）。放行的是**位置**，敏感檔名（`.env`、`*.pem` 這類）與敏感目錄的檢查照走 |

### 一筆 run 在哪個專案（repo）做

> 舊鍵 `projects`／`repos`／`default_repo` 仍然讀得進來（新鍵優先，同時
> 存在時 log 會警告）。Hub／App 對外的 `project` 欄位沒有跟著改名：
> 執行器的**工作區 key 就是 Hub 的 project key**。

1. `push`：`ref` 就是 repo 名。
2. brief 裡有一行 `repo: <名稱>` ⇒ 用那個。
3. 工作區只有一個專案，或設了 `default_project` ⇒ 用它。
4. 都不成立 ⇒ 這筆 run 直接 failed。**執行器不猜**：猜錯等於在錯的工作樹上
   commit，而遠端沒有人看得到。

## 檔案位置

| 東西 | 位置 |
|---|---|
| 設定 | `%LOCALAPPDATA%/UEP/Chatroom/runner/config.json`（`CHATROOM_RUNNER_CONFIG` 可覆寫） |
| log | `%LOCALAPPDATA%/UEP/Chatroom/runner/logs/runner.log`（輪替 5MB × 5） |
| 執行器身分與 token | `.../runner/state.json`（權限只限使用者，**不要外流**）。同時記著現在手上有哪幾筆 run（`active_run_ids`），啟動對帳靠它認出上一次崩潰留下的孤兒 |
| 用量視窗 | `.../runner/usage.db` |
| 每筆 run 的暫存 | `.../runner/runs/<run_id>/`：`settings.json`、`mcp.json`、`guard.json`、`stream.jsonl`、`tool.log`、`handoff.flag`、`compacted`、`report_failed.json`（回報送不出去時的落地，下次 heartbeat 重送）、`downloads/`（`chatroom_get_file` 的落點，`CHATROOM_DOWNLOAD_DIR` 指到這裡；不放在 repo 裡是因為附件會弄髒人類的工作樹，run 結束後隨 run 目錄留著） |

## 硬限制（`PreToolUse` hook）

matcher：`Bash|PowerShell|Write|Edit|MultiEdit|NotebookEdit|Read|Glob|Grep`
（⚠️ **一定要含 PowerShell**：Windows 上模型預設選它；
少了 `Read|Glob|Grep` 則 `.env` 與私鑰換一個工具就讀得到）。

- `handoff.flag` 存在 ⇒ 一律擋，要求立刻交接。
- git：白名單 `status/diff/log/show/add/commit/branch 建立/checkout|switch 到允許分支/stash list/fetch/rev-parse/ls-files/remote 讀/config 讀`，其餘一律擋（含 `push`、`reset`、`clean`、`rebase`、`branch -D`）。
- 一律擋：`--no-verify`、`--no-gpg-sign`、`rm -r*`、`Remove-Item -Recurse`、
  `npm publish`、`az`、`wrangler deploy`、`gh pr merge`、
  `curl`／`Invoke-WebRequest` 到 `allowed_domains` 以外。
- 殼層與直譯器包裝一律擋：`cmd /c`、`powershell`／`pwsh`、`bash -c`、`wsl`、
  `Start-Process`、`iex`／`Invoke-Expression`、`Invoke-Command`、`eval`／`exec`、
  `& {…}`、`python -c`／`-m`（只留 `-m pytest`）、`node -e`／`-p`、`perl -e`、
  `ruby -e`。允許 `python`／`node` 跑 cwd 以內的腳本與 `npm`／`npx`／`pnpm`
  的 test／run／lint 類。
- git 全域選項先剝除：`-C`／`--git-dir`／`--work-tree` 出現即拒絕，
  `-c credential.*`／`core.hooksPath`／`gpg.*`／`commit.gpgsign=false` 也拒絕。
- 改 git 憑證設定（`$env:GIT_*=`、`set`／`export GIT_*=`、
  `Set-Item env:GIT_*`、`SetEnvironmentVariable`、`git config credential.*`）
  一律擋——一般 run 的環境是刻意清掉憑證的。
- 寫入型工具：路徑必須在 cwd 內，且不是 `.env*`／`*.pem`／`.claude`／`.gnupg`／
  執行器自己的目錄。
- 讀取型工具（`Read`／`Glob`／`Grep`）：**不限 cwd**，但路徑或 glob 命中
  `.env*`／`*.pem`／`*.key`／`*.p12`／`id_rsa*`／`.ssh`／`.gnupg`／`.claude`／
  `.claude.json`／`credentials*`／執行器自己的目錄就擋。
- 其餘放行，並寫進該 run 的 `tool.log`。

被擋時 stderr 的理由會原樣回給模型，開頭一定是「這是系統限制」並指出替代路徑
——實測模型被擋之後會換工具再試一次然後放棄，不講清楚它只會在那裡繞。

### 推送憑證隔離（裁決 2026-09-16）

一般 run 的子進程環境清空 `credential.helper`（`GIT_CONFIG_*` 只作用在那個進程，
本機 git 設定沒動）、`GIT_TERMINAL_PROMPT=0`、`GIT_ASKPASS` 指到
`hooks/askpass-deny.*`（永遠 exit 1）。`push` run 的 `fetch`／`push` 明確帶
`-c credential.helper=manager`，不改 remote URL、不存 token。

⚠️ 同一個 Windows 帳號下，決心繞過的對手仍讀得到 Credential Manager——
真正的硬隔離要第二個帳號，已裁定不做（規劃書 §6.4「結構性限制」）。

## 退出碼

| 碼 | 意思 |
|---|---|
| 0 | 正常收工 |
| 1 | 啟動自檢沒過 |
| 2 | 設定檔有問題 |
| 75 | 請立刻重新拉起（維護窗、`restart` 命令）。排程工作看這個碼 |

## 測試

```powershell
.\.venv\Scripts\python.exe -m pytest -q
```

不要指定路徑（`pytest.ini` 的 `testpaths` 含 `runner/tests`，命令列給了路徑會
把另外兩半排除掉）。測試**不會**起真的 `claude`、不會註冊排程工作、
不會連外部 Hub：假的 claude 在 `runner/tests/fake_claude.py`，Hub 走
in-process ASGI。
