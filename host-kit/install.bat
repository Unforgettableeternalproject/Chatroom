@echo off
rem Chatroom hub installer launcher -- double-click this file.
rem
rem ASCII ONLY, no BOM. cmd.exe reads a batch file byte by byte and re-seeks by
rem byte offset after every goto/call; non-ASCII lines make it land in the
rem middle of a line and execute the leftovers, and a UTF-8 BOM kills the very
rem first line (@echo off stops working and the whole script starts echoing).
rem Both were reproduced on 2026-09-20 -- same rule as scripts\*.cmd, see
rem tests/test_cmd_scripts_encoding.py.
rem
rem Chinese belongs in install.py (Python 3 prints UTF-8) and, for the one
rem message that has to be printed before a Python is found, in
rem install-help.txt. The `chcp 65001` below is what makes install.py's UTF-8
rem output readable: a Traditional Chinese console defaults to cp950.
chcp 65001 >nul
setlocal EnableExtensions
cd /d "%~dp0."

set "PYCMD="
set "OLDVER="
call :probe py -3.12
call :probe py -3
call :probe python

if not defined PYCMD goto :nopython

%PYCMD% "%~dp0install.py" %*
set "RC=%ERRORLEVEL%"

rem Always pause: this window was opened by a double-click, and without it a
rem failure closes before anyone can read why.
echo.
pause
exit /b %RC%

rem ---- Python lookup: py -3.12, then py -3, then python ----
rem Exit code 1 means it ran but is older than 3.12; 2 or more means the
rem command itself is not there. Keeping them apart is what stops "you have
rem Python 3.10" from being reported as "you have no Python at all".
:probe
if defined PYCMD goto :eof
%* -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else 1)" >nul 2>&1
if errorlevel 2 goto :eof
if errorlevel 1 goto :tooold
set "PYCMD=%*"
goto :eof

:tooold
for /f "delims=" %%v in ('%* -c "import sys; print(sys.version.split()[0])" 2^>nul') do set "OLDVER=%%v"
goto :eof

:nopython
echo.
if defined OLDVER echo    Python %OLDVER%
type "%~dp0install-help.txt"
echo.
pause
exit /b 1
