@echo off
rem 把本機 Hub 轉發到 Cloudflare Quick Tunnel（雙擊即可）。
rem Hub 要先跑著——隧道只是轉發，不會替你把 Hub 叫起來。
setlocal
"%~dp0..\.venv\Scripts\python.exe" "%~dp0tunnel.py" %*
if errorlevel 1 pause
