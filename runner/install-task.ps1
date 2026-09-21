# 建立執行器的 Windows 排程工作（REMOTE-OPS-PLAN §5.7）。
#
# ⚠️ 這個腳本**只建工作，不啟動執行器**。第一次跑之前請先確認：
#   1. 設定檔已就位（見 runner/README.md）
#   2. `python -m chatroom_runner --selfcheck-only` 是通的
#   3. 獨立的 CLAUDE_CONFIG_DIR 已經 `claude /login` 過
#
# 三個觸發器：登入時啟動、失敗自動重啟、每 5 分鐘檢查存活。
# 執行器用退出碼 75 要求「立刻重新拉起」（維護窗與 restart 命令），
# 排程工作的重啟設定會接手——執行器不自己 re-exec，因為壞掉的那一次
# 自己就沒有人重試了。

[CmdletBinding()]
param(
    [string]$TaskName = "ChatroomRunner",
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$Python,
    [string]$ConfigPath,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

if (-not $Python) { $Python = Join-Path $RepoRoot ".venv\Scripts\python.exe" }
if (-not (Test-Path $Python)) {
    throw "找不到 Python：$Python。請先建好專案的 .venv。"
}
$runnerDir = Join-Path $RepoRoot "runner"
if (-not (Test-Path (Join-Path $runnerDir "chatroom_runner"))) {
    throw "找不到 runner 套件：$runnerDir"
}
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $env:LOCALAPPDATA "UEP\Chatroom\runner\config.json"
}
if (-not (Test-Path $ConfigPath)) {
    Write-Warning "設定檔還不存在：$ConfigPath（工作照建，但執行器會以退出碼 2 結束）"
}

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing -and -not $Force) {
    throw "排程工作「$TaskName」已存在。確定要覆寫請加 -Force。"
}

# 讓 runner/ 進得了 sys.path：**排程工作設不了環境變數**，所以不能靠
# PYTHONPATH（2026-09-17 的失敗就是這個——動作照跑，但每次都是
# `No module named chatroom_runner`、退出碼 1，然後被重啟設定每分鐘拉一次）。
# 改成在直譯器的 site-packages 放一行 .pth，對前景手跑與排程都成立。
$purelib = (& $Python -c "import sysconfig;print(sysconfig.get_paths()['purelib'])" 2>&1 | Select-Object -Last 1)
if ($LASTEXITCODE -ne 0 -or -not $purelib -or -not (Test-Path $purelib)) {
    throw "取不到 site-packages 路徑（$Python）：$purelib"
}
$pthFile = Join-Path $purelib "chatroom_runner.pth"
Set-Content -Path $pthFile -Value ((Resolve-Path $runnerDir).Path) -Encoding ascii
Write-Host "已寫入 $pthFile"

# 工作目錄留給 repo root，不 cd 進 runner/：這樣 log 與相對路徑的意義
# 跟手動跑的時候一致
#
# 用 pythonw.exe 起：python.exe 是 console 程式，排程工作每次拉起都會閃一個
# 黑窗（失敗重啟時就是一直閃）。pythonw 沒有 console，子進程那邊由
# chatroom_runner.procs.no_window_kwargs() 補 CREATE_NO_WINDOW。
$pythonw = Join-Path (Split-Path -Parent $Python) "pythonw.exe"
if (Test-Path $pythonw) {
    $execute = $pythonw
} else {
    Write-Warning "找不到 $pythonw，改用 $Python（每次啟動會閃一個 console 視窗）"
    $execute = $Python
}

$action = New-ScheduledTaskAction `
    -Execute $execute `
    -Argument "-m chatroom_runner --config `"$ConfigPath`"" `
    -WorkingDirectory $RepoRoot

# 從 Git Bash 起 pwsh 時 $env:USERNAME 可能是空的，會讓 -User 轉型失敗
$user = if ($env:USERNAME) { $env:USERNAME } else { [Environment]::UserName }

$triggers = @(
    # 要括起來：不括的話結尾的逗號會把下一個元素併進 -User 變成陣列
    (New-ScheduledTaskTrigger -AtLogOn -User $user),
    # 存活檢查：工作已經在跑時這個觸發會被 IgnoreNew 擋掉，等於「沒跑才拉起來」
    (New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes 5))
)

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -RestartInterval (New-TimeSpan -Minutes 1) `
    -RestartCount 999 -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew

$principal = New-ScheduledTaskPrincipal -UserId $user `
    -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action `
    -Trigger $triggers -Settings $settings -Principal $principal `
    -Description "Chatroom 遠端派工執行器（REMOTE-OPS-PLAN P2）" `
    -Force:$Force | Out-Null

# 驗證 .pth 真的生效：不驗的話「工作建好了」與「它跑得起來」是兩件事，
# 而失敗只會安靜地寫在工作紀錄的退出碼裡
& $Python -c "import chatroom_runner" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "註冊完成但 import chatroom_runner 失敗：請檢查 $pthFile 是否指向 $runnerDir"
}

Write-Host "已建立排程工作「$TaskName」。"
Write-Host "  Python   : $execute"
Write-Host "  設定檔   : $ConfigPath"
Write-Host "  log      : $env:LOCALAPPDATA\UEP\Chatroom\runner\logs\runner.log"
Write-Host ""
Write-Host "還沒啟動。確認自檢通過後再手動 Start-ScheduledTask -TaskName $TaskName。"
Write-Host "登入層級用 Interactive：GPG 的 pinentry 需要有使用者工作階段，"
Write-Host "改成 S4U/服務帳號會讓簽章在遠端靜默卡住。"
