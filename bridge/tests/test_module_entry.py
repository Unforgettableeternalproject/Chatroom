"""`python -m chatroom_mcp` 與 console script 等價。

console script 是一個 `.exe`，而 pip 升級必須覆寫那個檔案——agent 跑著時
它被獨佔，原地升級就撞 `WinError 32`（測試端 2026-09-09 在真機重現，而
上午那次沒撞是因為連線剛好自己斷了，不是問題修好了）。走 `-m` 的話升級只
覆寫 `.py`，沒有被獨佔的執行檔。

⚠️ 這條路存在不代表有人走：**要 MCP 設定改成 `python -m chatroom_mcp`
才吃得到**，那是安裝器那側的決定。這裡守的是「那條路真的通、而且與 exe
同一個入口」——否則換設定的那天才會發現它不通。
"""

import subprocess
import sys
from pathlib import Path

BRIDGE = Path(__file__).resolve().parents[1]


def test_module_entry_starts_the_same_server():
    """stdin 立刻 EOF ⇒ server 正常收工；banner 與 console script 同一份。"""
    proc = subprocess.run(
        [sys.executable, "-m", "chatroom_mcp"],
        cwd=BRIDGE, stdin=subprocess.DEVNULL,
        capture_output=True, text=True, timeout=60,
    )
    assert proc.returncode == 0, proc.stderr
    # main() 開頭印的那行——兩條入口都會經過它
    assert "[chatroom-mcp]" in proc.stderr


def test_module_entry_delegates_to_server_main():
    """入口只有一個。第二條啟動路徑遲早會與第一條長得不一樣。"""
    source = (BRIDGE / "chatroom_mcp" / "__main__.py").read_text(encoding="utf-8")
    assert "from .server import main" in source
    assert "main()" in source
