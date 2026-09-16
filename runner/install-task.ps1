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

# 用 PYTHONPATH 指到 runner/，而不是 cd 進去：工作目錄留給 repo root，
# 這樣 log 與相對路徑的意義跟手動跑的時候一致
$action = New-ScheduledTaskAction `
    -Execute $Python `
    -Argument "-m chatroom_runner --config `"$ConfigPath`"" `
    -WorkingDirectory $RepoRoot

$triggers = @(
    New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME,
    # 存活檢查：工作已經在跑時這個觸發會被 IgnoreNew 擋掉，等於「沒跑才拉起來」
    (New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes 5))
)

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -RestartInterval (New-TimeSpan -Minutes 1) `
    -RestartCount 999 -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME `
    -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action `
    -Trigger $triggers -Settings $settings -Principal $principal `
    -Description "Chatroom 遠端派工執行器（REMOTE-OPS-PLAN P2）" `
    -Force:$Force | Out-Null

Write-Host "已建立排程工作「$TaskName」。"
Write-Host "  Python   : $Python"
Write-Host "  設定檔   : $ConfigPath"
Write-Host "  log      : $env:LOCALAPPDATA\UEP\Chatroom\runner\logs\runner.log"
Write-Host ""
Write-Host "還沒啟動。確認自檢通過後再手動 Start-ScheduledTask -TaskName $TaskName。"
Write-Host "登入層級用 Interactive：GPG 的 pinentry 需要有使用者工作階段，"
Write-Host "改成 S4U/服務帳號會讓簽章在遠端靜默卡住。"
