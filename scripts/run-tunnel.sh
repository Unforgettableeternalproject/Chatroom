#!/bin/sh
# 把本機 Hub 經 Cloudflare Quick Tunnel 轉發到公網（macOS / Linux），
# 對應 run-tunnel.cmd。Hub 必須已經在跑：隧道只轉發，不會替你啟動它。
#
# 兩種進來的方式，行為相反：
#   終端機直接跑          -> 輸出留在畫面上，失敗才看得到原因
#   App 的「開隧道」按鈕   -> 沒有視窗（CHATROOM_HIDDEN=1），輸出必須進 log
# 網址本身兩種都不會遺失：tunnel.py 會寫 server/.tunnel-url，App 讀那個檔。

SCRIPTS=$(cd "$(dirname "$0")" && pwd) || exit 1
ROOT=$(dirname "$SCRIPTS")
PY="$ROOT/.venv/bin/python"

if [ ! -x "$PY" ]; then
    echo "找不到 $PY，請先跑 install.sh 建好虛擬環境。" >&2
    exit 1
fi

if [ "${CHATROOM_HIDDEN:-}" = "1" ]; then
    LOGDIR="$ROOT/logs"
    mkdir -p "$LOGDIR" || exit 1
    exec "$PY" "$SCRIPTS/tunnel.py" "$@" >> "$LOGDIR/tunnel-$(date +%Y%m%d).log" 2>&1
fi
exec "$PY" "$SCRIPTS/tunnel.py" "$@"
