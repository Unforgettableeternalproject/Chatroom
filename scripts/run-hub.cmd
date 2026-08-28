@echo off
rem Chatroom Hub 啟動 wrapper（排程任務用）。
rem 用 cmd 原生重導日誌——PowerShell 的 *>> 會把 stderr 包成
rem NativeCommandError 噪音（先前在其他排程踩過）。
rem 日誌按日分檔：logs\hub-YYYYMMDD.log
setlocal
cd /d "%~dp0..\server"
set LOGDIR=%~dp0..\logs
if not exist "%LOGDIR%" mkdir "%LOGDIR%"
rem %DATE% 格式依系統地區而變，不可切片——用 PowerShell 取日期
for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd"') do set D=%%i
"%~dp0..\.venv\Scripts\python.exe" -m chatroom_server >> "%LOGDIR%\hub-%D%.log" 2>&1
