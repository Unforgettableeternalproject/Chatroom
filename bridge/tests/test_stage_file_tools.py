"""階段素材的 MCP 工具（stage files 契約 2026-09-17）。

工具存在的理由是「這輪的附件該問哪裡」：房是常駐的，歷史附件混著前幾輪
的東西，掃整間房找到的多半不是這次要用的那一份。

這裡釘的是兩件會安靜出錯的事：打到哪一條路徑、以及用 room_id 問時它有沒有
先解析成 board_id（沒解析的話，URL 上的那一段會是房間 id，而 Hub 會回一個
看起來像「板不存在」的 404）。
"""

from chatroom_mcp import server as srv

ROOM = "room-1"
BOARD = "board-1"
STAGE = "checklist-1"


def _join(fake_hub):
    fake_hub.json(
        "POST",
        f"/api/rooms/{ROOM}/join",
        {"participant_id": "pid-1", "display_name": "Novia", "rejoined": False},
    )
    srv.chatroom_join(ROOM)


def test_listing_by_board_id(fake_hub):
    fake_hub.json("GET", f"/api/boards/{BOARD}/checklists/{STAGE}/files",
                  {"files": [{"id": "f1", "attachment_id": "a1",
                              "filename": "login.png", "note": "登入頁"}]})
    out = srv.chatroom_stage_files(STAGE, board_id=BOARD)
    assert [f["id"] for f in out["files"]] == ["f1"]
    assert out["resolved_board_id"] == BOARD
    assert fake_hub.calls[-1].url.path == (
        f"/api/boards/{BOARD}/checklists/{STAGE}/files")


def test_room_id_is_resolved_to_a_board_first(fake_hub):
    """用 room_id 問要先解析成板——直接把房間 id 放進 URL 會變成一個 404。"""
    _join(fake_hub)
    fake_hub.json("GET", f"/api/rooms/{ROOM}/board",
                  {"board_id": BOARD, "board_seq": 1, "full": True,
                   "tasks": []})
    fake_hub.json("GET", f"/api/boards/{BOARD}/checklists/{STAGE}/files",
                  {"files": []})
    out = srv.chatroom_stage_files(STAGE, room_id=ROOM)
    assert out["resolved_board_id"] == BOARD
    assert fake_hub.calls[-1].url.path == (
        f"/api/boards/{BOARD}/checklists/{STAGE}/files")


def test_adding_sends_the_attachment_and_note(fake_hub):
    fake_hub.json("POST", f"/api/boards/{BOARD}/checklists/{STAGE}/files",
                  {"file": {"id": "f2", "attachment_id": "a2",
                            "note": "跑完的截圖"}})
    out = srv.chatroom_stage_file_add(STAGE, "a2", note="跑完的截圖",
                                      board_id=BOARD)
    assert out["file"]["id"] == "f2"
    call = fake_hub.calls[-1]
    assert call.method == "POST"
    assert call.url.path == f"/api/boards/{BOARD}/checklists/{STAGE}/files"


def test_both_ids_or_neither_is_refused(fake_hub):
    """`room_id` 與 `board_id` 都是 32 hex，猜錯不會有任何地方報錯。"""
    both = srv.chatroom_stage_files(STAGE, board_id=BOARD, room_id=ROOM)
    assert both["ok"] is False and "只能給一個" in both["reason"]

    neither = srv.chatroom_stage_file_add(STAGE, "a1")
    assert neither["ok"] is False and "room_id" in neither["reason"]
