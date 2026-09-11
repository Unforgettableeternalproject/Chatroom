@echo off
rem Forward the local Hub through a Cloudflare Quick Tunnel (double-click to run).
rem The Hub must already be running: a tunnel only forwards, it does not start it.
rem
rem ASCII ONLY. cmd.exe reads .cmd files using the system ANSI code page, so
rem non-ASCII comments turn into mojibake that swallows the `rem` keyword and
rem the leftovers get executed as commands. See tests/test_cmd_scripts_encoding.py
rem and host-kit/README.md for the Chinese notes.
setlocal
"%~dp0..\.venv\Scripts\python.exe" "%~dp0tunnel.py" %*
if errorlevel 1 pause
