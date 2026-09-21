"""`skipped` 的處置對 **run** 不一樣。

一般 agent 收到「對方選擇不在這裡回答」時的出路是「改回你原本的方式問他」
——終端機、原生提問工具，總之他有另一條管道。**派工產生的 run 沒有**：
它是一次性無頭進程，沒有人在看它的輸出。給它那句指示，它會停在一個做不到
的動作上，而 run 停住不會有人發現。

App 端已經把 run 成員看到的按鈕改成「不回答，讓它自己決定」——兩端要講
同一件事，否則人按下的意思與 agent 讀到的意思相反。

判準取 session_key 的 `claude-run-` 前綴（Hub 側 `_RUN_SESSION_PREFIX`，
執行器給 run 子進程的約定）。
"""

from chatroom_mcp import server as srv

ROOM = "room-1"
QID = "q-1"


def _ready(fake_hub, session_key=None):
    fake_hub.json("POST", f"/api/rooms/{ROOM}/join",
                  {"participant_id": "pid-1", "display_name": "Novia",
                   "rejoined": False,
                   **({"session_key": session_key} if session_key else {})})
    srv.chatroom_join(ROOM)
    if session_key:
        # join 回應不一定帶 canonical key，這裡直接把身分釘死，測的是
        # 「bridge 怎麼看自己」而不是 join 的回填路徑
        srv.state().set_identity(ROOM, "pid-1", "Novia", session_key)
    fake_hub.json("GET", f"/api/rooms/{ROOM}",
                  {"participants": [
                      {"id": "human-1", "display_name": "Xavier",
                       "status": "active", "role": "human",
                       "kind": "human"}]})
    fake_hub.json("POST", f"/api/rooms/{ROOM}/questions",
                  {"id": QID, "target_id": "human-1", "target_name": "Xavier",
                   "target_active": True,
                   "expires_in_seconds": 180})
    fake_hub.json("GET", f"/api/questions/{QID}",
                  {"question": {"id": QID, "status": "skipped",
                                "answer": None, "answer_kind": None,
                                "expires_in_seconds": 120}})


def test_a_run_is_told_to_decide_for_itself(fake_hub):
    """run 沒有「原本的方式」——叫它改用那條路等於叫它停下來。"""
    _ready(fake_hub, session_key="claude-run-abc123")
    out = srv.chatroom_ask_human(ROOM, "要用哪個方案？", "Xavier")
    assert out["answered"] is False and out["reason"] == "skipped"
    assert "自行" in out["hint"] or "自己決定" in out["hint"]
    assert "原本的方式" not in out["hint"], (
        "對 run 講了一個它做不到的動作")


def test_a_normal_agent_keeps_the_old_wording(fake_hub):
    """不是 run 就維持原文——它真的有別的管道，而那條路比較好。"""
    _ready(fake_hub)
    out = srv.chatroom_ask_human(ROOM, "要用哪個方案？", "Xavier")
    assert out["answered"] is False and out["reason"] == "skipped"
    assert "原本的方式" in out["hint"]
