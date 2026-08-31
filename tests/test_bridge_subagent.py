"""bridge 側的 subagent 身分：自報、派生 key、以及認不得時絕不退回父層。

這裡守的是 `docs/SUBAGENT-IDENTITY.md` §3 的那條線——bridge 是唯一知道
「這次呼叫是誰」的地方（Hub 分辨不出來），所以判錯的後果全都是靜默的。
"""

import pytest

from chatroom_mcp import server
from chatroom_mcp.hub import HubError
from chatroom_mcp.state import BridgeState
from chatroom_mcp.subagents import derive_key

ROOM = "room-1"
PARENT_KEY = "claude-parent-session"


class FakeHub:
    """只記下請求並回罐頭答案。這裡要驗的是 bridge 怎麼組請求、怎麼記身分。"""

    def __init__(self):
        self.calls = []
        self.next_participant = "sub-participant-1"

    def request(self, method, path, *, participant_id=None, **kwargs):
        self.calls.append({"method": method, "path": path,
                           "participant_id": participant_id, **kwargs})
        if path.endswith("/join"):
            return {
                "joined_seq": getattr(self, "joined_seq", 0),
                "participant_id": self.next_participant,
                "display_name": kwargs["json"].get("preferred_name") or "無名",
                "session_key": kwargs["json"]["session_key"],
                "parent_name": "Novia",
                "identity_scope": "subagent",
            }
        if path.endswith("/messages"):
            return {"id": "m1", "seq": 7, "mentions": []}
        if path.endswith("/leave"):
            return {"ok": True}
        if path.endswith("/questions"):
            return {"id": "q1", "target_name": "Bernie", "target_active": True}
        if path.startswith("/api/questions/"):
            # ask_human 逾時後會回頭查一次狀態
            return {"question": {"status": "pending", "expires_at": None}}
        if path.endswith("/attachments"):
            return {"id": "att-1", "size": 1}
        if path.endswith(f"/api/rooms/{ROOM}"):
            return {"participants": [
                {"id": "human-1", "display_name": "Bernie",
                 "role": "human", "status": "active"},
            ]}
        return {}


@pytest.fixture
def bridge(tmp_path, monkeypatch):
    monkeypatch.setattr(server, "SESSION_KEY", PARENT_KEY)
    st = BridgeState(tmp_path / "state.json")
    st.set_identity(ROOM, participant_id="parent-p", display_name="Novia",
                    session_key=PARENT_KEY)
    fake = FakeHub()
    server.configure(bridge_state=st, hub_client=fake)
    server._subagents = type(server._subagents)()
    yield fake
    server.configure(bridge_state=None, hub_client=None)


def test_derived_key_carries_a_random_segment(bridge):
    """同名平行派遣必須算出不同的 key，否則第二個根本進不了房。"""
    a = derive_key(PARENT_KEY, "tester")
    b = derive_key(PARENT_KEY, "tester")
    assert a != b
    assert a.startswith(f"{PARENT_KEY}#tester-")
    assert b.startswith(f"{PARENT_KEY}#tester-")


def test_spawn_declares_parentage_and_returns_a_handle(bridge):
    out = server.chatroom_spawn_subagent(ROOM, "米勒")
    assert out["ok"] is True
    assert out["handle"].startswith("sub-")

    sent = bridge.calls[-1]["json"]
    assert sent["parent_participant_id"] == "parent-p"
    assert sent["session_key"].startswith(f"{PARENT_KEY}#")


def test_spawn_before_joining_refuses(bridge, tmp_path):
    """父層自己不在房裡就沒有可依附的對象——這裡擋掉比讓 Hub 404 清楚。"""
    empty = BridgeState(tmp_path / "empty.json")
    server.configure(bridge_state=empty)
    out = server.chatroom_spawn_subagent(ROOM, "米勒")
    assert out["ok"] is False
    assert "chatroom_join" in out["reason"]


def test_post_as_subagent_uses_the_subagent_identity(bridge):
    handle = server.chatroom_spawn_subagent(ROOM, "米勒")["handle"]
    out = server.chatroom_post(ROOM, "我是子代理", subagent=handle)

    assert out["identity_scope"] == "subagent"
    assert out["subagent_name"] == "米勒"
    assert bridge.calls[-1]["participant_id"] == "sub-participant-1"


def test_post_without_handle_stays_parent_and_says_so(bridge):
    """未自報＝以父層身分執行，而且**說出來**。

    沉默的話，「漏帶 handle」與「舊版沒這功能」在結果上完全同形。
    """
    out = server.chatroom_post(ROOM, "一般發言")
    assert out["identity_scope"] == "parent"
    assert "subagent_name" not in out
    assert bridge.calls[-1]["participant_id"] == "parent-p"


def test_unknown_handle_errors_and_sends_nothing(bridge):
    """認不得的 handle 絕不退回父層——那會讓子代理以為自己說了話。"""
    before = len(bridge.calls)
    out = server.chatroom_post(ROOM, "誰在說話", subagent="sub-does-not-exist")

    assert out["ok"] is False
    assert "chatroom_spawn_subagent" in out["reason"]
    # 錨點：真的沒有發出去，不是悄悄以父層名義發了
    assert len(bridge.calls) == before


def test_handle_from_another_room_is_refused(bridge):
    handle = server.chatroom_spawn_subagent(ROOM, "米勒")["handle"]
    out = server.chatroom_post("room-2", "跨房發言", subagent=handle)
    assert out["ok"] is False
    assert "另一個房間" in out["reason"]


def test_ending_a_subagent_drops_the_handle(bridge):
    handle = server.chatroom_spawn_subagent(ROOM, "米勒")["handle"]
    out = server.chatroom_end_subagent(ROOM, handle)
    assert out["ended"] == "米勒"
    assert bridge.calls[-1]["participant_id"] == "sub-participant-1"

    # 收掉之後就不該再認得它
    again = server.chatroom_post(ROOM, "還在嗎", subagent=handle)
    assert again["ok"] is False


def test_expired_subagent_does_not_clear_the_parent_identity(bridge):
    """一個 subagent 的身分失效，不該連累整個 session。"""
    handle = server.chatroom_spawn_subagent(ROOM, "米勒")["handle"]

    def boom(method, path, *, participant_id=None, **kwargs):
        raise HubError("身分已失效", identity_invalid=True)

    bridge.request = boom
    out = server.chatroom_post(ROOM, "掛了", subagent=handle)
    assert out["ok"] is False
    # 父層在 state 檔裡的身分必須原封不動
    assert server.state().participant_id(ROOM) == "parent-p"


def test_expired_handle_is_dropped_and_does_not_say_rejoin(bridge):
    """被短 TTL 回收之後：handle 作廢、訊息指向重新 spawn，且**不標
    need_rejoin**。

    need_rejoin 是叫父層重新 join，而父層好端端的。不移除 handle 的話它會
    被 bridge 永遠認得，每次呼叫都白打一次 Hub，而錯誤一路指向錯的動作。
    """
    handle = server.chatroom_spawn_subagent(ROOM, "米勒")["handle"]

    def boom(method, path, *, participant_id=None, **kwargs):
        raise HubError("身分已失效", identity_invalid=True)

    bridge.request = boom
    out = server.chatroom_post(ROOM, "掛了", subagent=handle)
    assert out["ok"] is False
    assert "need_rejoin" not in out, out
    assert "chatroom_spawn_subagent" in out["reason"]
    assert "heartbeat" in out["reason"], "要順帶說出怎麼避免下一次"

    # handle 已作廢：下一次連 Hub 都不該打
    calls_before = len(bridge.calls)
    bridge.request = FakeHub().request
    again = server.chatroom_post(ROOM, "還在嗎", subagent=handle)
    assert again["ok"] is False
    assert "chatroom_spawn_subagent" in again["reason"]
    assert len(bridge.calls) == calls_before


def test_subagent_identity_applies_to_every_room_tool(bridge):
    """契約 §3：**所有**會產生房內行為的工具都要吃 subagent。

    只做 post 的話，子代理沒有續命手段——TTL 預設 120 秒，一段安靜的長工作
    就會讓它在要交報告時發現身分沒了（Codex review #1）。
    """
    handle = server.chatroom_spawn_subagent(ROOM, "米勒")["handle"]

    # **六個工具全部要驗。** 上一輪只跑了三個，於是 ask_human 漏掉沒被抓到
    # ——斷言寫得比宣稱窄，等於自己給自己開後門（Codex review 二審 #1）
    for label, call in [
        ("post", lambda: server.chatroom_post(ROOM, "x", subagent=handle)),
        ("heartbeat", lambda: server.chatroom_heartbeat(ROOM, subagent=handle)),
        ("read", lambda: server.chatroom_read(ROOM, subagent=handle)),
        ("wait", lambda: server.chatroom_wait(ROOM, timeout=0, subagent=handle)),
        ("send_file", lambda: server.chatroom_send_file(
            ROOM, __file__, subagent=handle)),
        ("ask_human", lambda: server.chatroom_ask_human(
            ROOM, "在嗎", "Bernie", timeout=0, subagent=handle)),
    ]:
        out = call()
        assert out["ok"] is True, (label, out)
        assert out["identity_scope"] == "subagent", (label, out)


def test_ask_human_asks_as_the_subagent_not_the_parent(bridge):
    """Hub 把標頭身分寫成 asker_id——收據、撤回權、離場自動取消都掛在它身上。

    走父層的話，子代理問的問題會變成父層問的：父層離開時被連帶撤回，而真正
    在等答案的是子代理。
    """
    handle = server.chatroom_spawn_subagent(ROOM, "米勒")["handle"]
    out = server.chatroom_ask_human(ROOM, "在嗎", "Bernie", timeout=0,
                                    subagent=handle)
    assert out["identity_scope"] == "subagent"

    created = [c for c in bridge.calls if c["path"].endswith("/questions")]
    assert created, bridge.calls
    assert created[-1]["participant_id"] == "sub-participant-1"
    # 找人也要用子代理的身分——房間詳情是讀取邊界
    lookup = [c for c in bridge.calls if c["path"] == f"/api/rooms/{ROOM}"]
    assert lookup and lookup[-1]["participant_id"] == "sub-participant-1"


def test_each_subagent_has_its_own_cursor(bridge):
    """省略 after_seq 時，子代理用**自己的**游標。

    共用父層那一份，兩個方向都會壞：父層沒在讀 → 子代理永遠拿到同一批；
    父層先讀掉 → 子代理跳過整段未讀（Codex review 二審 #2）。
    """
    server.state().set_last_seq(ROOM, 100)
    bridge.joined_seq = 7          # 子代理是在 seq 7 之後才出生的
    handle = server.chatroom_spawn_subagent(ROOM, "米勒")["handle"]

    seen = []

    def fake(method, path, *, participant_id=None, **kw):
        seen.append((kw.get("params") or {}).get("after_seq"))
        return {"messages": [{"seq": 9}], "next_after_seq": 9}

    bridge.request = fake
    server.chatroom_read(ROOM, subagent=handle)
    server.chatroom_read(ROOM, subagent=handle)
    # 第二次要從第一次的結尾接下去，不是重播
    assert seen == [7, 9], seen
    # 錨點：父層的游標完全沒被動到
    assert server.state().last_seq(ROOM) == 100


def test_subagent_cursor_starts_at_its_join_point(bridge):
    """起點是 join 當下的房內 seq——子代理不補讀出生之前的對話。"""
    bridge.joined_seq = 42
    handle = server.chatroom_spawn_subagent(ROOM, "米勒")["handle"]
    assert server._subagents.cursor(handle) == 42


def test_subagent_read_does_not_move_the_parent_cursor(bridge):
    """子代理讀訊息不推進父層的游標——那是父層「我讀到哪裡」的紀錄。

    被一個臨時分身推著跑，父層就會靜靜地跳過那段沒讀過的訊息。
    """
    handle = server.chatroom_spawn_subagent(ROOM, "米勒")["handle"]
    server.state().set_last_seq(ROOM, 5)

    bridge.request = lambda method, path, *, participant_id=None, **kw: {
        "messages": [{"seq": 42, "content": "新訊息"}], "next_after_seq": 42,
    }
    server.chatroom_read(ROOM, subagent=handle)
    assert server.state().last_seq(ROOM) == 5

    # 錨點：父層自己讀就會推進，否則上面那條可能只是讀取整個沒生效
    server.chatroom_read(ROOM)
    assert server.state().last_seq(ROOM) == 42
