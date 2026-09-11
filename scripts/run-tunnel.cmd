@echo off
rem Forward the local Hub through a Cloudflare Quick Tunnel (double-click to run).
rem The Hub must already be running: a tunnel only forwards, it does not start it.
rem
rem ASCII ONLY. cmd.exe reads .cmd files using the system ANSI code page, so
rem non-ASCII comments turn into mojibake that swallows the `rem` keyword and
rem the leftovers get executed as commands. See tests/test_cmd_scripts_encoding.py
rem and host-kit/README.md for the Chinese notes.
rem
rem Two ways in, and they need opposite behaviour:
rem   double-click     -> keep the output on screen, pause so failures are read
rem   App "open tunnel" -> no window at all (hidden-launch.vbs sets
rem                       CHATROOM_HIDDEN=1), so the output must go to the log
rem                       and `pause` must NOT run: a pause in a hidden window
rem                       waits forever for a key nobody can press.
rem The URL itself is not lost either way -- tunnel.py writes server\.tunnel-url
rem and the App reads it.
setlocal
set LOGDIR=%~dp0..\logs
if not exist "%LOGDIR%" mkdir "%LOGDIR%"
for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd"') do set D=%%i
set LOGFILE=%LOGDIR%\tunnel-%D%.log
if "%CHATROOM_HIDDEN%"=="1" (
    "%~dp0..\.venv\Scripts\python.exe" "%~dp0tunnel.py" %* >> "%LOGFILE%" 2>&1
) else (
    "%~dp0..\.venv\Scripts\python.exe" "%~dp0tunnel.py" %*
    if errorlevel 1 pause
)
