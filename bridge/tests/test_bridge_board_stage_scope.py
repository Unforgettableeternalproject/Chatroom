"""`chatroom_board(checklist_id=...)`：只讀某一個階段的卡。

起因：一個派工 agent 要找某階段底下還沒做完的那兩張卡的 `task_id`，而板
全量回 **72,970 字元**，超過它單次讀得下的量。bridge 原本只有
`objective_id`（週期）粒度——一期底下十幾個階段、上百張卡，那個粒度對它
一樣讀不動。

過濾在 **Hub**（與 `objective_id` 同一層，`_cycle_scope`），bridge 只負責
把參數原樣帶過去。所以這裡釘的是**參數真的有送出去**：漏送的症狀是安靜地
回整塊板，而那正是呼叫端讀不下的那一份。
"""

from chatroom_mcp import server as srv

ROOM = "room-1"
BOARD = "board-1"
STAGE = "checklist-1"


def _join(fake_hub):
    fake_hub.json("POST", f"/api/rooms/{ROOM}/join",
                  {"participant_id": "pid-1", "display_name": "Novia",
                   "rejoined": False})
    srv.chatroom_join(ROOM)


def _stage_body():
    return {"board_id": BOARD, "board_seq": 9, "full": True,
            "objectives": [{"id": "obj-1", "title": "JSAI-2383"}],
            "checklists": [{"id": STAGE, "title": "要的那個階段"}],
            "tasks": [{"id": "t-1", "title": "卡"}],
            "filtered": {"scope": "checklist", "checklist_id": STAGE,
                         "objective_id": "obj-1"}}


def test_the_stage_id_reaches_the_hub_on_the_board_axis(fake_hub):
    fake_hub.json("GET", f"/api/boards/{BOARD}", _stage_body())
    out = srv.chatroom_board(board_id=BOARD, checklist_id=STAGE)
    assert fake_hub.calls[-1].url.params["checklist_id"] == STAGE
    assert out["filtered"]["checklist_id"] == STAGE


def test_the_stage_id_reaches_the_hub_on_the_room_axis(fake_hub):
    """房裡的 agent 多半是拿 room_id 讀板的——只接上板軸等於沒接。"""
    _join(fake_hub)
    fake_hub.json("GET", f"/api/rooms/{ROOM}/board", _stage_body())
    srv.chatroom_board(ROOM, checklist_id=STAGE)
    assert fake_hub.calls[-1].url.params["checklist_id"] == STAGE


def test_not_passing_it_sends_an_empty_value(fake_hub):
    """沒給就是沒給——不要自作主張帶上一次的階段。"""
    fake_hub.json("GET", f"/api/boards/{BOARD}",
                  {"board_id": BOARD, "board_seq": 9, "full": True,
                   "tasks": [], "filtered": None})
    srv.chatroom_board(board_id=BOARD)
    assert fake_hub.calls[-1].url.params["checklist_id"] == ""


def test_an_unknown_stage_comes_back_as_a_machine_readable_code(fake_hub):
    """找不到要看得出 code——呼叫端要能分辨「階段 id 錯了」與「板讀不到」。"""
    fake_hub.error("GET", f"/api/boards/{BOARD}", 404,
                   {"code": "checklist_not_found",
                    "message": "這塊板上沒有這個階段"})
    out = srv.chatroom_board(board_id=BOARD, checklist_id="nope")
    assert out["ok"] is False
    assert "checklist_not_found" in repr(out)


def test_the_docstring_tells_you_to_use_it_instead_of_a_full_read(fake_hub):
    """⚠️ 這條釘的是**入口**：參數做好了而描述沒講，讀的人照舊全量讀一次
    再撞一次上限——而那正是這張卡要消除的東西。

    釘的是那句話的存在與位置（在全量警告附近），不是逐字文案。
    """
    doc = srv.chatroom_board.__doc__ or ""
    assert "checklist_id" in doc
    assert doc.index("全量") < doc.index("checklist_id"), (
        "階段那段要接在全量警告後面——讀到警告的人才是需要它的人")
