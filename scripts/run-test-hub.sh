#!/usr/bin/env bash
# 測試用 Hub（port 8788）——subagent identity 的 C5/C6 需要秒級時限，
# 不能在共用的正式那台（8787）上跑，那會把所有人的 agent 掃出房間。
#
# 🔑 **從 git worktree 起，不從共用工作區起**（09/02 定的，09/05 補進腳本）。
# `build_info()` 的 dirty 判定含未追蹤檔案，而這棵樹隨時有三個人在改 ⇒
# 從共用工作區起的 Hub 幾乎必然是 `-dirty` build，測出來的結果對不回任何
# commit，工作區一被蓋過就世界上不存在第二份、重現不了。
# 09/04 那次沒中是**碰巧**樹剛好乾淨，不是機制有效。
#
# 佔用：TCP 8788、test_resources/hub-test.db*、test_resources/hub-test-attachments/、
#       logs/hub-test/。完全不碰正式資料庫。
# 關法：Ctrl-C。要清資料就刪掉上面那三個路徑（.db 記得連 -wal / -shm）。
#
# 用法：從 repo 根目錄執行 ./scripts/run-test-hub.sh [目標 commit]
#       不給 commit 就沿用 worktree 目前的 HEAD。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WT="$ROOT/.claude/worktrees/hub-8788"
# 預設 8788。`TEST_HUB_PORT` 是給**驗這支腳本本身**用的——要確認正常啟動那條
# 路徑還通，總不能先把大家在用的 8788 停掉。DB 與附件目錄不跟著換，所以換 port
# 起的那台看到的是同一份資料，只適合當場驗完就關。
PORT="${TEST_HUB_PORT:-8788}"

if [ ! -d "$WT/server" ]; then
  echo "✖ 找不到 worktree：$WT" >&2
  echo "  先建一個（detached，指到你要測的 commit）：" >&2
  echo "    git worktree add --detach \"$WT\" <commit>" >&2
  exit 1
fi

# 🚨 **port 被佔就停手，不要讓舊進程頂替。**
# 這是 09/05 實際踩到的：bind 失敗 uvicorn 以 exit 3 退場，而 `curl health`
# **仍然有回應**——回話的是前一天就在跑的舊進程。差一步就把位址交給跨裝置
# 測試端，他會在昨天的程式碼上驗今天的新行為，每一項都安靜地驗不到，
# 而且長得像「功能沒做」不像「你打錯機器」。
if command -v netstat >/dev/null 2>&1 &&
   netstat -ano 2>/dev/null | grep -E "[:.]$PORT[[:space:]].*LISTEN" >/dev/null; then
  echo "✖ port $PORT 已經有東西在聽——**先確認那是誰**，不要直接再起一個。" >&2
  echo "  現在跑著的是什麼版本：" >&2
  echo "    curl -s http://127.0.0.1:$PORT/api/health" >&2
  echo "  它是誰起的（看 PID，並注意 launcher 會 spawn 子進程，要看整條樹）：" >&2
  echo "    netstat -ano | grep :$PORT" >&2
  echo "  確定要換掉的話，先收掉那個進程再重跑本腳本。" >&2
  exit 1
fi

if [ $# -ge 1 ]; then
  git -C "$WT" checkout --detach "$1"
fi

# 版本要在起之前就講出來——起完才問等於相信 health，而 health 分不出
# 「回話的是誰起的進程」
HEAD_SHA="$(git -C "$WT" rev-parse --short=12 HEAD)"
DIRTY="$(git -C "$WT" status --porcelain)"
echo "worktree : $WT"
echo "commit   : $HEAD_SHA"
if [ -n "$DIRTY" ]; then
  # 不擋，但要講：worktree 髒掉多半是有人手改過它，那份產物對不回 commit
  echo "⚠️  worktree 有未提交的變更 ⇒ build 會是 -dirty，對不回任何 commit：" >&2
  echo "$DIRTY" | sed 's/^/    /' >&2
fi

mkdir -p "$ROOT/test_resources/hub-test-attachments" "$ROOT/logs/hub-test"

cd "$WT/server"

# ⚠️ **五個路徑一律用主 repo 的絕對路徑。** worktree 裡沒有 `.env`、也沒有
# `test_resources/`（都在 gitignore） ⇒ 相對路徑會讓 Hub 在 worktree 裡開一個
# **全新空庫**，測試房全部「消失」而且照樣回 200。
#
# CHATROOM_TOKEN 由主 repo 的 server/.env 自動補上（載入器只補缺、不覆寫），
# 與正式那台同一把——測試端才不必換設定
set -a
# shellcheck disable=SC1091
[ -f "$ROOT/server/.env" ] && . "$ROOT/server/.env"
set +a

export CHATROOM_PORT=$PORT
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

# venv 在主 repo，worktree 沒有自己的
exec "$ROOT/.venv/Scripts/python.exe" -m chatroom_server
