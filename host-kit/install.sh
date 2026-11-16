#!/bin/sh
# Chatroom Hub 安裝入口（macOS / Linux），對應 install.bat：找一個夠新的
# Python（3.12+）再跑同目錄的 install.py，參數原樣轉交。
#
# POSIX sh、LF 行尾（.gitattributes 與打包都會保證）。解壓後若沒有執行位元，
# 用 `sh install.sh` 也能跑。

DIR=$(cd "$(dirname "$0")" && pwd) || exit 1

PYCMD=""
OLDVER=""

# 依序試 python3.12 → python3 → python。
# 「有這個指令但版本太舊」與「根本沒有這個指令」要分開：不然使用者手上明明
# 有 Python 3.10，卻被告知「你沒有 Python」。
probe() {
    [ -n "$PYCMD" ] && return 0
    command -v "$1" >/dev/null 2>&1 || return 0
    if "$1" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else 1)' >/dev/null 2>&1; then
        PYCMD="$1"
    else
        OLDVER=$("$1" -c 'import sys; print(sys.version.split()[0])' 2>/dev/null) || OLDVER=""
    fi
    return 0
}

probe python3.12
probe python3
probe python
# PATH 上找不到時，再看幾個常見的安裝位置：uv 與 Homebrew 裝的 Python
# 不一定在非互動 shell 的 PATH 裡（例如 ~/.local/bin 沒被加進去）
if [ -z "$PYCMD" ]; then
    for cand in \
        "$HOME/.local/bin/python3.12" \
        "$HOME"/.local/share/uv/python/cpython-3.12*/bin/python3.12 \
        /opt/homebrew/bin/python3.12 \
        /usr/local/bin/python3.12; do
        [ -x "$cand" ] && probe "$cand"
    done
fi

if [ -z "$PYCMD" ]; then
    echo
    if [ -n "$OLDVER" ]; then
        echo "   找到 Python $OLDVER，但這個安裝器需要 Python 3.12 以上。"
    else
        echo "   找不到 Python。這個安裝器需要 Python 3.12 以上。"
    fi
    echo
    case "$(uname -s)" in
        Darwin)
            echo "   macOS 任選一種："
            echo "       brew install python@3.12                    （有 Homebrew 的話）"
            echo "       uv python install 3.12                      （有 uv 的話）"
            echo "       或從 https://www.python.org/downloads/ 下載安裝程式"
            ;;
        *)
            echo "   Debian／Ubuntu："
            echo "       sudo apt install python3.12 python3.12-venv"
            echo "   Fedora："
            echo "       sudo dnf install python3.12"
            echo "   其他發行版請從套件庫或 https://www.python.org/downloads/ 取得，"
            echo "   並確認 venv 模組可用（Debian 系要另外裝 python3-venv）。"
            ;;
    esac
    echo
    echo "   裝好之後重新執行：sh install.sh"
    exit 1
fi

exec "$PYCMD" "$DIR/install.py" "$@"
