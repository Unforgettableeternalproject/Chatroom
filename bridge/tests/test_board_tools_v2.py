"""Board v2 的 MCP 工具契約（BOARD_DESIGN §9）。

板已經不屬於任何一間聊天室了，所以工具也不能只認 room_id。這份測試釘的是
那條新路徑，以及**兩件猜錯又不會報錯的事**：

1. `room_id` 與 `board_id` 兩個都是 32 hex，猜錯會安靜地對另一塊板動作
2. 用 room_id 問時「這個房沒掛板」與「板上什麼都沒有」長得一模一樣，
   除非回應明講 `resolved_board_id`
"""

from chatroom_mcp import server as srv

ROOM = "room-1"
BOARD = "board-1"


def _join(fake_hub):
    fake_hub.json(
        "POST",
        f"/api/rooms/{ROOM}/join",
        {"participant_id": "pid-1", "display_name": "Aster", "rejoined": False},
    )
    srv.chatroom_join(ROOM)


def test_boards_lists_the_library(fake_hub):
    """`chatroom_boards()`：房間列表回答不了「我手上有哪些工作」。"""
    fake_hub.json("GET", "/api/boards", {"boards": [
        {"id": BOARD, "name": "Board V2", "status": "active",
         "attached_room_count": 2, "my_role": "owner",
         "task_counts": {"total": 10, "done": 7, "claimed": 1}},
    ]})
    out = srv.chatroom_boards()
    assert [b["id"] for b in out["boards"]] == [BOARD]
    # 憑證走 session_key，不需要任何房間身分
    assert fake_hub.calls[-1].url.params["session_key"]


def test_reading_by_board_id_needs_no_room(fake_hub):
    """Board Library 裡沒有房——那個畫面上也要讀得到板。"""
    fake_hub.json("GET", f"/api/boards/{BOARD}",
                  {"board_id": BOARD, "board_seq": 5, "full": True,
                   "tasks": [], "name": "Board V2"})
    out = srv.chatroom_board(board_id=BOARD)
    assert out["resolved_board_id"] == BOARD
    assert fake_hub.calls[-1].url.path == f"/api/boards/{BOARD}"
    # 水位記在板上，下次接著讀
    assert srv.state().board_cursor(BOARD) == 5


def test_reading_by_room_id_says_which_board_it_was(fake_hub):
    """用 room_id 問要回 `resolved_board_id`。

    沒有這個欄位的話，**「這個房沒掛板」與「板上什麼都沒有」在回應裡長得
    一模一樣**——兩者的下一步完全不同（一個要先掛板，一個是正常的空板）。
    """
    _join(fake_hub)
    fake_hub.json("GET", f"/api/rooms/{ROOM}/board",
                  {"board_id": BOARD, "board_seq": 3, "full": True,
                   "tasks": []})
    assert srv.chatroom_board(ROOM)["resolved_board_id"] == BOARD

    fake_hub.json("GET", f"/api/rooms/{ROOM}/board",
                  {"board_id": None, "board_seq": 0, "full": True,
                   "tasks": []})
    out = srv.chatroom_board(ROOM, full=True)
    assert out["resolved_board_id"] is None, "沒掛板要說沒掛，不是回空板"


def test_giving_both_ids_or_neither_is_refused(fake_hub):
    """兩個 id 都是 32 hex，**猜錯不會有任何地方報錯**——它會安靜地對另一
    塊板動作。所以兩個都給或都不給一律擋下。
    """
    both = srv.chatroom_board(room_id=ROOM, board_id=BOARD)
    assert both["ok"] is False and "只能給一個" in both["reason"]

    neither = srv.chatroom_board()
    assert neither["ok"] is False and "room_id" in neither["reason"]


def test_adding_a_card_straight_onto_the_board(fake_hub):
    fake_hub.json("POST", f"/api/boards/{BOARD}/tasks",
                  {"ok": True, "id": "t9", "board_seq": 6})
    out = srv.chatroom_board_add(kind="task", title="從板上記一件事",
                                 board_id=BOARD)
    assert out["resolved_board_id"] == BOARD
    assert fake_hub.calls[-1].url.path == f"/api/boards/{BOARD}/tasks"

    fake_hub.json("POST", f"/api/boards/{BOARD}/objectives",
                  {"ok": True, "id": "o9", "board_seq": 7})
    srv.chatroom_board_add(kind="objective", title="新週期", board_id=BOARD)
    assert fake_hub.calls[-1].url.path == f"/api/boards/{BOARD}/objectives"


def test_checklist_from_the_board_is_refused_with_a_way_out(fake_hub):
    """Hub 那條 checklist 端點要房內身分，板上沒有房。

    **明確擋下來比讓它 404 好**——後者查半天才知道原因是身分。
    """
    out = srv.chatroom_board_add(kind="checklist", title="階段",
                                 parent_id="o1", board_id=BOARD)
    assert out["ok"] is False
    assert "room_id" in out["reason"], "要說出替代做法，不是只說不行"


def test_item_operations_by_board_id_explain_themselves(fake_hub):
    """認領與改卡目前只走房內身分。

    回 404 的話會讓人以為卡不見了，而真正的原因是身分——訊息要說出
    「先進一間掛著這塊板的房」。
    """
    for call in (
        lambda: srv.chatroom_board_claim(task_id="t1", board_id=BOARD),
        lambda: srv.chatroom_board_update(item_id="t1", status="done",
                                          board_id=BOARD),
    ):
        out = call()
        assert out["ok"] is False
        assert "chatroom_join" in out["reason"]
        assert "attached_rooms" in out["reason"], "要告訴他去哪裡找那些房"


def test_attach_and_detach(fake_hub):
    fake_hub.json("POST", f"/api/boards/{BOARD}/rooms/{ROOM}",
                  {"ok": True, "board_id": BOARD, "room_id": ROOM})
    assert srv.chatroom_board_attach(BOARD, ROOM)["ok"] is True
    assert fake_hub.calls[-1].method == "POST"

    fake_hub.json("DELETE", f"/api/boards/{BOARD}/rooms/{ROOM}",
                  {"ok": True, "board_id": BOARD, "room_id": ROOM})
    srv.chatroom_board_attach(BOARD, ROOM, detach=True)
    assert fake_hub.calls[-1].method == "DELETE"


def test_old_positional_calls_still_work(fake_hub):
    """新參數一律加在**尾端**。

    插在中間會把既有的位置參數呼叫整個錯位，而錯位之後每一次呼叫都打到
    別的地方——這條就是為了讓那件事一發生就紅。
    """
    _join(fake_hub)
    fake_hub.json("POST", "/api/board/tasks/t1/status",
                  {"ok": True, "id": "t1", "status": "done"})
    srv.chatroom_board_update(ROOM, "t1", "task", "done")
    assert fake_hub.calls[-1].url.path == "/api/board/tasks/t1/status"

    fake_hub.json("POST", "/api/board/tasks/t1/claim",
                  {"ok": True, "id": "t1"})
    srv.chatroom_board_claim(ROOM, "t1")
    assert fake_hub.calls[-1].url.path == "/api/board/tasks/t1/claim"
