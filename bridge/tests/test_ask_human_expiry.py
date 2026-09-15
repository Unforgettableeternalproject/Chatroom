"""`chatroom_ask_human` 的等待與逾時。

兩個時間是分開的，這是整支工具最容易搞混的地方：

- ``timeout``——**我要等多久**
- ``question_ttl``——**這題活多久**

分開之後「只等 30 秒但問題留 3 分鐘」是合法用法：問完先去做別的，稍後回頭
拿。發問的 agent 卡著的時候，派它做事的人也在等它。

回報 ``timeout`` 與 ``expired`` 必須分開：前者還能拿到答案，後者拿不到。
壓成同一個字等於逼 agent 去猜，而它多半會猜「再等等看」。
"""

import httpx

from chatroom_mcp import server as srv

ROOM = "room-1"
QID = "q-1"


def _ready(fake_hub, target_active=True):
    """房內身分 + 名稱解析 + 建立問題，都先鋪好。"""
    fake_hub.json("POST", f"/api/rooms/{ROOM}/join",
                  {"participant_id": "pid-1", "display_name": "Novia",
                   "rejoined": False})
    srv.chatroom_join(ROOM)
    fake_hub.json("GET", f"/api/rooms/{ROOM}",
                  {"participants": [
                      {"id": "human-1", "display_name": "Xavier",
                       "status": "active", "role": "human", "kind": "human"}]})
    fake_hub.json("POST", f"/api/rooms/{ROOM}/questions",
                  {"id": QID, "target_id": "human-1", "target_name": "Xavier",
                   "target_active": target_active,
                   "target_last_seen_at": "2026-08-30T00:00:00+00:00",
                   "expires_at": "2026-08-30T00:03:00+00:00",
                   "expires_in_seconds": 180})


def _question(status, **extra):
    q = {"id": QID, "status": status, "answer": None, "answer_kind": None,
         "expires_in_seconds": 120}
    q.update(extra)
    return {"question": q}


def test_answer_comes_back(fake_hub):
    _ready(fake_hub)
    fake_hub.json("GET", f"/api/questions/{QID}",
                  _question("answered", answer="用 A", answer_kind="free_text"))
    out = srv.chatroom_ask_human(ROOM, "要用哪個方案？", "Xavier")
    assert out["answered"] is True and out["answer"] == "用 A"


def test_expired_is_reported_separately_from_timeout(fake_hub):
    """這題沒了：回頭也拿不到答案，訊息必須說死，不能留「再等等」的餘地。"""
    _ready(fake_hub)
    fake_hub.json("GET", f"/api/questions/{QID}", _question("expired"))
    out = srv.chatroom_ask_human(ROOM, "要用哪個方案？", "Xavier")
    assert out["answered"] is False
    assert out["reason"] == "expired"
    assert "拿不到答案" in out["hint"]
    # 不可以在這裡叫人回頭拿——那是 timeout 才有的出路
    assert "chatroom_read_answer" not in out["hint"].replace(
        "（chatroom_read_answer 只會告訴你同一件事）", "")


def test_timeout_says_how_long_the_question_still_lives(fake_hub):
    """等夠了但題還活著——沒有剩餘秒數的話，「timeout」就是一句沒有下一步的話。"""
    _ready(fake_hub)
    fake_hub.json("GET", f"/api/questions/{QID}", _question("pending"))
    out = srv.chatroom_ask_human(ROOM, "要用哪個方案？", "Xavier", timeout=0)
    assert out["reason"] == "timeout"
    assert out["expires_in_seconds"] == 120
    assert "chatroom_read_answer" in out["hint"]


def test_timeout_falls_through_to_expired_when_the_question_is_already_dead(fake_hub):
    """等待期間題就過期了：不該還叫人回頭拿一個拿不到的答案。"""
    _ready(fake_hub)
    fake_hub.json("GET", f"/api/questions/{QID}",
                  _question("expired", expires_in_seconds=0))
    out = srv.chatroom_ask_human(ROOM, "要用哪個方案？", "Xavier", timeout=0)
    assert out["reason"] == "expired"


def test_question_ttl_is_sent_to_the_hub(fake_hub):
    """`question_ttl` 是題的壽命，跟我等多久無關，要真的傳出去。"""
    _ready(fake_hub)
    fake_hub.json("GET", f"/api/questions/{QID}", _question("skipped"))
    srv.chatroom_ask_human(ROOM, "在嗎", "Xavier", question_ttl=45)
    body = next(c.read().decode() for c in reversed(fake_hub.calls)
                if c.url.path.endswith("/questions") and c.method == "POST")
    assert '"timeout_seconds": 45' in body or '"timeout_seconds":45' in body


def test_default_does_not_send_a_ttl(fake_hub):
    """沒指定就別送——伺服器的預設值才是唯一的一份。"""
    _ready(fake_hub)
    fake_hub.json("GET", f"/api/questions/{QID}", _question("skipped"))
    srv.chatroom_ask_human(ROOM, "在嗎", "Xavier")
    body = next(c.read().decode() for c in reversed(fake_hub.calls)
                if c.url.path.endswith("/questions") and c.method == "POST")
    assert "timeout_seconds" not in body


def test_skipped_still_means_ask_elsewhere(fake_hub):
    """「不想在這裡答」與「沒看到」不同，這條不能被逾時改動搞壞。"""
    _ready(fake_hub)
    fake_hub.json("GET", f"/api/questions/{QID}", _question("skipped"))
    out = srv.chatroom_ask_human(ROOM, "在嗎", "Xavier")
    assert out["reason"] == "skipped"
    assert "改用你原本的方式" in out["hint"]


def test_missing_lifetime_does_not_break_the_timeout_path(fake_hub):
    """舊 Hub 不回 expires_in_seconds——問不到壽命不該讓整個提問失敗。"""
    _ready(fake_hub)
    fake_hub.json("GET", f"/api/questions/{QID}",
                  {"question": {"id": QID, "status": "pending"}})
    out = srv.chatroom_ask_human(ROOM, "在嗎", "Xavier", timeout=0)
    assert out["reason"] == "timeout"
    assert out["expires_in_seconds"] is None
    assert "chatroom_read_answer" in out["hint"]


def test_idle_target_warning_survives_into_the_expired_result(fake_hub):
    """對方本來就不在線的話，過期幾乎是必然——那句提醒要跟著出現。"""
    _ready(fake_hub, target_active=False)
    fake_hub.json("GET", f"/api/questions/{QID}", _question("expired"))
    out = srv.chatroom_ask_human(ROOM, "在嗎", "Xavier")
    assert out["reason"] == "expired"
    assert "沒有動靜" in out["hint"]
