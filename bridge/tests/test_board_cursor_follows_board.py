"""板水位跟著**板**走，不跟著房走。

一塊板可以掛多間房（Board v2）。水位若記在房上，同一次板變更會在每一間
房各算出一次「board 動了」——同一個 agent 被叫醒 N 次，而 Hub 那邊就算
只出一筆 canonical event 也擋不住（@開發Novia (除錯) 2026-09-02 實測，
`board_changed` 是 bridge 自己算的，不是 Hub 回的）。

這份測試釘的是那個共用：**讀一次板，掛著它的每一間房都不再報變動。**
"""

import pytest

from chatroom_mcp import server as srv

ROOM_A = "room-a"
ROOM_B = "room-b"
BOARD = "board-1"
_OMIT = object()   # 舊 Hub 連這個鍵都沒有，與「有鍵但 null」是兩件事


def _join(fake_hub, room):
    fake_hub.json(
        "POST",
        f"/api/rooms/{room}/join",
        {"participant_id": f"pid-{room}", "display_name": "Aster",
         "rejoined": False},
    )
    srv.chatroom_join(room)


def _read_board(fake_hub, room, seq, board_id=BOARD):
    payload = {"board_seq": seq, "full": True, "tasks": []}
    if board_id is not _OMIT:
        payload["board_id"] = board_id
    fake_hub.json("GET", f"/api/rooms/{room}/board", payload)
    return srv.chatroom_board(room)


def _wait(fake_hub, room, board_seq, board_id=BOARD):
    payload = {"messages": [], "last_seq": 0, "board_seq": board_seq}
    if board_id is not _OMIT:
        payload["board_id"] = board_id
    fake_hub.json("GET", f"/api/rooms/{room}/updates", payload)
    return srv.chatroom_wait(room, timeout=0)


def test_reading_the_board_once_clears_it_for_every_attached_room(fake_hub):
    """A 房讀完板，B 房就不該再報 board_changed——那是同一塊板。"""
    _join(fake_hub, ROOM_A)
    _join(fake_hub, ROOM_B)
    # 兩間房都先認識這塊板，並讀到水位 5
    _read_board(fake_hub, ROOM_A, 5)
    assert srv.state().board_cursor(BOARD) == 5

    # B 房從沒自己讀過，但水位是共用的 ⇒ 不是「沒讀過」，也沒有變動
    out = _wait(fake_hub, ROOM_B, 5)
    assert out["board_changed"] is False
    assert out["board_unread"] is False, "B 房被當成沒讀過這塊板"

    # 板真的動了：兩邊都要看得到
    assert _wait(fake_hub, ROOM_A, 6)["board_changed"] is True
    assert _wait(fake_hub, ROOM_B, 6)["board_changed"] is True

    # 從 A 房讀一次就把兩邊一起消掉
    _read_board(fake_hub, ROOM_A, 6)
    assert _wait(fake_hub, ROOM_B, 6)["board_changed"] is False


def test_incremental_read_uses_the_shared_cursor(fake_hub):
    """B 房的增量請求要從共用水位起算，不是從 0 重收整塊板。"""
    _join(fake_hub, ROOM_A)
    _join(fake_hub, ROOM_B)
    _read_board(fake_hub, ROOM_A, 5)

    _wait(fake_hub, ROOM_B, 5)          # B 房從這裡才知道是同一塊板
    _read_board(fake_hub, ROOM_B, 7)
    assert fake_hub.calls[-1].url.params["after_board_seq"] == "5"


def test_old_hub_without_board_id_still_works(fake_hub):
    """舊 Hub 不回 `board_id`——那時退回房內水位。

    不能因為對方沒有這個欄位就當成「沒有板」，那會讓每次 wait 都報一次
    board_unread。
    """
    _join(fake_hub, ROOM_A)
    _read_board(fake_hub, ROOM_A, 4, board_id=_OMIT)
    assert srv.state().board_seq(ROOM_A) == 4
    assert srv.state().room_board(ROOM_A) is None

    out = _wait(fake_hub, ROOM_A, 4, board_id=_OMIT)
    assert out["board_changed"] is False
    assert out["board_unread"] is False


def test_detaching_forgets_the_board(fake_hub):
    """解除掛接之後 Hub 回 board_id: null——那也要記下來。

    留著舊的 board_id，水位會繼續掛在一塊已經不相干的板上，而那條路徑
    不報錯，只是安靜地不再通知。
    """
    _join(fake_hub, ROOM_A)
    _read_board(fake_hub, ROOM_A, 5)
    assert srv.state().room_board(ROOM_A) == BOARD

    _wait(fake_hub, ROOM_A, 0, board_id=None)
    assert srv.state().room_board(ROOM_A) is None


def test_legacy_room_cursor_is_carried_onto_the_board(fake_hub):
    """升級時舊 state 的房內水位要搬到板上，不能丟。

    那是這個 agent 讀到哪裡的唯一紀錄；丟掉會讓它把整塊板重收一次，
    而重收在畫面上看起來像「板突然全部變成新的」。
    """
    _join(fake_hub, ROOM_A)
    srv.state().set_board_seq(ROOM_A, 11)      # 升級前留下的房內水位

    _read_board(fake_hub, ROOM_A, 11)
    assert srv.state().board_cursor(BOARD) == 11
    # 這一次請求仍以舊水位起算，不是 0
    assert fake_hub.calls[-1].url.params["after_board_seq"] == "11"
