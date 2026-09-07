"""測試不吃真實的 `server/.env`。

**為什麼需要這個檔**：`bridge/chatroom_mcp/server.py` 在 **import 期**呼叫
`load_env_file()`（它必須那樣做——bridge 的設定在 import 期就固定下來）。而
`tests/` 底下有十來個檔會 import bridge 來驗契約，於是**光是收集測試就把
`server/.env` 的每一個 `CHATROOM_*` 灌進了整個 pytest 進程**。

之後每一個 `Config(...)` 沒有顯式覆寫的欄位，讀到的都是這台機器的正式設定。

這件事一直都在，只是恰好沒有咬人：測試多半顯式傳 `api_token`，而其餘欄位
的正式值與預設值相近。2026-09-07 加了 `CHATROOM_HUMAN_TOKEN` 之後當場爆開
——那天正式 `.env` 剛加了那把 token，於是**所有 `role=human` 的 join 一律
403**，204 條測試同時紅，而每一條單獨跑都是綠的。

⚠️ 這裡清的是 `os.environ`，不是 `.env`。清的時機在收集之後、測試之前，
所以 import 期的污染救得回來——`Config` 的欄位是在**建立實例**時才讀環境。
"""

import os

import pytest


@pytest.fixture(autouse=True, scope="session")
def _no_ambient_chatroom_env():
    """把 `CHATROOM_*` 從環境裡拿掉，跑完再放回去。

    整段清掉而不是只清 human token：下一個被加進 `.env` 的欄位不會來提醒
    我們補這份名單，而它咬人的方式與今天一模一樣。
    """
    saved = {k: v for k, v in os.environ.items() if k.startswith("CHATROOM_")}
    for k in saved:
        del os.environ[k]
    try:
        yield
    finally:
        os.environ.update(saved)
