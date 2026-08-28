# Chatroom Hub 服務管理（Windows 排程任務版）。
#
#   pwsh -File scripts/hub-service.ps1 install     # 註冊開機自啟（不立即啟動）
#   pwsh -File scripts/hub-service.ps1 start|stop  # 手動啟停
#   pwsh -File scripts/hub-service.ps1 status      # 查狀態
#   pwsh -File scripts/hub-service.ps1 uninstall   # 移除
#
# 檔案帶 UTF-8 BOM，Windows PowerShell 5.1 直接執行也不會把中文讀成 ANSI。
#
# 選型：排程任務而非 NSSM——零外部依賴、內建失敗重啟（RestartCount），
# 單使用者基礎設施夠用。LogonType S4U：不必儲存密碼、未登入也能跑。
# 日誌由 run-hub.cmd 落在 logs\hub-YYYYMMDD.log。
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('install', 'uninstall', 'start', 'stop', 'status')]
    [string]$Action
)

$TaskName = 'ChatroomHub'
$Wrapper = Join-Path $PSScriptRoot 'run-hub.cmd'

switch ($Action) {
    'install' {
        if (-not (Test-Path (Join-Path $PSScriptRoot '..\.venv\Scripts\python.exe'))) {
            Write-Error '找不到 .venv，請先建立專案虛擬環境'; exit 1
        }
        # 注意：PowerShell 變數不分大小寫，內部變數不可叫 $action（撞參數 $Action）
        $taskAction = New-ScheduledTaskAction -Execute $Wrapper
        # AtStartup + S4U（未登入也跑）需要系統管理員；一般權限退回
        # AtLogOn + Interactive（登入時啟動）——個人機日常等價
        $isAdmin = [Security.Principal.WindowsPrincipal]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($isAdmin) {
            $taskTrigger = New-ScheduledTaskTrigger -AtStartup
            $taskPrincipal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U
            $mode = '開機自啟（未登入也跑）'
        } else {
            $taskTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
            $taskPrincipal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
            $mode = '登入時自啟（要開機層級請以系統管理員重跑 install）'
        }
        # 失敗每分鐘重試、無限次；不限執行時長（常駐進程）
        $taskSettings = New-ScheduledTaskSettingsSet `
            -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
            -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $TaskName -Action $taskAction `
            -Trigger $taskTrigger -Settings $taskSettings `
            -Principal $taskPrincipal -Force | Out-Null
        Write-Output "已註冊排程任務 $TaskName——$mode。立即啟動請執行：hub-service.ps1 start"
        Write-Output '注意：啟動前先關掉手動跑著的 Hub，否則 port 會衝突。'
    }
    'uninstall' {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Output "已移除 $TaskName"
    }
    'start' {
        Start-ScheduledTask -TaskName $TaskName
        Write-Output "已啟動 $TaskName"
    }
    'stop' {
        Stop-ScheduledTask -TaskName $TaskName
        # wrapper 是 cmd → python 兩層，排程停止只殺得掉 cmd；把 Hub 本體一併收掉
        Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
            Where-Object { $_.CommandLine -match 'chatroom_server' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
        Write-Output "已停止 $TaskName"
    }
    'status' {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($null -eq $task) { Write-Output '未註冊'; exit 0 }
        $info = Get-ScheduledTaskInfo -TaskName $TaskName
        Write-Output "狀態：$($task.State)　上次執行：$($info.LastRunTime)（結果 $($info.LastTaskResult)）"
        $proc = Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
            Where-Object { $_.CommandLine -match 'chatroom_server' }
        if ($proc) {
            Write-Output "Hub 進程：PID $($proc.ProcessId)"
        } else {
            Write-Output 'Hub 進程：未在執行'
        }
    }
}
