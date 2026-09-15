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
    """走不通的組合要說出原因，不要變成一個 404。

    ⚠️ **這條的前提在 09/06 反了**（卡 46f096b5）。它原本釘的是「認領與
    改卡只走房內身分」，斷言 board_id 一律被擋、訊息要說「先 chatroom_join
    進一間掛著這塊板的房」。那條封鎖已經過時——server 的卡片端點早就吃得下
    `X-Session-Key`。**不是我為了讓測試過而改斷言，是斷言本身跟著契約反了。**

    留下來的是它真正在守的東西：走不通的時候要說得出為什麼。現在走不通的
    只剩「board 軸帶 subagent」。
    """
    for call in (
        lambda: srv.chatroom_board_claim(task_id="t1", board_id=BOARD,
                                         subagent="handle-1"),
        lambda: srv.chatroom_board_update(item_id="t1", status="done",
                                          board_id=BOARD,
                                          subagent="handle-1"),
    ):
        out = call()
        assert out["ok"] is False
        assert "subagent" in out["reason"]
        assert "room_id" in out["reason"], "要告訴他替代做法是哪一條"


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


# ---------------------------------------------------------------------------
# 卡片操作也走得通 board 軸（09/06 卡 46f096b5）
#
# 板房分離之後，`chatroom_board_claim(board_id=…)` 仍被 bridge 本地擋下
# （`_require_room_for_item`），連請求都發不出去。那條封鎖寫的理由是「Hub
# 的卡片端點認的是房內 participant」——**那句話現在不成立了**：server 的
# `_board_item_writer` 早就吃得下 `X-Session-Key`，防線改成 `board_member`
# 資格（tests/test_board_claim.py 兩條實測釘住）。
#
# 所以這是 bridge 沒跟上 server，不是誤用。
# ---------------------------------------------------------------------------


def test_claiming_by_board_id_needs_no_room(fake_hub):
    """Board Library 裡沒有房，卡照樣要領得動。"""
    fake_hub.json("POST", "/api/board/tasks/t-1/claim",
                  {"ok": True, "id": "t-1", "board_seq": 9})
    out = srv.chatroom_board_claim(board_id=BOARD, task_id="t-1")
    assert out["ok"] is True
    req = fake_hub.calls[-1]
    # 憑證走 session_key，兩邊都要帶——GET 吃查詢字串，寫入只認標頭
    assert req.url.params["session_key"]
    assert req.headers.get("X-Session-Key")
    assert "X-Participant-Id" not in req.headers,         "board 軸不該帶房內身分——那把 id 屬於另一個軸"


def test_releasing_by_board_id_works_too(fake_hub):
    """放掉與認領是同一條路，只差一個動作名。"""
    fake_hub.json("POST", "/api/board/tasks/t-1/release",
                  {"ok": True, "id": "t-1", "board_seq": 10})
    out = srv.chatroom_board_claim(board_id=BOARD, task_id="t-1", release=True)
    assert out["ok"] is True
    assert fake_hub.calls[-1].url.path.endswith("/release")


def test_updating_a_card_by_board_id_needs_no_room(fake_hub):
    """改卡同理——收尾一張卡不必先進一間房。"""
    fake_hub.json("POST", "/api/board/tasks/t-1/status",
                  {"ok": True, "id": "t-1", "status": "done", "board_seq": 11})
    out = srv.chatroom_board_update(board_id=BOARD, item_id="t-1",
                                    kind="task", status="done")
    assert out["ok"] is True
    assert fake_hub.calls[-1].headers.get("X-Session-Key")


def test_a_subagent_cannot_act_on_the_board_axis(fake_hub):
    """**子代理只在房裡有身分。**

    認領綁的是 participant，而 board 軸下沒有房、也就沒有 participant。
    默默用父層身分送出去的話，那張卡會掛在父層名下——與「這個功能沒開」
    在結果上完全一樣，而且不會有任何地方報錯。所以明確擋下來。
    """
    out = srv.chatroom_board_claim(board_id=BOARD, task_id="t-1",
                                   subagent="handle-1")
    assert out["ok"] is False
    assert "subagent" in out["reason"]


def test_giving_both_ids_is_still_refused(fake_hub):
    """兩個都是 32 hex，猜錯不會報錯——這條擋線不因為開通而放寬。"""
    out = srv.chatroom_board_claim(room_id=ROOM, board_id=BOARD,
                                   task_id="t-1")
    assert out["ok"] is False
    assert "只能給一個" in out["reason"]
