# Chatroom Hub 服務管理（Windows 排程任務版）。
#
#   pwsh -File scripts/hub-service.ps1 install     # 註冊開機自啟（不立即啟動）
#   pwsh -File scripts/hub-service.ps1 start|stop  # 手動啟停（stop 會停用
#                                                  # 觸發器，start 自動啟用回來）
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
# 停止後要驗證埠真的空了。port 讀 server/.env，沒有就用預設值
$Port = 8787
$EnvFile = Join-Path $PSScriptRoot '..\server\.env'
if (Test-Path $EnvFile) {
    $line = Select-String -Path $EnvFile -Pattern '^CHATROOM_PORT=(.+)$' |
        Select-Object -First 1
    if ($line) { $Port = $line.Matches[0].Groups[1].Value.Trim() }
}

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
        # 對稱於 stop 的停用：不先啟用的話，停過一次之後就再也起不來
        Enable-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null
        Start-ScheduledTask -TaskName $TaskName
        Write-Output "已啟動 $TaskName"
    }
    'stop' {
        # 先停用觸發器再殺進程。這個任務設了失敗自動重啟（RestartCount 999、
        # 每分鐘重試），只 Stop-ScheduledTask 加殺進程的話，排程會在一分鐘內
        # 把 Hub 拉回來——`stop` 看起來成功了，Hub 卻還活著。
        Disable-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        # wrapper 是 cmd → python 兩層，排程停止只殺得掉 cmd；把 Hub 本體一併收掉
        Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
            Where-Object { $_.CommandLine -match 'chatroom_server' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
        Start-Sleep -Seconds 2
        $still = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        if ($still) {
            Write-Warning "埠 $Port 仍有監聽（PID $($still.OwningProcess)）——可能有手動啟動的 Hub，排程管不到它"
        } else {
            Write-Output "已停止 $TaskName（觸發器已停用；start 會自動重新啟用）"
        }
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
