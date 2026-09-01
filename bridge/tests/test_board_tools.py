"""T-09：Board 的四個 MCP 工具。

這份測試釘的是**猜錯又不會報錯**的那幾件事：水位在哪裡推進、沒讀過 board
時不要帶 0、以及 agent 不能 verify 這件事要在工具層就說清楚。
"""

import httpx
import pytest

from chatroom_mcp import server as srv
from chatroom_mcp.hub import HubError

ROOM = "room-1"


def _join(fake_hub):
    fake_hub.json(
        "POST",
        f"/api/rooms/{ROOM}/join",
        {"participant_id": "pid-1", "display_name": "Aster", "rejoined": False},
    )
    srv.chatroom_join(ROOM)


def _board(fake_hub, payload):
    fake_hub.json("GET", f"/api/rooms/{ROOM}/board", payload)


# ---------- 增量水位 ----------


def test_board_starts_at_zero_and_remembers_the_watermark(fake_hub):
    _join(fake_hub)
    _board(fake_hub, {"board_seq": 12, "full": True, "tasks": []})

    result = srv.chatroom_board(ROOM)

    assert result["ok"] is True
    assert result["after_board_seq"] == 0
    assert fake_hub.calls[-1].url.params["after_board_seq"] == "0"
    assert srv.state().board_seq(ROOM) == 12


def test_second_call_is_incremental(fake_hub):
    _join(fake_hub)
    _board(fake_hub, {"board_seq": 12, "tasks": []})
    srv.chatroom_board(ROOM)

    _board(fake_hub, {"board_seq": 15, "tasks": []})
    srv.chatroom_board(ROOM)

    assert fake_hub.calls[-1].url.params["after_board_seq"] == "12"


def test_full_rereads_everything_without_rewinding(fake_hub):
    _join(fake_hub)
    _board(fake_hub, {"board_seq": 12, "tasks": []})
    srv.chatroom_board(ROOM)

    _board(fake_hub, {"board_seq": 12, "full": True, "tasks": []})
    srv.chatroom_board(ROOM, full=True)

    assert fake_hub.calls[-1].url.params["after_board_seq"] == "0"
    # 重讀不該把水位倒回去——下一次增量仍然從 12 起算
    assert srv.state().board_seq(ROOM) == 12


def test_board_watermark_is_separate_from_message_cursor(fake_hub):
    """board 水位與訊息游標**不能互相沖掉**。

    Hub 那側是兩個獨立的計數器（共用的話人看到的訊息編號會跳號）。
    這裡混用不會有任何地方報錯，只會安靜地漏訊息或漏 board 變動。
    """
    _join(fake_hub)
    srv.state().set_last_seq(ROOM, 300)
    _board(fake_hub, {"board_seq": 7, "tasks": []})

    srv.chatroom_board(ROOM)

    assert srv.state().board_seq(ROOM) == 7
    assert srv.state().last_seq(ROOM) == 300


# ---------- chatroom_wait 的接線 ----------


def test_wait_omits_after_board_seq_until_board_has_been_read(fake_hub):
    """🔴 沒讀過 board 就**不帶**這個參數，不是帶 0。

    帶 0 的話任何已經有內容的板都會讓 long-poll 立刻返回，變成 25 秒 25 次
    的空轉——而畫面上看起來只是「訊息一直是空的」，沒有任何地方報錯。
    """
    _join(fake_hub)
    fake_hub.json("GET", f"/api/rooms/{ROOM}/updates",
                  {"messages": [], "last_seq": 0})

    srv.chatroom_wait(ROOM, timeout=0.1)

    assert "after_board_seq" not in fake_hub.calls[-1].url.params


def test_wait_sends_watermark_once_board_is_known(fake_hub):
    _join(fake_hub)
    _board(fake_hub, {"board_seq": 9, "tasks": []})
    srv.chatroom_board(ROOM)
    fake_hub.json("GET", f"/api/rooms/{ROOM}/updates",
                  {"messages": [], "last_seq": 0, "board_seq": 9})

    result = srv.chatroom_wait(ROOM, timeout=0.1)

    assert fake_hub.calls[-1].url.params["after_board_seq"] == "9"
    assert result["board_changed"] is False


def test_wait_reports_board_changed_but_does_not_move_the_watermark(fake_hub):
    """水位要等**內容拿到手**才前進。

    在這裡推進的話，下一次就不會再被通知，而板上那批變動根本還沒讀。
    """
    _join(fake_hub)
    _board(fake_hub, {"board_seq": 9, "tasks": []})
    srv.chatroom_board(ROOM)
    fake_hub.json("GET", f"/api/rooms/{ROOM}/updates",
                  {"messages": [], "last_seq": 0, "board_seq": 14})

    result = srv.chatroom_wait(ROOM, timeout=0.1)

    assert result["board_changed"] is True
    assert srv.state().board_seq(ROOM) == 9


def test_unread_board_is_not_reported_as_a_change(fake_hub):
    """🔴 「你還沒看過這塊板」與「board 剛剛動了」是兩件事。

    合成一個的話，沒讀過 board 的 agent 會在**每一次** wait 都看到
    board_changed=true（板上只要有東西，水位就大於 0），而它以為那代表
    剛剛有變動——一個永遠為真、因此毫無資訊的訊號。
    """
    _join(fake_hub)
    fake_hub.json("GET", f"/api/rooms/{ROOM}/updates",
                  {"messages": [], "last_seq": 0, "board_seq": 42})

    result = srv.chatroom_wait(ROOM, timeout=0.1)

    assert result["board_changed"] is False
    assert result["board_unread"] is True


def test_read_board_then_no_change_reports_neither(fake_hub):
    _join(fake_hub)
    _board(fake_hub, {"board_seq": 42, "tasks": []})
    srv.chatroom_board(ROOM)
    fake_hub.json("GET", f"/api/rooms/{ROOM}/updates",
                  {"messages": [], "last_seq": 0, "board_seq": 42})

    result = srv.chatroom_wait(ROOM, timeout=0.1)

    assert result["board_changed"] is False
    assert result["board_unread"] is False


def test_board_change_does_not_count_as_being_mentioned(fake_hub):
    """被 board 叫醒 ≠ 被 @。"""
    _join(fake_hub)
    _board(fake_hub, {"board_seq": 1, "tasks": []})
    srv.chatroom_board(ROOM)
    fake_hub.json("GET", f"/api/rooms/{ROOM}/updates", {
        "messages": [], "last_seq": 0, "board_seq": 5,
        "you_were_mentioned": False,
    })

    result = srv.chatroom_wait(ROOM, timeout=0.1)

    assert result["board_changed"] is True
    assert result["you_were_mentioned"] is False


# ---------- 新增 ----------


def test_add_task_posts_under_its_checklist(fake_hub):
    _join(fake_hub)
    fake_hub.json("POST", "/api/board/checklists/c1/tasks", {"id": "t9"})

    result = srv.chatroom_board_add(
        ROOM, "task", "寫測試", parent_id="c1", source_seq=142)

    assert result["id"] == "t9"
    body = fake_hub.calls[-1].read().decode()
    assert "142" in body


def test_add_rejects_unknown_kind(fake_hub):
    _join(fake_hub)
    result = srv.chatroom_board_add(ROOM, "epic", "x")
    assert result["ok"] is False
    assert "objective" in result["reason"]


def test_task_without_parent_goes_to_the_loose_endpoint(fake_hub):
    """隨手記一件事：不給 parent_id 就讓 Hub 放進「未分類」。

    要 agent 為了記一件事先蓋 Objective 再蓋 Checklist，實際的結果是
    它乾脆不記（Q2 定案的那條退路，F2 之後才通）。
    """
    _join(fake_hub)
    fake_hub.json("POST", f"/api/rooms/{ROOM}/board/tasks", {"id": "t-loose"})

    result = srv.chatroom_board_add(ROOM, "task", "隨手記一件事")

    assert result["id"] == "t-loose"
    assert fake_hub.calls[-1].url.path == f"/api/rooms/{ROOM}/board/tasks"


def test_checklist_without_parent_says_which_id_is_missing(fake_hub):
    """checklist **沒有**那條退路：它一定要掛在某個 objective 底下。

    錯誤訊息要說得出要哪一個 id，不然 agent 只會再猜一次。
    """
    _join(fake_hub)

    result = srv.chatroom_board_add(ROOM, "checklist", "x")

    assert result["ok"] is False
    assert "objective" in result["reason"]


# ---------- 更新與狀態 ----------


def test_update_status_uses_the_status_endpoint_not_patch(fake_hub):
    """狀態一律走專用端點。PATCH 那條 Hub 是 extra=forbid，會 422。"""
    _join(fake_hub)
    fake_hub.json("POST", "/api/board/tasks/t1/status", {"ok": True})

    srv.chatroom_board_update(ROOM, "t1", status="done")

    assert fake_hub.calls[-1].url.path == "/api/board/tasks/t1/status"


def test_update_fields_uses_patch(fake_hub):
    _join(fake_hub)
    fake_hub.json("PATCH", "/api/board/tasks/t1", {"ok": True})

    srv.chatroom_board_update(ROOM, "t1", title="改個標題")

    assert fake_hub.calls[-1].method == "PATCH"


def test_update_with_nothing_to_change_says_so(fake_hub):
    _join(fake_hub)
    result = srv.chatroom_board_update(ROOM, "t1")
    assert result["ok"] is False


def test_objective_review_goes_to_its_own_endpoint(fake_hub):
    _join(fake_hub)
    fake_hub.json("POST", "/api/board/objectives/o1/review", {"ok": True})

    srv.chatroom_board_update(ROOM, "o1", kind="objective", status="review")

    assert fake_hub.calls[-1].url.path == "/api/board/objectives/o1/review"


def test_agents_are_told_why_verify_is_not_available(fake_hub):
    """🔴 agent 試圖 verify 時，要在**工具層**就講清楚，不要讓它撞 403。

    Hub 會擋，但那時 agent 拿到的是一個權限錯誤，它會去猜有沒有別條路。
    這裡直接說出該做什麼：送審，然後請人類確認。
    """
    _join(fake_hub)

    result = srv.chatroom_board_update(
        ROOM, "o1", kind="objective", status="verified")

    assert result["ok"] is False
    assert "人類" in result["reason"]
    assert "review" in result["reason"]
    # 根本沒打出去——這是工具層的判斷，不是 Hub 的拒絕
    assert all("verify" not in c.url.path for c in fake_hub.calls)


# ---------- 認領 ----------


def test_claim_posts_to_claim(fake_hub):
    _join(fake_hub)
    fake_hub.json("POST", "/api/board/tasks/t1/claim",
                  {"ok": True, "reclaimed": False})

    result = srv.chatroom_board_claim(ROOM, "t1")

    assert result["ok"] is True
    assert fake_hub.calls[-1].url.path == "/api/board/tasks/t1/claim"


def test_release_posts_to_release(fake_hub):
    _join(fake_hub)
    fake_hub.json("POST", "/api/board/tasks/t1/release", {"ok": True})

    srv.chatroom_board_claim(ROOM, "t1", release=True)

    assert fake_hub.calls[-1].url.path == "/api/board/tasks/t1/release"


def test_claim_conflict_keeps_the_holder_name(fake_hub):
    """認領失敗是正常結果——回應要說得出現在是誰持有它。"""
    _join(fake_hub)
    fake_hub.error("POST", "/api/board/tasks/t1/claim", 409, {
        "code": "task_already_claimed",
        "message": "這張卡已經被 Swift-Falcon 領走了",
    })

    result = srv.chatroom_board_claim(ROOM, "t1")

    assert result["ok"] is False
    assert "Swift-Falcon" in result["reason"]
    # 認領衝突不是身分問題，不可以叫人重新 join
    assert result.get("need_rejoin") is not True


# ---------- 子代理身分（測試端 #73 提出）----------


def _spawn(fake_hub, handle_name="Probe", pid="pid-sub"):
    fake_hub.json("POST", f"/api/rooms/{ROOM}/join",
                  {"participant_id": pid, "display_name": handle_name,
                   "rejoined": False, "ephemeral": True})
    return srv.chatroom_spawn_subagent(ROOM, handle_name)


def test_subagent_claims_with_its_own_identity(fake_hub):
    """🔴 子代理認領要用**自己的** participant id。

    走父層身分的話，那張卡會掛在父層名下、房內看到的也是父層的名字；
    而同一個父層派兩個子代理去領同一張時，第二次會拿到「已經被『你自己』
    領走了」——訊息荒謬，**併發保證等於完全沒有被驗證到**。
    """
    _join(fake_hub)
    spawned = _spawn(fake_hub)
    handle = spawned["handle"]
    fake_hub.json("POST", "/api/board/tasks/t1/claim",
                  {"ok": True, "reclaimed": False})

    result = srv.chatroom_board_claim(ROOM, "t1", subagent=handle)

    assert result["identity_scope"] == "subagent"
    assert fake_hub.calls[-1].headers["X-Participant-Id"] == "pid-sub"


def test_board_write_without_handle_stays_on_the_parent(fake_hub):
    """漏帶 handle 不會報錯，會掛在父層名下——所以回應要說得出來。"""
    _join(fake_hub)
    fake_hub.json("POST", "/api/board/tasks/t1/claim", {"ok": True})

    result = srv.chatroom_board_claim(ROOM, "t1")

    assert result["identity_scope"] == "parent"
    assert fake_hub.calls[-1].headers["X-Participant-Id"] == "pid-1"


def test_subagent_reads_full_board_and_leaves_the_parent_cursor_alone(fake_hub):
    """子代理讀 board 不碰父層水位。

    它活不久、也沒有自己的水位；用父層那個會把父層的位置往前推，
    父層之後就靜靜跳過它沒讀過的變動。
    """
    _join(fake_hub)
    _board(fake_hub, {"board_seq": 5, "tasks": []})
    srv.chatroom_board(ROOM)          # 父層水位 → 5

    spawned = _spawn(fake_hub)
    _board(fake_hub, {"board_seq": 30, "tasks": []})
    srv.chatroom_board(ROOM, subagent=spawned["handle"])

    assert fake_hub.calls[-1].url.params["after_board_seq"] == "0"
    assert srv.state().board_seq(ROOM) == 5


def test_subagent_add_and_update_carry_the_handle(fake_hub):
    _join(fake_hub)
    spawned = _spawn(fake_hub)
    handle = spawned["handle"]
    fake_hub.json("POST", "/api/board/checklists/c1/tasks", {"id": "t9"})
    fake_hub.json("POST", "/api/board/tasks/t9/status", {"ok": True})

    srv.chatroom_board_add(ROOM, "task", "x", parent_id="c1", subagent=handle)
    assert fake_hub.calls[-1].headers["X-Participant-Id"] == "pid-sub"

    srv.chatroom_board_update(ROOM, "t9", status="done", subagent=handle)
    assert fake_hub.calls[-1].headers["X-Participant-Id"] == "pid-sub"
