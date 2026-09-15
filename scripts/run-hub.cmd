@echo off
rem Chatroom Hub launcher (also used by the scheduled task).
rem
rem ASCII ONLY. cmd.exe reads .cmd files using the system ANSI code page, so
rem non-ASCII comments turn into mojibake that swallows the `rem` keyword and
rem the leftovers get executed as commands -- that produced two red error lines
rem on every start until 2026-09-11. See tests/test_cmd_scripts_encoding.py.
rem
rem Redirection is done by cmd itself, not PowerShell: PowerShell's `*>>` wraps
rem stderr into NativeCommandError noise (hit before in another scheduled task).
rem Logs are split per day: logs\hub-YYYYMMDD.log
rem %DATE% formatting depends on the system locale and must not be sliced --
rem PowerShell is used to get a stable date instead.
setlocal
cd /d "%~dp0..\server"
set LOGDIR=%~dp0..\logs
if not exist "%LOGDIR%" mkdir "%LOGDIR%"
for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd"') do set D=%%i
"%~dp0..\.venv\Scripts\python.exe" -m chatroom_server >> "%LOGDIR%\hub-%D%.log" 2>&1
