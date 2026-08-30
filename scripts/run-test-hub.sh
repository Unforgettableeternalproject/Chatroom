#!/usr/bin/env bash
# 測試用 Hub（port 8788）——subagent identity 的 C5/C6 需要秒級時限，
# 不能在共用的正式那台（8787）上跑，那會把所有人的 agent 掃出房間。
#
# 佔用：TCP 8788、test_resources/hub-test.db*、test_resources/hub-test-attachments/、
#       logs/hub-test/。完全不碰正式資料庫。
# 關法：Ctrl-C。要清資料就刪掉上面那三個路徑（.db 記得連 -wal / -shm）。
#
# 用法：從 repo 根目錄執行 ./scripts/run-test-hub.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/test_resources/hub-test-attachments" "$ROOT/logs/hub-test"

cd "$ROOT/server"

# CHATROOM_TOKEN 由 server/.env 自動補上（載入器只補缺、不覆寫），
# 與正式那台同一把——測試端才不必換設定
export CHATROOM_PORT=8788
export CHATROOM_HOST=0.0.0.0                      # 讓另一台裝置連得到
export CHATROOM_DB="$ROOT/test_resources/hub-test.db"
export CHATROOM_ATTACHMENT_DIR="$ROOT/test_resources/hub-test-attachments"
export CHATROOM_LOG_DIR="$ROOT/logs/hub-test"
export CHATROOM_IDLE_TIMEOUT=300                  # 正式 1800。與下面差一個數量級是
                                                  # 刻意的：要驗兩條時限獨立，差 20 秒
                                                  # 只證明得了排序（契約 C5）
export CHATROOM_SUBAGENT_TIMEOUT=5
export CHATROOM_SWEEP_INTERVAL=2                  # 正式 30
export CHATROOM_ARCHIVE_GRACE=10                  # 正式 60
export CHATROOM_PURGE_ARCHIVED_DAYS=0             # 測試機一律關閉自動刪除

exec ../.venv/Scripts/python.exe -m chatroom_server
