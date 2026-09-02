"""想法板與追蹤的 MCP 工具契約。

⚠️ 這份測試存在的理由：`cf427f1` 把 Hub 側整套做完了、904 條測試全綠，
而 **agent 完全碰不到那些功能**——工具數 27→27，一個都沒加
（@測試Novia 2026-09-02）。

艾斯維爾的原話是「agent 會有工具是可以讀取與編輯」。只有 HTTP 與 UI 的話，
這個功能對它最主要的使用者而言等於不存在，**而 Hub 的測試不會抓到**。
"""

from chatroom_mcp import server as srv

ROOM = "room-1"
BOARD = "board-1"
PAD = "pad-1"
BLOCK = "block-1"


def _join(fake_hub):
    fake_hub.json(
        "POST", f"/api/rooms/{ROOM}/join",
        {"participant_id": "pid-1", "display_name": "Novia", "rejoined": False},
    )
    srv.chatroom_join(ROOM)


def test_reading_by_room_resolves_the_board_first(fake_hub):
    """想法板全都是 board-scoped 的，房裡的人要先知道自己掛的是哪一塊。"""
    _join(fake_hub)
    fake_hub.json("GET", f"/api/rooms/{ROOM}/board",
                  {"board_id": BOARD, "board_seq": 3, "full": True,
                   "tasks": []})
    fake_hub.json("GET", f"/api/boards/{BOARD}/scratchpads",
                  {"board_id": BOARD, "scratchpads": [
                      {"id": PAD, "title": "想法", "block_count": 2,
                       "unresolved_notes": 1, "rev": 3}]})
    out = srv.chatroom_scratchpads(room_id=ROOM)
    assert out["resolved_board_id"] == BOARD
    assert out["scratchpads"][0]["unresolved_notes"] == 1


def test_a_room_with_no_board_says_so_instead_of_an_empty_list(fake_hub):
    """**「這個房沒掛板」與「板上沒有想法板」是兩件事。**

    回一份空清單的話，那兩者長得一模一樣，而下一步完全不同：一個要先掛板，
    一個是正常的空板。
    """
    _join(fake_hub)
    fake_hub.json("GET", f"/api/rooms/{ROOM}/board",
                  {"board_id": None, "board_seq": 0, "full": True,
                   "tasks": []})
    out = srv.chatroom_scratchpads(room_id=ROOM)
    assert out["ok"] is False
    assert "掛" in out["reason"], "要說出下一步，不是只說沒有"


def test_adding_a_block_is_how_an_agent_drops_an_idea(fake_hub):
    fake_hub.json("POST", f"/api/boards/{BOARD}/scratchpads/{PAD}/blocks",
                  {"ok": True, "id": "b9", "rev": 1, "board_seq": 8})
    out = srv.chatroom_scratchpad_add(kind="block", content="一個想法",
                                      board_id=BOARD, pad_id=PAD)
    assert out["id"] == "b9"
    assert fake_hub.calls[-1].url.path == \
        f"/api/boards/{BOARD}/scratchpads/{PAD}/blocks"


def test_a_note_needs_the_block_it_hangs_on(fake_hub):
    """註解掛在段落上。少了 block_id 要**明確擋下並說出替代做法**——
    落進 Hub 的話會是 404，而查半天才知道原因是少一個參數。
    """
    out = srv.chatroom_scratchpad_add(kind="note", content="我有不同看法",
                                      board_id=BOARD, pad_id=PAD)
    assert out["ok"] is False
    assert "block_id" in out["reason"]

    fake_hub.json(
        "POST",
        f"/api/boards/{BOARD}/scratchpads/{PAD}/blocks/{BLOCK}/notes",
        {"ok": True, "id": "n1", "board_seq": 9})
    srv.chatroom_scratchpad_add(kind="note", content="我有不同看法",
                                board_id=BOARD, pad_id=PAD, block_id=BLOCK)
    assert fake_hub.calls[-1].url.path.endswith("/notes")


def test_editing_carries_the_rev(fake_hub):
    """``rev`` 必須送回去。少了它，改寫就是一次無條件覆蓋。"""
    fake_hub.json(
        "PUT", f"/api/boards/{BOARD}/scratchpads/{PAD}/blocks/{BLOCK}",
        {"ok": True, "id": BLOCK, "rev": 4, "board_seq": 10})
    srv.chatroom_scratchpad_edit(pad_id=PAD, block_id=BLOCK, content="改過",
                                 rev=3, board_id=BOARD)
    sent = fake_hub.calls[-1]
    assert sent.method == "PUT"


def test_watch_and_release_hit_the_same_place(fake_hub):
    fake_hub.json("POST", f"/api/boards/{BOARD}/watches",
                  {"ok": True, "watching": True, "watcher_count": 1,
                   "delivery": "room_and_inbox"})
    out = srv.chatroom_watch(task_id="t1", board_id=BOARD)
    assert out["delivery"] == "room_and_inbox"
    assert fake_hub.calls[-1].method == "POST"

    fake_hub.json("DELETE", f"/api/boards/{BOARD}/watches",
                  {"ok": True, "watching": False, "watcher_count": 0})
    srv.chatroom_watch(task_id="t1", board_id=BOARD, release=True)
    assert fake_hub.calls[-1].method == "DELETE"


def test_the_inbox_is_cross_board(fake_hub):
    """「我在等的東西完成了嗎」不分板，所以收件匣**不需要 board_id**。"""
    fake_hub.json("GET", "/api/board/notices",
                  {"actor_key": "claude-x", "unread_count": 2,
                   "notices": [{"id": "n1", "event_type": "task_done",
                                "item_title": "被等的卡"},
                               {"id": "n2", "event_type": "task_reopened",
                                "item_title": "另一張"}]})
    out = srv.chatroom_notices()
    assert out["unread_count"] == 2
    assert fake_hub.calls[-1].url.path == "/api/board/notices"


def test_marking_read_is_a_second_call_not_a_side_effect(fake_hub):
    """``mark_read`` 預設關著：**撈一次就清掉的話，重啟前沒讀完的就沒了。**"""
    fake_hub.json("GET", "/api/board/notices",
                  {"unread_count": 1, "notices": [{"id": "n1"}]})
    srv.chatroom_notices()
    assert fake_hub.calls[-1].url.path == "/api/board/notices"

    fake_hub.json("POST", "/api/board/notices/read", {"ok": True, "marked": 1})
    srv.chatroom_notices(mark_read=True)
    assert fake_hub.calls[-1].url.path == "/api/board/notices/read"


def test_board_scoped_writes_carry_the_session_key_header(fake_hub):
    """⚠️ **寫入只認 `X-Session-Key` 標頭。**

    查詢字串上的 `session_key` 只有 GET 端點吃得到——只給它的話，POST 會被
    當成沒有身分，而錯誤訊息講的是權限，完全對不上真正的原因。
    """
    fake_hub.json("POST", f"/api/boards/{BOARD}/scratchpads",
                  {"ok": True, "id": PAD, "rev": 1})
    srv.chatroom_scratchpad_add(kind="pad", title="新的想法板",
                                content="第一段", board_id=BOARD)
    sent = fake_hub.calls[-1]
    assert sent.headers.get("X-Session-Key"), "寫入沒有帶身分標頭"
