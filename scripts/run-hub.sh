#!/bin/sh
# Chatroom Hub 前景啟動腳本（macOS / Linux），對應 run-hub.cmd。
#
# 輸出寫到 logs/hub-YYYYMMDD.log（與 Windows 版同一個位置與命名）。用 exec 取代
# 目前的 shell：停止訊號（Ctrl-C、kill）直接送到 Hub 本體，不會停在中間這一層。
# 要常駐請改用 service.py（systemd 使用者服務／LaunchAgent），它的 log 另外寫在
# 安裝根目錄的 hub/logs/。

SCRIPTS=$(cd "$(dirname "$0")" && pwd) || exit 1
ROOT=$(dirname "$SCRIPTS")
PY="$ROOT/.venv/bin/python"

if [ ! -x "$PY" ]; then
    echo "找不到 $PY，請先跑 install.sh 建好虛擬環境。" >&2
    exit 1
fi

LOGDIR="$ROOT/logs"
mkdir -p "$LOGDIR" || exit 1
LOGFILE="$LOGDIR/hub-$(date +%Y%m%d).log"

cd "$ROOT/server" || exit 1
# 互動終端機上先講輸出去哪了：不然畫面一片空白，像是當掉
if [ -t 1 ]; then
    echo "Hub 啟動中，輸出寫到 $LOGFILE（Ctrl-C 停止）"
fi
exec "$PY" -m chatroom_server >> "$LOGFILE" 2>&1
