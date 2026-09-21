"""遠端派工（Remote Ops）的 bridge 工具。

這五支工具共用一個特殊處境：**工具介面上只有 `run_id`，而 Hub 要房內身分**。
房間 id 從本機身分推，所以「推錯」與「Hub 拒絕」這兩件事必須分得開——推錯
的症狀是對著另一間房問，而那會回 403，再被翻成「身分失效請重新 join」。

另一半是憑證界線（REMOTE-OPS-PLAN §6.4）：`chatroom_run_request` 與
`chatroom_run_cancel` 只認人類憑證，agent 呼叫一定 403。那條訊息**不能**
讓 agent 以為自己掉出房間了——它會照著去 join，成功，再撞一次同一道門。
"""

import json

import pytest

from chatroom_mcp import server as srv

ROOM = "room-ops"
PID = "pid-run"


@pytest.fixture
def in_room(fake_hub, bridge_state):
    """本 session 已經是這間工作房的成員。"""
    bridge_state.set_identity(ROOM, PID, "Novia")
    return fake_hub


def _body(request):
    return json.loads(request.content.decode("utf-8"))


# ---------- chatroom_runs ----------


def test_runs_merges_the_queue_and_the_dashboard(in_room):
    """佇列與執行器儀表板要一次回——分開讀的話「沒人在跑」與「沒有執行器」同形。"""
    in_room.json("GET", f"/api/rooms/{ROOM}/runs",
                 {"runs": [{"id": "r1", "status": "queued", "ref": "t-1"}]})
    in_room.json("GET", f"/api/rooms/{ROOM}/runner", {
        "room_id": ROOM,
        "runners": [{"id": "rn1", "status": "online", "running_count": 1}],
        "counts": {"queued": 1}, "queued": 1, "running": 0,
        "active_runs": [{"id": "r1"}],
    })
    out = srv.chatroom_runs(room_id=ROOM)
    assert out["ok"] is True
    assert [r["id"] for r in out["runs"]] == ["r1"]
    assert out["runners"][0]["status"] == "online"
    assert out["queued"] == 1
    assert out["active_runs"][0]["id"] == "r1"


def test_runs_passes_the_status_filter_through(in_room):
    seen = {}

    def queue(request):
        seen["status"] = request.url.params.get("status")
        import httpx
        return httpx.Response(200, json={"runs": []})

    in_room.on("GET", f"/api/rooms/{ROOM}/runs", queue)
    in_room.json("GET", f"/api/rooms/{ROOM}/runner", {"runners": []})
    srv.chatroom_runs(room_id=ROOM, status="queued,running")
    assert seen["status"] == "queued,running"


def test_runs_without_room_id_uses_the_only_room_we_have(in_room):
    """一個 run 的 agent 就待在一間房——那是常態，不該逼它自己填 room_id。"""
    in_room.json("GET", f"/api/rooms/{ROOM}/runs", {"runs": []})
    in_room.json("GET", f"/api/rooms/{ROOM}/runner", {"runners": []})
    assert srv.chatroom_runs()["ok"] is True


def test_runs_refuses_to_guess_between_two_rooms(fake_hub, bridge_state):
    """兩間房就不猜。猜錯會對另一間房問，拿回 403，然後被翻成「身分失效」。"""
    bridge_state.set_identity(ROOM, PID, "Novia")
    bridge_state.set_identity("room-other", "pid-2", "Novia")
    out = srv.chatroom_runs()
    assert out["ok"] is False
    assert "room_id" in out["reason"]
    assert fake_hub.calls == [], "不確定是哪間房時不該先打出去試"


# ---------- chatroom_run ----------


def test_run_returns_the_audit_trail(in_room):
    in_room.json("GET", "/api/runs/r1", {
        "run": {"id": "r1", "status": "running", "handoff_depth": 0},
        "events": [{"from_status": "", "to_status": "queued"}],
    })
    out = srv.chatroom_run("r1", room_id=ROOM)
    assert out["ok"] is True
    assert out["run"]["status"] == "running"
    assert out["events"][0]["to_status"] == "queued"


# ---------- chatroom_run_request ----------


def test_run_request_creates_a_run(in_room):
    captured = {}

    def create(request):
        captured.update(_body(request))
        import httpx
        return httpx.Response(200, json={"run": {"id": "r9", "status": "queued"}})

    in_room.on("POST", f"/api/rooms/{ROOM}/runs", create)
    out = srv.chatroom_run_request(ROOM, "ticket", "ai-website", "t-1",
                                   brief="修那張票", priority=2)
    assert out["ok"] is True and out["run"]["id"] == "r9"
    assert captured == {"kind": "ticket", "project": "ai-website",
                        "ref": "t-1", "brief": "修那張票", "priority": 2}


def test_run_request_rejects_an_unknown_kind_before_the_hub_sees_it(in_room):
    """Hub 的 422 只會說「不符合這個正規式」；agent 要的是「有哪四種」。"""
    out = srv.chatroom_run_request(ROOM, "deploy", "ai-website", "t-1")
    assert out["ok"] is False
    for kind in ("investigate", "ticket", "stage", "push"):
        assert kind in out["reason"]
    assert in_room.calls == [], "擋在 bridge 就不該打 Hub"


def test_run_request_rejects_an_over_long_brief(in_room):
    out = srv.chatroom_run_request(ROOM, "ticket", "ai-website", "t-1",
                                   brief="字" * 2001)
    assert out["ok"] is False
    assert "2000" in out["reason"] and "2001" in out["reason"]
    assert in_room.calls == []


def test_run_request_requires_a_target(in_room):
    assert srv.chatroom_run_request(ROOM, "ticket", "ai-website", "")["ok"] is False
    assert srv.chatroom_run_request(ROOM, "ticket", "", "t-1")["ok"] is False
    assert in_room.calls == []


def test_run_request_403_does_not_read_as_a_lost_identity(in_room):
    """**這一條是整組工具的重點。**

    agent 派工被拒是它做了一件本來就不屬於它的事，不是身分過期。翻成
    「請重新 join」的話它會照做、成功、再撞一次，而中間沒有任何線索。
    """
    in_room.error("POST", f"/api/rooms/{ROOM}/runs", 403,
                  {"code": "human_actor_required_for_run",
                   "message": "只有房內的人類成員能派工。"})
    out = srv.chatroom_run_request(ROOM, "ticket", "ai-website", "t-1")
    assert out["ok"] is False
    assert out.get("need_rejoin") is not True
    assert "人類" in out["reason"]


def test_run_request_403_on_human_token_says_the_credential_is_the_problem(in_room):
    in_room.error("POST", f"/api/rooms/{ROOM}/runs", 403,
                  {"code": "human_token_required_for_run",
                   "message": "派工只認人類憑證。"})
    out = srv.chatroom_run_request(ROOM, "ticket", "ai-website", "t-1")
    assert out["ok"] is False
    assert out.get("need_rejoin") is not True
    assert "憑證" in out["reason"]


def test_run_request_quota_429_tells_you_to_wait_not_to_retry(in_room):
    in_room.error("POST", f"/api/rooms/{ROOM}/runs", 429,
                  {"code": "run_daily_quota_exceeded",
                   "message": "今天已經派了 20 筆，達到每日上限（20）。"})
    out = srv.chatroom_run_request(ROOM, "ticket", "ai-website", "t-1")
    assert out["ok"] is False
    assert out["code"] == "run_daily_quota_exceeded"
    assert "20" in out["reason"]


# ---------- chatroom_run_cancel ----------


def test_run_cancel_distinguishes_stopped_from_flagged(in_room):
    in_room.json("POST", "/api/runs/r1/cancel",
                 {"run": {"id": "r1", "status": "running"}, "cancelled": False})
    out = srv.chatroom_run_cancel("r1", room_id=ROOM)
    assert out["ok"] is True
    # False＝旗標已立、進程還在跑。這與「已經停了」是兩件事
    assert out["cancelled"] is False


def test_run_cancel_403_does_not_read_as_a_lost_identity(in_room):
    in_room.error("POST", "/api/runs/r1/cancel", 403,
                  {"code": "human_actor_required_for_run_cancel",
                   "message": "取消派工只有房內的人類成員或管理員做得到。"})
    out = srv.chatroom_run_cancel("r1", room_id=ROOM)
    assert out["ok"] is False
    assert out.get("need_rejoin") is not True


# ---------- chatroom_run_handoff ----------


def _handoff_hub(hub, *, ref="t-1", description="原本的敘述"):
    hub.json("GET", "/api/runs/r1",
             {"run": {"id": "r1", "room_id": ROOM, "ref": ref,
                      "status": "running", "handoff_depth": 0},
              "events": []})
    hub.json("GET", f"/api/rooms/{ROOM}/board", {
        "board_id": "b-1",
        "checklists": [{"id": "c-1", "title": "階段"}],
        "tasks": [{"id": "t-1", "title": "卡", "description": description,
                   "status": "in_progress"}],
        "board_seq": 7,
    })


def test_handoff_appends_the_note_and_releases_the_claim(in_room):
    """交接寫進卡 + 放掉認領。**卡的狀態不動**——事情還沒做完。"""
    _handoff_hub(in_room)
    patched = {}

    def patch(request):
        patched.update(_body(request))
        import httpx
        return httpx.Response(200, json={"task": {"id": "t-1"}})

    in_room.on("PATCH", "/api/board/tasks/t-1", patch)
    in_room.json("POST", "/api/board/tasks/t-1/release",
                 {"task": {"id": "t-1", "status": "in_progress",
                           "claim_state": "free"}})

    out = srv.chatroom_run_handoff("r1", "已做：A。未做：B。下一步：C。",
                                   room_id=ROOM)
    assert out["ok"] is True
    assert out["task_id"] == "t-1" and out["released"] is True
    # 原敘述保留：那是下一棒要讀的東西，蓋掉它等於把交接的理由也一起丟了
    assert patched["description"].startswith("原本的敘述")
    assert "已做：A。未做：B。下一步：C。" in patched["description"]
    assert "status" not in patched, "交接不動卡的狀態"
    # 放掉認領那一步真的打出去了
    assert ("POST", "/api/board/tasks/t-1/release") in [
        (c.method, c.url.path) for c in in_room.calls]
    assert "結束你的回合" in out["next"]


def test_handoff_writes_the_note_when_the_card_had_no_description(in_room):
    _handoff_hub(in_room, description="")
    patched = {}

    def patch(request):
        patched.update(_body(request))
        import httpx
        return httpx.Response(200, json={"task": {"id": "t-1"}})

    in_room.on("PATCH", "/api/board/tasks/t-1", patch)
    in_room.json("POST", "/api/board/tasks/t-1/release", {"task": {"id": "t-1"}})
    assert srv.chatroom_run_handoff("r1", "交接內容", room_id=ROOM)["ok"] is True
    assert patched["description"].startswith("## 交接（run r1）")


def test_handoff_refuses_an_empty_note(in_room):
    out = srv.chatroom_run_handoff("r1", "   ", room_id=ROOM)
    assert out["ok"] is False
    assert in_room.calls == [], "空的交接不值得打一趟 Hub"


def test_handoff_on_a_checklist_ref_asks_for_the_card(in_room):
    """`stage` 派工的 ref 是階段不是卡——交接要寫在 agent 自己開的那張卡上。"""
    _handoff_hub(in_room, ref="c-1")
    out = srv.chatroom_run_handoff("r1", "交接內容", room_id=ROOM)
    assert out["ok"] is False
    assert "task_id" in out["reason"]
    # 沒有任何寫入發生：把交接寫到 checklist 上是靜默的錯地方
    assert not [c for c in in_room.calls if c.method in ("PATCH", "POST")]


def test_handoff_with_explicit_task_id_overrides_the_ref(in_room):
    _handoff_hub(in_room, ref="c-1")
    in_room.json("PATCH", "/api/board/tasks/t-1", {"task": {"id": "t-1"}})
    in_room.json("POST", "/api/board/tasks/t-1/release", {"task": {"id": "t-1"}})
    out = srv.chatroom_run_handoff("r1", "交接內容", task_id="t-1", room_id=ROOM)
    assert out["ok"] is True and out["task_id"] == "t-1"


def test_handoff_says_so_when_the_card_is_not_on_the_board(in_room):
    _handoff_hub(in_room, ref="t-missing")
    out = srv.chatroom_run_handoff("r1", "交接內容", room_id=ROOM)
    assert out["ok"] is False
    assert "t-missing" in out["reason"]


def test_handoff_403_does_not_read_as_a_lost_identity(in_room):
    """卡在別人手上／板上是 viewer——那些都不是身分失效。"""
    _handoff_hub(in_room)
    in_room.error("PATCH", "/api/board/tasks/t-1", 403,
                  {"code": "board_read_only",
                   "message": "你在這塊板上是 viewer。"})
    out = srv.chatroom_run_handoff("r1", "交接內容", room_id=ROOM)
    assert out["ok"] is False
    assert out.get("need_rejoin") is not True


# ---------- 沒有身分時的處置 ----------


def test_run_tools_without_any_identity_point_at_join(fake_hub):
    out = srv.chatroom_runs()
    assert out["ok"] is False
    assert out.get("need_rejoin") is True
    assert "chatroom_join" in out["reason"]
    assert fake_hub.calls == []
