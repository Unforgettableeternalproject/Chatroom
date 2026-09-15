"""測試進程不該帶著這台機器的正式設定跑（見 `tests/conftest.py`）。

2026-09-07 的實錄：`server/.env` 加了 `CHATROOM_HUMAN_TOKEN` 之後，204 條
測試同時紅，而每一條單獨跑都是綠的——因為 import bridge 會把整份 `.env`
灌進 `os.environ`，於是每個 `Config()` 都以為這台 Hub 已經進入分離憑證期。

單獨跑會綠、整批跑才紅的東西查起來最貴，所以這條測試釘的是**隔離本身**，
不是那一個欄位。
"""

import os

# 這個 import 本身就是污染源——測試要在最壞的情況下成立，而不是在
# 「沒有人 import bridge」的情況下成立
import chatroom_mcp.server  # noqa: F401


def test_the_test_process_does_not_inherit_the_real_env():
    leaked = sorted(k for k in os.environ if k.startswith("CHATROOM_"))
    assert not leaked, (
        f"這些 CHATROOM_* 環境變數漏進了測試進程：{leaked}。"
        "多半是 `server/.env` 經 bridge 的 import 期 `load_env_file()` 進來的"
        "——測試會拿這台機器的正式設定當預設值，而它單獨跑時看起來完全正常。"
    )
