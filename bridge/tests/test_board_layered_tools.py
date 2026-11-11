"""任務板分層讀取的 MCP 工具，以及 `moved` 狀態的工具層接線。

釘的事：

1. `chatroom_board` 不帶參數、第一次讀 ＝ 走綱要端點，不是整塊板；水位推進
2. 水位已知 ＝ 增量（舊行為不變）；帶任一舊參數 ＝ 舊端點
3. cycles／outline／item 三支工具打對端點、兩個軸都通，且**不碰水位**
4. `moved` 與 `moved_to` 真的送到 Hub；`moved_to` 不能配別的狀態
"""

import pytest

from chatroom_mcp import server as srv

ROOM = "room-1"
BOARD = "board-1"


def _join(fake_hub):
    fake_hub.json("POST", f"/api/rooms/{ROOM}/join",
                  {"participant_id": "pid-1", "display_name": "Aster",
                   "rejoined": False})
    srv.chatroom_join(ROOM)


def _outline(seq=9, **extra):
    return {"board_id": BOARD, "board_seq": seq, "view": "outline",
            "full": False, "cycle": {"id": "o-1"}, "checklists": [],
            "tasks": [], **extra}


def test_first_read_by_room_is_the_outline_and_moves_the_cursor(fake_hub):
    _join(fake_hub)
    fake_hub.json("GET", f"/api/rooms/{ROOM}/board/outline", _outline(9))
    out = srv.chatroom_board(ROOM)
    assert fake_hub.calls[-1].url.path == f"/api/rooms/{ROOM}/board/outline"
    assert out["view"] == "outline" and out["resolved_board_id"] == BOARD
    assert out["after_board_seq"] == 0
    assert srv.state().board_cursor(BOARD) == 9
    assert srv.state().room_board(ROOM) == BOARD


def test_second_read_is_incremental_on_the_old_endpoint(fake_hub):
    _join(fake_hub)
    fake_hub.json("GET", f"/api/rooms/{ROOM}/board/outline", _outline(9))
    srv.chatroom_board(ROOM)
    fake_hub.json("GET", f"/api/rooms/{ROOM}/board",
                  {"board_id": BOARD, "board_seq": 12, "tasks": []})
    srv.chatroom_board(ROOM)
    assert fake_hub.calls[-1].url.path == f"/api/rooms/{ROOM}/board"
    assert fake_hub.calls[-1].url.params["after_board_seq"] == "9"


@pytest.mark.parametrize("kwargs", [
    {"full": True}, {"include_settled": True}, {"objective_id": "o-1"},
    {"checklist_id": "c-1"}])
def test_any_legacy_parameter_keeps_the_old_endpoint(fake_hub, kwargs):
    _join(fake_hub)
    fake_hub.json("GET", f"/api/rooms/{ROOM}/board",
                  {"board_id": BOARD, "board_seq": 3, "tasks": []})
    srv.chatroom_board(ROOM, **kwargs)
    assert fake_hub.calls[-1].url.path == f"/api/rooms/{ROOM}/board"


def test_first_read_by_board_id_is_the_outline(fake_hub):
    fake_hub.json("GET", f"/api/boards/{BOARD}/outline", _outline(5))
    out = srv.chatroom_board(board_id=BOARD)
    assert fake_hub.calls[-1].url.path == f"/api/boards/{BOARD}/outline"
    assert out["resolved_board_id"] == BOARD
    assert srv.state().board_cursor(BOARD) == 5


def test_outline_tool_picks_the_cycle_and_leaves_the_cursor(fake_hub):
    fake_hub.json("GET", f"/api/boards/{BOARD}/outline", _outline(8))
    out = srv.chatroom_board_outline(board_id=BOARD, objective_id="o-2")
    assert fake_hub.calls[-1].url.params["objective_id"] == "o-2"
    assert out["resolved_board_id"] == BOARD
    # 看某個週期不等於讀過這塊板
    assert srv.state().board_cursor(BOARD) == 0


def test_cycles_tool_passes_limit_on_both_axes(fake_hub):
    _join(fake_hub)
    fake_hub.json("GET", f"/api/boards/{BOARD}/cycles",
                  {"cycles": [], "cycles_total": 0})
    srv.chatroom_board_cycles(board_id=BOARD, limit=5)
    assert fake_hub.calls[-1].url.params["limit"] == "5"
    fake_hub.json("GET", f"/api/rooms/{ROOM}/board/cycles",
                  {"board_id": BOARD, "cycles": [], "cycles_total": 0})
    out = srv.chatroom_board_cycles(room_id=ROOM)
    assert fake_hub.calls[-1].url.path == f"/api/rooms/{ROOM}/board/cycles"
    assert out["resolved_board_id"] == BOARD


def test_item_tool_hits_the_item_endpoint(fake_hub):
    fake_hub.json("GET", f"/api/boards/{BOARD}/items/t-1",
                  {"kind": "task", "item": {"id": "t-1"}, "events": []})
    out = srv.chatroom_board_item("t-1", board_id=BOARD)
    assert out["kind"] == "task"
    out = srv.chatroom_board_item("  ", board_id=BOARD)
    assert out["ok"] is False


def test_layered_tools_refuse_both_or_neither_id(fake_hub):
    assert srv.chatroom_board_outline(room_id=ROOM, board_id=BOARD)["ok"] is False
    assert srv.chatroom_board_cycles()["ok"] is False


def test_moved_and_moved_to_reach_the_hub(fake_hub):
    _join(fake_hub)
    fake_hub.json("POST", "/api/board/tasks/t-1/status", {"ok": True})
    srv.chatroom_board_update(ROOM, "t-1", status="moved", moved_to="t-2")
    sent = fake_hub.calls[-1].read()
    assert b'"status":"moved"' in sent.replace(b" ", b"")
    assert b'"moved_to":"t-2"' in sent.replace(b" ", b"")


def test_moved_without_a_destination_sends_no_moved_to(fake_hub):
    _join(fake_hub)
    fake_hub.json("POST", "/api/board/tasks/t-1/status", {"ok": True})
    srv.chatroom_board_update(ROOM, "t-1", status="moved")
    assert b"moved_to" not in fake_hub.calls[-1].read()


def test_moved_to_with_another_status_is_refused(fake_hub):
    _join(fake_hub)
    out = srv.chatroom_board_update(ROOM, "t-1", status="done", moved_to="t-2")
    assert out["ok"] is False and "moved_to" in repr(out)


def test_the_update_docstring_lists_moved_and_how_it_differs_from_cancel():
    doc = srv.chatroom_board_update.__doc__ or ""
    assert "moved" in doc and "moved_to" in doc
    # 要講出「搬走 ≠ 取消」，不然 agent 照樣走取消
    assert doc.index("moved") < doc.index("cancelled", doc.index("moved"))
    assert "不是" in doc
