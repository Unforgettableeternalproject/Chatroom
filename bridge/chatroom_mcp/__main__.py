"""`python -m chatroom_mcp` 入口。

與 console script `chatroom-mcp` **完全等價**——兩者都只是呼叫
`server.main()`，沒有第二條啟動路徑。

為什麼需要它：console script 是一個 `.exe`，而 pip 升級必須覆寫那個檔案。
agent 跑著的時候那個 exe 被獨佔，於是原地升級撞 `WinError 32`
（測試端 2026-09-09 在真機重現）。走 `-m` 的話升級只覆寫 `.py`，
沒有被獨佔的執行檔。

⚠️ 光有這個檔案不會改變任何事——**要 MCP 設定改成 `python -m chatroom_mcp`
才吃得到**，而那是安裝器那側的決定（既有安裝都得重跑一次安裝器換設定形式）。
這裡只負責讓那條路存在且等價。
"""

from .server import main

main()
