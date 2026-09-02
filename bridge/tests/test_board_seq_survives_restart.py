"""board_seq 要跨 bridge 重啟活下來。

## 缺陷（既有，非 Board V2 造成）

`BridgeState._load()` 用**白名單重建**每個房間的 entry，只保留

    participant_id / display_name / last_seq / session_key

`board_seq` 不在白名單裡 ⇒ **寫得進檔案，讀不回來**。

實測（我自己的 state 檔）：

    檔案裡    board_seq = 14   last_seq = 113
    載入後    board_seq =  0   last_seq = 113   ← 訊息游標活著，板水位歸零

## 根因

- 白名單寫於 `5c664a5`（P2-01~03，bridge 初期）
- `board_seq` 在 `107f871`（09/01，Board 的四個 MCP 工具）才加進 state
- **加欄位時沒有同步更新載入白名單** —— 白名單式重建的典型陷阱：
  新欄位在寫入端加一次就以為完成了，讀取端是另一個地方

## 為什麼既有測試抓不到

`bridge/tests/test_board_tools.py` 有 `assert srv.state().board_seq(ROOM) == 12`，
但那是**同一個進程內**的記憶體值，沒有經過「寫檔 → 重新載入」的往返。
本檔補的就是那一趟往返。

## 影響

1. bridge 每次重啟，板水位歸零
2. 歸零後 `known_board == 0`，`chatroom_wait` 回的是 `board_unread=true`
   而非 `board_changed` ⇒ **「重啟過」與「從來沒讀過這塊板」變成同一件事**，
   而這兩者本來是刻意分開的（見 `server.py:726` 的註解）
3. T6 要驗「升級後游標不遺失」——板水位這一半**現在就已經遺失**，
   而且與升級無關，單純重啟就會

⚠️ 這條在修好之前會紅，那是它該有的樣子。
"""

import json

from chatroom_mcp.state import BridgeState

ROOM = "room-abc"


def test_board_seq_survives_a_reload(tmp_path):
    """寫入 → 換一個 BridgeState 實例載入 → 水位要還在。

    這是「重啟 bridge」的最小模型：同一個檔案，新的物件。
    """
    path = tmp_path / "state.json"

    first = BridgeState(path)
    first.set_board_seq(ROOM, 42)
    first.set_last_seq(ROOM, 100)

    # 前提：確實寫進檔案了（不然這條測的是別的東西）
    raw = json.loads(path.read_text(encoding="utf-8"))
    assert raw["rooms"][ROOM]["board_seq"] == 42, "前提：board_seq 要先寫得進檔案"

    reborn = BridgeState(path)
    assert reborn.last_seq(ROOM) == 100, "對照組：訊息游標本來就活得下來"
    assert reborn.board_seq(ROOM) == 42, (
        "板水位在重新載入後歸零了——BridgeState._load() 的白名單重建漏了 "
        "board_seq。加欄位時要同時改寫入端與載入端"
    )


def test_unknown_room_still_starts_at_zero(tmp_path):
    """沒看過的房間水位是 0——修白名單時不要把預設值也一起弄壞。"""
    state = BridgeState(tmp_path / "state.json")
    assert state.board_seq("never-seen") == 0


def test_every_written_field_survives_a_reload(tmp_path):
    """防漏：**寫得進去的欄位，載入端都要收得回來**。

    board_seq 掉了半天的根因不是打錯字，是白名單式重建的結構陷阱——
    寫入端加一個欄位就以為完成了，而載入端在另一個地方，沒有任何東西
    會提醒你。這條把「忘了」變成一個會紅的事實：下一個人加欄位時，
    只要沒同步改 `_load()` 的白名單，這裡就會指名道姓地說是哪一個。
    """
    path = tmp_path / "state.json"
    state = BridgeState(path)
    # 呼叫**所有**寫入端 API，讓檔案裡出現這個版本會寫的每一個欄位
    state.set_identity(ROOM, "pid-1", "Novia", session_key="claude-x")
    state.set_last_seq(ROOM, 7)
    state.set_board_seq(ROOM, 9)

    written = set(json.loads(path.read_text(encoding="utf-8"))["rooms"][ROOM])
    reloaded = set(BridgeState(path)._rooms[ROOM])
    assert written <= reloaded, (
        f"這些欄位寫得進 state.json 卻讀不回來：{sorted(written - reloaded)}。"
        "BridgeState._load() 的白名單要跟著寫入端一起改"
    )
